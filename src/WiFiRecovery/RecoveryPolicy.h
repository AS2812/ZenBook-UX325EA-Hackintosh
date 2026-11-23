#ifndef ZENBOOK_WIFI_RECOVERY_POLICY_H
#define ZENBOOK_WIFI_RECOVERY_POLICY_H
#include <stdbool.h>

typedef enum { Missing, Incompatible, Unready, RadioOff, Searching, Joining, NoService, NoAddress,
               LocalUnknown, LocalOK, LocalStall } LinkStatus;
typedef enum { Wait, Launch, Rejoin, TurnOn, Cycle } RecoveryAction;
typedef enum { ScanUnknown, ScanEmpty, ScanVisible } ScanState;
typedef struct {
    LinkStatus last;
    double since, epoch, nextAction, nextCycle, nextScan;
    bool relaunched, cycled, restored;
    bool wasJoined, empty;
    double emptySince;
} RecoveryPolicy;

static inline void startWindow(RecoveryPolicy *p, double now) {
    double nextCycle = p->nextCycle;
    bool wasJoined = p->wasJoined;
    *p = (RecoveryPolicy){ .last = Missing, .since = now, .epoch = now, .nextCycle = nextCycle,
                           .wasJoined = wasJoined };
}
static inline void observeScan(RecoveryPolicy *p, LinkStatus state, ScanState scan, double now) {
    if (state >= NoService) p->wasJoined = true;
    if (state != Searching || scan != ScanEmpty) { p->empty = false; return; }
    if (!p->empty) { p->empty = true; p->emptySince = now; }
}
static inline RecoveryAction decide(RecoveryPolicy *p, LinkStatus state, double now, bool running,
                                    bool expectOn, bool manual) {
    if (state != p->last) { p->since = now; p->last = state; }
    if (state == Missing || state == Incompatible || state == Unready) return Wait;
    if (state == RadioOff && (manual || (expectOn && !p->restored && now - p->epoch <= 120))) {
        p->restored = true;
        return TurnOn;
    }
    if (!manual && now < p->nextAction) return Wait;
    if (!running) { p->nextAction = now + 30; return Launch; }
    if (state == RadioOff || state == NoService) return Wait;
    bool scanStuck = state == Searching && p->wasJoined && p->empty && now - p->emptySince >= 60;
    bool trafficStuck = state == LocalStall && now - p->since >= 45;
    if (manual || ((scanStuck || trafficStuck) && !p->cycled && now >= p->nextCycle)) {
        p->cycled = true; p->nextCycle = now + 600; p->nextAction = now + 15;
        return Cycle;
    }
    if (state == LocalOK || state == LocalUnknown) { p->relaunched = false; p->cycled = false; }
    if (state == Searching && (!p->relaunched || now >= p->nextScan) && now - p->since >= 60) {
        p->relaunched = true; p->nextAction = now + 10; p->nextScan = now + 600;
        return Rejoin;
    }
    return Wait;
}
#endif
