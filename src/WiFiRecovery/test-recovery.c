#include "RecoveryPolicy.h"
#include <assert.h>
#include <stdio.h>

// Disconnected with an empty driver list from t=420 s after a working link: restarts at 465, 585, 705, then stop.
static int emptyListReplay(ScanState scan, bool previouslyJoined, int *times) {
    RecoveryPolicy p = {0};
    startWindow(&p, 0);
    int cycles = 0;
    for (int t = 0; t < 1500; t += 15) {
        LinkStatus state = t < 420 && previouslyJoined ? LocalOK : Searching;
        observeScan(&p, state, scan, t);
        if (decide(&p, state, t, true, true, false) == Cycle) { if (times) times[cycles] = t; cycles++; }
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
    assert(decide(&p, Searching, 90, true, false, false) == Wait);
    assert(decide(&p, Searching, 120, true, false, false) == Rejoin);
    assert(decide(&p, Searching, 135, false, false, false) == Launch);
    assert(decide(&p, Searching, 200, true, false, false) == Wait);
    assert(decide(&p, Searching, 310, true, false, false) == Rejoin);
    assert(decide(&p, Searching, 800, true, false, false) == Rejoin);
    startWindow(&p, 50000);
    assert(decide(&p, RadioOff, 50005, true, true, false) == TurnOn);
    assert(decide(&p, RadioOff, 50015, true, true, false) == Wait);
    startWindow(&p, 60000);
    assert(decide(&p, RadioOff, 60005, true, false, false) == Wait);
    assert(decide(&p, RadioOff, 60015, true, false, true) == TurnOn);
    for (int i = 0; i < 60; i++) assert(decide(&p, LocalUnknown, 60100+i*15, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62000, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62120, true, true, false) == Cycle);
    assert(decide(&p, LocalStall, 62150, true, true, false) == Wait);    // cooldown
    assert(decide(&p, LocalOK, 62165, true, true, false) == Wait);       // recovered: counter reset
    assert(decide(&p, LocalStall, 62180, true, true, false) == Wait);
    assert(decide(&p, LocalStall, 62240, true, true, false) == Wait);    // silent only 60 s
    assert(decide(&p, LocalStall, 62310, true, true, false) == Cycle);   // new failure, cooldown over
    assert(decide(&p, Incompatible, 63000, true, true, true) == Wait);
    assert(decide(&p, NoService, 63005, true, true, true) == Wait);
    assert(decide(&p, Joining, 63010, true, true, false) == Wait);
    assert(decide(&p, Joining, 63060, true, true, false) == Wait);
    assert(decide(&p, Joining, 63130, true, true, false) == Rejoin);     // join hanging for 120 s
    assert(decide(&p, NoAddress, 63145, true, true, false) == Wait);
    int at[8] = {0};
    assert(emptyListReplay(ScanEmpty, true, at) == 2 && at[0] == 540 && at[1] == 720);
    assert(emptyListReplay(ScanVisible, true, NULL) == 0);
    assert(emptyListReplay(ScanUnknown, true, NULL) == 0);
    assert(emptyListReplay(ScanEmpty, false, NULL) == 0);
    p = (RecoveryPolicy){.wasJoined = true};
    startWindow(&p, 1000);
    for (int t = 1000; t < 1100; t += 15) {
        observeScan(&p, Searching, t == 1045 ? ScanVisible : ScanEmpty, t);
        assert(decide(&p, Searching, t, true, true, false) != Cycle);
    }
    observeScan(&p, RadioOff, ScanUnknown, 1105);
    assert(!p.empty && decide(&p, RadioOff, 1105, true, false, false) == Wait);
    // a new wake window keeps the cooldown but resets the restart counter
    p = (RecoveryPolicy){.wasJoined = true, .cycles = 3, .nextCycle = 5100};
    startWindow(&p, 5000);
    assert(p.cycles == 0 && p.nextCycle == 5100 && p.wasJoined);
    puts("PASS empty list after minute seven -> 3 radio restarts 2 min apart, visible networks, failed reads, first setup, interrupted empty interval, intentional off");
    puts("PASS late login, delayed init, long sleep, manual off, failed association, hanging join, DHCP, silent router, recovered link resets the counter");
}
