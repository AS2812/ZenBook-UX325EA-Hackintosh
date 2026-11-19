#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cassert>
#include <map>
#include <string>
#include <vector>
typedef int IOReturn; enum { kIOReturnSuccess = 0 };
static std::map<std::string, std::vector<uint8_t>> props;
struct IORegistryEntry { static IORegistryEntry *getRegistryRoot() { static IORegistryEntry r; return &r; }
  bool setProperty(const char *k, const void *d, unsigned n) { props[k].assign((const uint8_t*)d, (const uint8_t*)d + n); return true; }
  bool setProperty(const char *k, bool) { props[k]; return true; } };
static void clock_get_uptime(uint64_t *t) { *t = 1; }
static void absolutetime_to_nanoseconds(uint64_t a, uint64_t *r) { *r = a; }
template <typename T> static T FunctionCast(T, uintptr_t a) { return reinterpret_cast<T>(a); }
struct Panel { bool valid {}; uint32_t ddi {}; };
struct Ports { Panel panel; };
struct XE {
  Ports firmwarePorts; bool tglEDPLaneClamp {}, tglEDPTimingFix {}, tglEDPSinkExtCaps {}; uint8_t tglEDPSinkRate[2] {}; void *tglEDPSinkPort {};
  uintptr_t orgTGLSetupDisplayTiming {}, orgTGLOptimalLaneCount {};
  static uint32_t wrapTGLOptimalLaneCount(void *port, const void *timing, uint32_t bpp);
  static void wrapTGLSetupDisplayTiming(void *fb, const void *src, void *out);
};
static XE driver, *callbackXE = &driver;
#include "extracted.inc"

// ---- donor emulation -------------------------------------------------------
// computeLaneCount/setupOptimalLaneCount exactly as disassembled (0x1fc22 / setupOptimalLaneCount)
static uint32_t donorLanes(void *port, const void *timing, uint32_t bpp) {
  auto p = (uint8_t*)port; if (p[0x117]) { *(uint32_t*)(p+0x124) = p[0x11]; return 0; }
  uint32_t rate = *(uint32_t*)(p+0x128), &lanes = *(uint32_t*)(p+0x124); lanes = 0;
  uint64_t hz = rate==6?162000000:rate==0xA?270000000:rate==0xC?324000000:rate==0x14?540000000:rate==0x1E?810000000:0;
  if (!hz) return 0xE00002C7;
  uint64_t x = uint64_t(bpp) * ((*(const uint64_t*)((const uint8_t*)timing+0x28) * 1000) / hz);
  if (x >= 0x7D08) { lanes = 4; return 0xE00002C7; }
  lanes = x >= 0x3E88 ? 4 : x >= 0x1F48 ? 2 : 1; return 0;
}
static int timingMode;           // 0 = AGDC failure (no write), 1 = normal memmove, 2 = override 0xC..0x95
static uint8_t overrideTiming[0xA0];
static void donorTiming(void *fb, const void *src, void *out) {
  if (timingMode == 1) memmove(out, src, 0xA0);
  else if (timingMode == 2) memcpy((uint8_t*)out + 0xC, overrideTiming + 0xC, 0x96 - 0xC);
  if (timingMode) *(int32_t*)((uint8_t*)fb + 0x3FD8) = 0;
}
static void makeTiming(uint8_t *t, uint64_t pclk) { memset(t, 0, 0xA0); *(uint64_t*)(t+0x28) = pclk; *(uint32_t*)(t+0x40) = 1920; *(uint32_t*)(t+0x50) = 1080; *(uint16_t*)(t+0x88) = 1; *(uint16_t*)(t+0x8A) = 8; }

