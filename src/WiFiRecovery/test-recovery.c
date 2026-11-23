#include "RecoveryPolicy.h"
#include <assert.h>
#include <stdio.h>

static int emptyListReplay(ScanState scan, bool previouslyJoined) {
    RecoveryPolicy p = {0};
    startWindow(&p, 0);
    int cycles = 0;
    for (int t = 0; t < 1500; t += 15) {
        LinkStatus state = t < 420 && previouslyJoined ? LocalOK : Searching;
        observeScan(&p, state, scan, t);
        RecoveryAction a = decide(&p, state, t, true, true, false);
        if (a == Cycle) { assert(t == 480); cycles++; }
    }
    return cycles;
}

int main(void) {
    RecoveryPolicy p = {0};
    startWindow(&p, 0);
    assert(decide(&p, Missing, 0, false, false, false) == Wait);
    assert(decide(&p, Unready, 15, false, false, false) == Wait);
    assert(decide(&p, Searching, 30, false, false, false) == Launch);
    assert(decide(&p, Searching, 60, true, false, false) == Wait);
    assert(decide(&p, Searching, 90, true, false, false) == Rejoin);
    assert(decide(&p, Searching, 105, false, false, false) == Launch);
    assert(decide(&p, Searching, 265, true, false, false) == Wait);
    assert(decide(&p, Searching, 800, true, false, false) == Rejoin);
    startWindow(&p, 50000);
    assert(decide(&p, RadioOff, 50005, true, true, false) == TurnOn);
    assert(decide(&p, RadioOff, 50015, true, true, false) == Wait);
    startWindow(&p, 60000);
    assert(decide(&p, RadioOff, 60005, true, false, false) == Wait);
    assert(decide(&p, RadioOff, 60015, true, false, true) == TurnOn);
    for (int i = 0; i < 60; i++) assert(decide(&p, LocalUnknown, 60100+i*15, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62000, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62045, true, true, false) == Cycle);
    assert(decide(&p, LocalStall, 62110, true, true, false) == Wait);
    assert(decide(&p, LocalOK, 62125, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62140, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62200, true, true, false) == Wait);
    assert(decide(&p, Incompatible, 63000, true, true, true) == Wait);
    assert(decide(&p, NoService, 63005, true, true, true) == Wait);
    assert(decide(&p, Joining, 63010, true, true, false) == Wait);
    assert(decide(&p, NoAddress, 63100, true, true, false) == Wait);
    assert(emptyListReplay(ScanEmpty, true) == 1);
    assert(emptyListReplay(ScanVisible, true) == 0);
    assert(emptyListReplay(ScanUnknown, true) == 0);
    assert(emptyListReplay(ScanEmpty, false) == 0);
    p = (RecoveryPolicy){.wasJoined = true};
    startWindow(&p, 1000);
    for (int t = 1000; t < 1100; t += 15) {
        observeScan(&p, Searching, t == 1045 ? ScanVisible : ScanEmpty, t);
        assert(decide(&p, Searching, t, true, true, false) != Cycle);
    }
    observeScan(&p, RadioOff, ScanUnknown, 1105);
    assert(!p.empty && decide(&p, RadioOff, 1105, true, false, false) == Wait);
    puts("PASS seven-minute drop, continuous empty cache, visible networks, failed cache reads, first setup, interrupted empty interval and intentional off");
    puts("PASS late login, delayed init, long sleep, manual off, failed association, DHCP, silent router and bounded recovery");
}
