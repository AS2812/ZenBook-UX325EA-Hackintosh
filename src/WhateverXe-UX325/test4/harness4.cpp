#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cassert>
#include <map>
#include <string>
#include <vector>
#include "kern_edp_aux_backlight.hpp"
typedef int IOReturn; enum { kIOReturnSuccess = 0 };
#define arrsize(a) (sizeof(a)/sizeof((a)[0]))
struct OSObject { virtual ~OSObject() {} };
struct OSData : OSObject { std::vector<uint8_t> v; unsigned getLength() const { return (unsigned)v.size(); } const void *getBytesNoCopy() const { return v.data(); } };
#define OSDynamicCast(T, o) dynamic_cast<T *>(o)
static std::map<std::string, std::vector<uint8_t>> props; static std::map<std::string, OSData> objs;
struct IORegistryEntry { static IORegistryEntry *getRegistryRoot() { static IORegistryEntry r; return &r; }
  bool setProperty(const char *k, const void *d, unsigned n) { props[k].assign((const uint8_t*)d, (const uint8_t*)d + n); return true; }
  bool setProperty(const char *k, bool) { props[k]; return true; }
  OSObject *getProperty(const char *k) { auto it = objs.find(k); return it == objs.end() ? nullptr : &it->second; } };
static void clock_get_uptime(uint64_t *t) { *t = 1; }
static void absolutetime_to_nanoseconds(uint64_t a, uint64_t *r) { *r = a; }
template <typename T> static T FunctionCast(T, uintptr_t a) { return reinterpret_cast<T>(a); }
static bool forceVesa, zeroArg;
static bool checkKernelArgument(const char *n) { return (forceVesa && !strcmp(n, "-wex-tgl-edp-bl-vesa")) || (zeroArg && !strcmp(n, "-wex-tgl-edp-bl-zero")); }
#define SYSLOG(...) do {} while (0)
struct Panel { bool valid {}; uint32_t ddi {}; }; struct Ports { Panel panel; };
static uint8_t dpcd[0x10000]; static std::vector<std::pair<uint32_t,std::vector<uint8_t>>> writes;
struct XE {
  Ports firmwarePorts; bool tglEDPLaneClamp {}, tglEDPTimingFix {}, tglEDPSinkExtCaps {}, tglEDPBacklight {}; uint8_t tglEDPSinkRate[2] {}; void *tglEDPSinkPort {};
  uint8_t tglEDPBLState {}, tglEDPBLCaps[4] {}, tglEDPBLIface {}; uint32_t tglEDPBLMaximum {}, tglEDPBLMaxNits {};
  uint32_t tglEDPBLWantLevel {UINT32_MAX}; bool tglEDPBLPending {};
  static void tglEDPBLReapply(XE *s, void *port);
  uintptr_t orgTGLSetupDisplayTiming {}, orgTGLOptimalLaneCount {}, orgTGLHwSetBacklight {}, orgTGLRegisterRead {};
  static uint32_t wrapTGLOptimalLaneCount(void *port, const void *timing, uint32_t bpp);
  static void wrapTGLSetupDisplayTiming(void *fb, const void *src, void *out);
  static uint32_t wrapTGLHwSetBacklight(void *controller, uint32_t level);
  static uint32_t wrapTGLRegisterRead(void *access, unsigned long reg);
  static uint32_t wrapTGLReadAUX(void *, uint32_t a, void *d, uint32_t n) { memcpy(d, dpcd + a, n); return 0; }
  static uint32_t wrapTGLWriteAUX(void *, uint32_t a, void *d, uint32_t n) { memcpy(dpcd + a, d, n); writes.push_back({a, std::vector<uint8_t>((uint8_t*)d, (uint8_t*)d + n)}); return 0; }
};
static XE driver, *callbackXE = &driver;
static uint32_t ppStatus = 0x80000008;   // PP_STATUS: bit 31 = panel on
static uint32_t regRead(void *, unsigned long r) { return r == 0xC7200 ? ppStatus : 0; }
uint32_t XE::wrapTGLRegisterRead(void *a, unsigned long r) { return regRead(a, r); }
static uint32_t nativeLevel; static uint32_t nativeBL(void *, uint32_t level) { nativeLevel = level; return 0; }
#include "extracted.inc"
static uint8_t port[0x600], controller[0x1000]; static uint32_t cfg[4] = {0, 0, 0, 0};
static void panel(bool intel, uint8_t pwmBits) {   // registers as read on the UX325EA (05:47 test)
  memset(dpcd, 0, sizeof(dpcd)); writes.clear(); props.clear();
  const uint8_t base[16] = {0x14,0x0a,0xc2,0x01,0,0,0x01,0xc0,0x02,0x14,0,0,0,0x09,0x84,0}; memcpy(dpcd, base, 16);
  const uint8_t e700[4] = {0x05,0x9d,0xa6,0x04}; memcpy(dpcd + 0x700, e700, 4);
  dpcd[0x721] = 0x02; dpcd[0x724] = pwmBits; dpcd[0x725] = 0x0b; dpcd[0x726] = 0x0b;
  if (intel) { const uint8_t t[5] = {0x01,0x57,0x01,0x00,0x10}; memcpy(dpcd + 0x340, t, 5); }
  dpcd[0x300] = 0x00; dpcd[0x301] = 0xaa; dpcd[0x302] = 0x01;
  driver.tglEDPBLState = 0; driver.tglEDPBLIface = 0; driver.tglEDPBLMaxNits = 0;
}
static void edid(int cv) {   // CTA extension with HDR static metadata (UX325EA: 116, 96, 7)
  OSData d; d.v.assign(128, 0); d.v[0] = 0x02; d.v[1] = 3; d.v[2] = 4 + 7; d.v[4] = (7 << 5) | 6; d.v[5] = 6; d.v[6] = 0x05; d.v[7] = 0x01;
  d.v[8] = (uint8_t)cv; d.v[9] = 96; d.v[10] = 7; objs["TGLWEGPort0DDCExtension"] = d;
}
static uint64_t q(const char *k, int i) { auto &v = props[k]; assert(v.size() >= size_t(8 * (i + 1))); uint64_t x; memcpy(&x, v.data() + 8 * i, 8); return x; }
int main() {
  *(uint32_t**)(port + 0x548) = cfg; *(void**)(controller + 0xC40) = (void*)1;
  driver.orgTGLHwSetBacklight = (uintptr_t)nativeBL; driver.orgTGLRegisterRead = (uintptr_t)regRead; driver.tglEDPSinkPort = port; driver.tglEDPBacklight = true;
  // I1: the UX325EA panel + its EDID -> Intel interface, max = 50*2^(116/32) = 616 nits
  zeroArg = true;                                                          // the UX325EA config: black at 0
  panel(true, 0); edid(116); XE::wrapTGLHwSetBacklight(controller, 65535);
  assert(driver.tglEDPBLState == 1 && driver.tglEDPBLIface == 2 && driver.tglEDPBLMaxNits == 616);
  assert(q("WEXTGLEDPBacklightCaps", 5) == 2 && q("WEXTGLEDPBacklightCaps", 6) == 616 && (q("WEXTGLEDPBacklightCaps", 7) & 0xFFFFFF) == 0x015701);
  assert(dpcd[0x354] == (616 & 0xFF) && dpcd[0x355] == (616 >> 8) && dpcd[0x356] == 0 && dpcd[0x357] == 0 && (dpcd[0x344] & 0x10));
  assert(dpcd[0x722] == 0 && dpcd[0x723] == 0);                          // VESA registers untouched
  size_t w = writes.size(); XE::wrapTGLHwSetBacklight(controller, 32768);   // 0x344 already enabled: only the nits write
  assert(writes.size() == w + 1 && writes.back().first == 0x354 && (dpcd[0x354] | dpcd[0x355] << 8) == 308);
  XE::wrapTGLHwSetBacklight(controller, 1); assert((dpcd[0x354] | dpcd[0x355] << 8) == 1);   // never 0 unless level 0
  XE::wrapTGLHwSetBacklight(controller, 0); assert((dpcd[0x354] | dpcd[0x355] << 8) == 0 && nativeLevel == 0);
  assert(q("WEXTGLEDPBacklightLast", 7) == 1);
  // I2: AUX enable bit off -> set once, other bits kept
  panel(true, 0); dpcd[0x344] = 0x02; XE::wrapTGLHwSetBacklight(controller, 65535); assert(dpcd[0x344] == 0x12);
  // I3: no HDR metadata -> Linux default 512 nits
  objs.clear(); panel(true, 0); XE::wrapTGLHwSetBacklight(controller, 65535); assert(driver.tglEDPBLMaxNits == 512 && (dpcd[0x354] | dpcd[0x355] << 8) == 512);
  // I4: no Intel caps, VESA with PWMGEN bit count 0 -> full 16-bit range
  panel(false, 0); XE::wrapTGLHwSetBacklight(controller, 65535); assert(driver.tglEDPBLIface == 1 && driver.tglEDPBLMaximum == 0xFFFF && dpcd[0x722] == 0xFF && dpcd[0x723] == 0xFF);
  // I5: boot-arg -wex-tgl-edp-bl-vesa forces VESA on the Intel-capable panel
  forceVesa = true; panel(true, 0); XE::wrapTGLHwSetBacklight(controller, 32768); assert(driver.tglEDPBLIface == 1 && dpcd[0x722] == 0x80 && dpcd[0x354] == 0); forceVesa = false;
  // I6: neither interface -> state 2, never writes
  panel(false, 0); dpcd[0x702] = 0x01; XE::wrapTGLHwSetBacklight(controller, 65535); assert(driver.tglEDPBLState == 2 && writes.empty());
  // I7 (v4.1): without -wex-tgl-edp-bl-zero the lowest level keeps 0.5% (616/200 = 3 nits), never black
  zeroArg = false; panel(true, 0); edid(116); XE::wrapTGLHwSetBacklight(controller, 65535);
  XE::wrapTGLHwSetBacklight(controller, 0); assert((dpcd[0x354] | dpcd[0x355] << 8) == 3);
  XE::wrapTGLHwSetBacklight(controller, 1); assert((dpcd[0x354] | dpcd[0x355] << 8) == 3);
  XE::wrapTGLHwSetBacklight(controller, 32768); assert((dpcd[0x354] | dpcd[0x355] << 8) == 308);
  // I8 (v4.3, lid wake): lid close writes 0; the restore arrives while the panel is off -> skipped and
  // marked pending; the re-send at panel power-on (DPCD D0) writes it and clears the mark
  zeroArg = true; panel(true, 0); edid(116); XE::wrapTGLHwSetBacklight(controller, 65535);
  XE::wrapTGLHwSetBacklight(controller, 0); assert((dpcd[0x354] | dpcd[0x355] << 8) == 0 && !driver.tglEDPBLPending);
  ppStatus = 0; size_t w8 = writes.size();
  XE::wrapTGLHwSetBacklight(controller, 32768);
  assert(writes.size() == w8 && driver.tglEDPBLPending && driver.tglEDPBLWantLevel == 32768 && (dpcd[0x354] | dpcd[0x355] << 8) == 0);
  ppStatus = 0x80000008; XE::tglEDPBLReapply(&driver, port);
  assert(!driver.tglEDPBLPending && (dpcd[0x354] | dpcd[0x355] << 8) == 308 && (dpcd[0x344] & 0x10));
  // I9: a normal write after a skipped one also clears the mark (no second re-send needed)
  ppStatus = 0; XE::wrapTGLHwSetBacklight(controller, 65535); assert(driver.tglEDPBLPending);
  ppStatus = 0x80000008; XE::wrapTGLHwSetBacklight(controller, 49151); assert(!driver.tglEDPBLPending && (dpcd[0x354] | dpcd[0x355] << 8) == 461);
  printf("ALL 9 INTEL/VESA BACKLIGHT CHECKS PASSED\n");
}