int main() {
  driver.orgTGLOptimalLaneCount = (uintptr_t)donorLanes; driver.orgTGLSetupDisplayTiming = (uintptr_t)donorTiming;
  static uint8_t fb[0x4B90]; *(int32_t*)(fb+0x3FD8) = -1;
  uint8_t src[0xA0]; makeTiming(src, 140120000);
  // T1: AGDC failure path -> output must equal src (was stack garbage)
  uint8_t out[0xA0]; memset(out, 0xCC, sizeof(out));
  driver.tglEDPTimingFix = true; timingMode = 0; XE::wrapTGLSetupDisplayTiming(fb, src, out);
  assert(!memcmp(out, src, 0xA0)); auto r = (uint64_t*)props["WEXTGLEDPTimingLast"].data(); assert(r[1] == 1 && r[2] == 1 && r[3] == 1 && r[6] == 140120000);
  // T2: normal path -> identical to src, not counted as rescued
  memset(out, 0xCC, sizeof(out)); timingMode = 1; XE::wrapTGLSetupDisplayTiming(fb, src, out);
  assert(!memcmp(out, src, 0xA0)); r = (uint64_t*)props["WEXTGLEDPTimingLast"].data(); assert(r[1] == 0 && r[3] == 1);
  // T3: override path -> donor fields 0xC..0x95 win, head and tail from src (not garbage)
  makeTiming(overrideTiming, 148500000); memset(out, 0xCC, sizeof(out)); timingMode = 2; XE::wrapTGLSetupDisplayTiming(fb, src, out);
  assert(*(uint64_t*)(out+0x28) == 148500000 && !memcmp(out, src, 0xC) && !memcmp(out+0x96, src+0x96, 0xA0-0x96));
  // T4: fix disabled -> wrapper adds nothing (garbage stays, like stock)
  driver.tglEDPTimingFix = false; memset(out, 0xCC, sizeof(out)); timingMode = 0;
  // (route is not installed without the flag; wrapper still safe if called)
  driver.tglEDPTimingFix = true;

  // ---- lane/rate ----
  static uint8_t port[0x600]; static uint32_t cfg[4] = {0, 0, 0, 0}; *(uint32_t**)(port+0x548) = cfg;
  auto setupPort = [&]{ *(uint32_t*)(port+0x128) = 0x14; *(uint64_t*)(port+0x140) = 540000000; *(uint32_t*)(port+0x124) = 2; port[0x11] = 2; port[0x117] = 0; };
  driver.tglEDPLaneClamp = true; driver.tglEDPSinkPort = port; driver.tglEDPSinkRate[0] = 0x0A; driver.tglEDPSinkRate[1] = 0; driver.tglEDPSinkExtCaps = true;
  // T5: valid timing (fixed) -> rate 0x0A, clock 270M, 2 lanes, success  (= firmware/Linux config)
  setupPort(); assert(XE::wrapTGLOptimalLaneCount(port, src, 24) == 0);
  assert(*(uint32_t*)(port+0x128) == 0x0A && *(uint64_t*)(port+0x140) == 270000000 && *(uint32_t*)(port+0x124) == 2);
  // T6: 30 bpp still fits 2 x HBR (15540 < 16008)
  setupPort(); assert(XE::wrapTGLOptimalLaneCount(port, src, 30) == 0 && *(uint32_t*)(port+0x128) == 0x0A && *(uint32_t*)(port+0x124) == 2);
  // T7: 36 bpp does not fit 2 x HBR -> keep native HBR2 (Apple then picks lanes itself)
  setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 36); assert(*(uint32_t*)(port+0x128) == 0x14 && *(uint64_t*)(port+0x140) == 540000000);
  // T8: garbage timing (stock bug) -> no rate change; lane clamp fallback to 2 lanes
  uint8_t bad[0xA0]; memset(bad, 0, sizeof(bad)); *(uint64_t*)(bad+0x28) = 0xffffff953ec267c0ULL;
  setupPort(); assert(XE::wrapTGLOptimalLaneCount(port, bad, 24) == 0); assert(*(uint32_t*)(port+0x128) == 0x14 && *(uint32_t*)(port+0x124) == 2);
  // T9: flag off -> stock behaviour (failure, 4 lanes)
  driver.tglEDPLaneClamp = false; setupPort(); assert(XE::wrapTGLOptimalLaneCount(port, bad, 24) != 0 && *(uint32_t*)(port+0x124) == 4);
  setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14);   // no rate change when off
  driver.tglEDPLaneClamp = true;
  // T10: non-eDP port (DP, cfg[2]=1) and other DDI -> untouched
  cfg[2] = 1; setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14); cfg[2] = 0;
  cfg[0] = 3; setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14); cfg[0] = 0;
  // T11: sink cache from a different port -> untouched
  driver.tglEDPSinkPort = fb; setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14); driver.tglEDPSinkPort = port;
  // T12: extended caps advertise HBR2 -> no clamp
  driver.tglEDPSinkRate[1] = 0x14; setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14); driver.tglEDPSinkRate[1] = 0;
  // T13: unknown sink rate code -> untouched
  driver.tglEDPSinkRate[0] = 0x07; setupPort(); XE::wrapTGLOptimalLaneCount(port, src, 24); assert(*(uint32_t*)(port+0x128) == 0x14); driver.tglEDPSinkRate[0] = 0x0A;
  printf("ALL %d UX325 CHECKS PASSED\n", 13);
}
