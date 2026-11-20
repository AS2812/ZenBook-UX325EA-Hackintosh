/*
 * ASUS ZenBook 13 OLED (UX325EA) - wake / shutdown / hotkey / lid SSDT v1.9 (2026-11-20)
 *
 * Requires these OpenCore ACPI->Patch renames (DSDT only, 1 match each):
 *   14 06 "XPTS" 01 -> 14 06 "YPTS" 01   (ASUS' empty XPTS hook, called from _PTS)
 *   14 06 "XWAK" 01 -> 14 06 "YWAK" 01   (ASUS' empty XWAK hook, called last in _WAK)
 *   "IANE" 09       -> "XANE" 09         (ATKD.IANE method header: queue + Notify of ASUS hotkeys)
 *   "WMNB" 0B       -> "XMNB" 0B         (ATKD.WMNB: ASUS WMI entry used by AsusSMC)
 *
 * Fn volume / mute (and the other ASUS keys) travel through a 16-entry event queue in
 * ATKD: IANE puts the key code in the queue and sends ONE Notify; AsusSMC answers every
 * Notify by taking ONE entry (_WED -> GANQ). If a Notify is lost (sleep / wake), an old
 * entry stays behind for good and every later key press delivers the PREVIOUS key's code:
 * after sleep volume and mute seem dead. (Brightness also uses another path, so it kept
 * working - exactly what the v9.7 test showed.)
 *
 * v1.2: the v9.8 test showed volume/mute still dead after sleep while brightness (which goes
 *       Notify(DD1F) -> BrightnessKeys -> PS/2 keyboard) kept working. Volume up / down / mute
 *       (ATK 0x30 / 0x31 / 0x32) now take that same proven path: Notify(DD1F, 0x90/0x91/0x92),
 *       handled by BrightnessKeys-UX325.kext (adds these 3 codes -> PS/2 keyboard ADB
 *       0x48/0x49/0x4A = sound up / down / mute). AsusSMC no longer gets them (no double).
 *
 * v1.3: lid open = black screen. Kernel log of the failed test: clamshell sleep 11:58:59,
 *       resume 11:59:29 / :44 / :54 (FullWake on a key press) - all with "clamshell closed 1",
 *       "Clamshell opened" only after the restart. macOS re-reads the lid only after a
 *       Notify(LID0); the EC "lid open" query that woke the laptop was lost during resume, so
 *       macOS kept the lid "closed" and the internal screen off. XWAK now sends Notify(LID0,
 *       0x80) on every wake: macOS evaluates _LID, which reads the EC hall sensor (LSTE).
 *
 * v1.4: after a lid wake the screen came back (v1.3) but every Fn key stayed dead. The EC
 *       delivers events one at a time: it raises SCI_EVT and waits until the OS reads the event
 *       (QR_EC). The lid-open event that woke the laptop is not read during resume, so the EC
 *       keeps waiting and never reports anything newer (Fn keys, AC, battery). Power-button
 *       wakes (fixed event, not EC) never had the problem. XWAK now drains pending EC events
 *       like Linux does after resume (ZECD: up to 8, via the EC's own status/command ports
 *       that the DSDT itself uses in ECD2) and forwards lid / AC / battery ones as Notify.
 *
 * v1.5: v1.4 drained the stuck lid event on wake (two "Clamshell opened"), but afterwards macOS
 *       still received no EC event at all (no lid close -> no 2nd sleep, no Fn keys): its EC
 *       event channel itself stays dead after a lid wake. Fallback: BrightnessKeys-UX325 calls
 *       DD1F.ZECP every 300 ms. If the EC has had an event waiting (SCI_EVT) for 2 polls in a
 *       row - macOS would have taken it within milliseconds - ZECQ reads it (QR_EC) and runs the
 *       firmware's own _Qxx handler. With a healthy macOS channel it never intervenes.
 *
 * v1.6: v1.5 test: the poll found nothing waiting - after a lid wake the EC itself sends no
 *       events (no lid close: the 2nd sleep was "Idle Sleep"; no Fn keys). This firmware is
 *       built for Modern Standby: on lid close / open Windows sends PEPD._DSM display off / on,
 *       which calls H_EC.ECNT(1) / ECNT(0) = EC commands 0x5D / 0x5E (low power enter / exit).
 *       macOS uses S3 and never sends "exit", so after a lid-closed sleep the EC stays in low
 *       power. XWAK now calls ECNT(0) like the display-on notification. ZDIA (read by
 *       BrightnessKeys-UX325 after each wake) records the EC state for diagnosis.
 *
 * v1.7: ROOT CAUSE of the dead keys after a lid wake. The v1.6 EC snapshot after a wake showed
 *       ATKP = 0 and OSDT = 0: the ASUS hotkey registration had NEVER run. AsusSMC calls WMNB
 *       with an 8-byte argument buffer, but WMNB creates five DWORD fields (IIA0..IIA4, 20 bytes)
 *       and aborts with AE_AML_BUFFER_LIMIT before INIT (reproduced in acpiexec) - so the EC ran
 *       in its "no OS driver" fallback the whole time, and that fallback does not come back
 *       after a lid-closed sleep. The WMNB wrapper pads the argument to 32 bytes, so AsusSMC's
 *       INIT sets ATKP = 1 / OSDT = 1 like the Windows ATK driver. AsusSMC's battery
 *       "conservative mode" (charge limit 80%) is NOT passed on: charging stays as it was.
 *
 * v1.8: v1.7 test: AsusSMC now registers (ATKP 1, OSDT 1) and volume works, but after a lid
 *       wake the EC still flags no events (status 0x08) - no lid close, no Fn keys - while its
 *       hall sensor (LSTE) does follow the lid. ZECQ (polled from the wake until the next sleep):
 *       (a) LSTE changed -> Notify(LID0): lid close / open work without EC events;
 *       (b) once a second a QR_EC even without SCI_EVT: events the EC queued but did not
 *           announce are delivered to the firmware's _Qxx handlers.
 *
 * v1.9: lid now sleeps every time (sensor poll), but after a lid wake Fn+F1/F4/F5/F7 type
 *       plain function keys: the EC forgets the ASUS Fn-lock state (WMI device 0x00100023,
 *       EC byte FEST, applied with EC command 0x72 / 0xB3) in a lid-closed sleep. Linux
 *       asus-wmi re-applies Fn-lock on every resume (asus_hotk_resume -> fnlock_update); now
 *       XPTS(3) saves FEST and XWAK + the first 10 s of the poll write it back.
 *
 * 1. IANE: an entry still waiting when a new key arrives is stale -> empty the queue first.
 * 2. XWAK: after every wake empty the queue and call ATKD.INIT again (as Windows does).
 * 3. XPTS(5): on Shut Down, the USB controller may not wake the laptop straight back up.
 */
DefinitionBlock ("", "SSDT", 2, "ZENBK", "WAKE", 0x00001900)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.ATKD.INIT, MethodObj)        // 1 Arguments
    External (_SB_.ATKD.XANE, MethodObj)        // 1 Arguments (renamed DSDT IANE)
    External (_SB_.ATKD.XMNB, MethodObj)        // 3 Arguments (renamed DSDT WMNB)
    External (_SB_.ATKD.AQNO, IntObj)
    External (_SB_.ATKD.AQHI, IntObj)
    External (_SB_.ATKD.AQTI, IntObj)
    External (_SB_.ATKP, IntObj)
    External (_SB_.PC00.XHCI.PMEE, FieldUnitObj)
    External (_SB_.PC00.GFX0.DD1F, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.LID0, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.ADP1, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.BAT0, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.EC62, FieldUnitObj)  // EC data port 0x62
    External (_SB_.PC00.LPCB.H_EC.EC66, FieldUnitObj)  // EC status / command port 0x66
    External (ECUP, IntObj)
    External (ECNO, FieldUnitObj)                       // GNVS: EC low-power notifications used
    External (_SB_.PC00.LPCB.H_EC.ECNT, MethodObj)      // 1 Arguments: 0 = display on / EC exit low power
    External (_SB_.PC00.LPCB.H_EC.OSTP, FieldUnitObj)
    External (_SB_.PC00.LPCB.H_EC.OSDT, FieldUnitObj)
    External (_SB_.PC00.LPCB.H_EC.LSTE, FieldUnitObj)
    External (_SB_.PC00.LPCB.H_EC.FEST, FieldUnitObj)  // ASUS Fn-lock state (EC 0xB3)
    External (_SB_.PC00.LPCB.H_EC.ECD2, MethodObj)     // 2 Arguments: EC command + data
    External (_SB_.PC00.LPCB.H_EC._Q0A, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q0B, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q0C, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q0D, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q12, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q13, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q14, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q15, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q16, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q17, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q18, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q19, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q1A, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q1B, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q1C, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q20, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q21, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q22, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q23, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q30, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q33, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q3E, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q3F, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q46, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q50, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q51, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q52, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q53, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q60, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q61, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q62, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q63, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q66, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q79, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q80, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q85, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q86, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q90, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._Q9D, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._QA0, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._QA1, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._QA2, MethodObj)    // 0 Arguments
    External (_SB_.PC00.LPCB.H_EC._QF8, MethodObj)    // 0 Arguments

    Scope (\_SB.PC00.LPCB.H_EC)
    {
        Name (ZEDC, Zero)                       // EC events drained after wakes (diagnostics)
        Name (ZEQL, Zero)                       // last drained EC event
        Name (ZEQS, Zero)                       // stale output byte discarded before a query

        Name (ZENC, Zero)                       // ECNT(0) calls after wakes (diagnostics)
        Name (ZSCN, Zero)                       // polls in a row that saw an EC event waiting
        Name (ZLST, Ones)                       // last hall sensor value seen by the poll
        Name (ZLCN, Zero)                       // lid changes delivered by the poll (diagnostics)
        Name (ZBQC, Zero)                       // poll counter (blind query every 4th poll)
        Name (ZBQH, Zero)                       // events found by blind queries (diagnostics)
        Name (ZFNS, Zero)                       // Fn-lock state saved before sleep
        Name (ZFNV, Zero)                       // ZFNS valid
        Name (ZFNW, Zero)                       // polls left that re-check Fn-lock after a wake
        Name (ZFNC, Zero)                       // Fn-lock re-applications (diagnostics)

        Method (ZFNA, 0, Serialized)            // write the saved Fn-lock state back to the EC
        {
            If ((ZFNV && (CondRefOf (\_SB.PC00.LPCB.H_EC.FEST) && CondRefOf (\_SB.PC00.LPCB.H_EC.ECD2))))
            {
                \_SB.PC00.LPCB.H_EC.FEST = ZFNS
                \_SB.PC00.LPCB.H_EC.ECD2 (0x72, 0xB3)
                ZFNC++
            }
        }
        Name (ZPDC, Zero)                       // EC events delivered by the poll (diagnostics)

        Method (ZEQD, 1, Serialized)            // after a wake: forward a drained lid / AC / battery event
        {
            If ((((Arg0 == 0x0C) || (Arg0 == 0x0D)) || (Arg0 == 0x80)))
            {
                If (CondRefOf (\_SB.PC00.LPCB.H_EC.LID0))
                {
                    Notify (\_SB.PC00.LPCB.H_EC.LID0, 0x80) // lid open / close / refresh
                }
            }
            ElseIf ((Arg0 == 0x0A))
            {
                If (CondRefOf (\_SB.PC00.LPCB.H_EC.ADP1))
                {
                    Notify (\_SB.PC00.LPCB.H_EC.ADP1, 0x80) // AC adapter
                }

                If (CondRefOf (\_SB.PC00.LPCB.H_EC.BAT0))
                {
                    Notify (\_SB.PC00.LPCB.H_EC.BAT0, 0x81)
                }
            }
            ElseIf ((((Arg0 == 0x0B) || (Arg0 == 0x90)) || (Arg0 == 0xA1)))
            {
                If (CondRefOf (\_SB.PC00.LPCB.H_EC.BAT0))
                {
                    Notify (\_SB.PC00.LPCB.H_EC.BAT0, 0x80) // battery
                    Notify (\_SB.PC00.LPCB.H_EC.BAT0, 0x81)
                }
            }
        }

        Method (ZQRN, 1, Serialized)            // run the firmware's handler for EC event Arg0
        {
            Switch (ToInteger (Arg0))
            {
                Case (0x0A)
                {
                    \_SB.PC00.LPCB.H_EC._Q0A ()
                }
                Case (0x0B)
                {
                    \_SB.PC00.LPCB.H_EC._Q0B ()
                }
                Case (0x0C)
                {
                    \_SB.PC00.LPCB.H_EC._Q0C ()
                }
                Case (0x0D)
                {
                    \_SB.PC00.LPCB.H_EC._Q0D ()
                }
                Case (0x12)
                {
                    \_SB.PC00.LPCB.H_EC._Q12 ()
                }
                Case (0x13)
                {
                    \_SB.PC00.LPCB.H_EC._Q13 ()
                }
                Case (0x14)
                {
                    \_SB.PC00.LPCB.H_EC._Q14 ()
                }
                Case (0x15)
                {
                    \_SB.PC00.LPCB.H_EC._Q15 ()
                }
                Case (0x16)
                {
                    \_SB.PC00.LPCB.H_EC._Q16 ()
                }
                Case (0x17)
                {
                    \_SB.PC00.LPCB.H_EC._Q17 ()
                }
                Case (0x18)
                {
                    \_SB.PC00.LPCB.H_EC._Q18 ()
                }
                Case (0x19)
                {
                    \_SB.PC00.LPCB.H_EC._Q19 ()
                }
                Case (0x1A)
                {
                    \_SB.PC00.LPCB.H_EC._Q1A ()
                }
                Case (0x1B)
                {
                    \_SB.PC00.LPCB.H_EC._Q1B ()
                }
                Case (0x1C)
                {
                    \_SB.PC00.LPCB.H_EC._Q1C ()
                }
                Case (0x20)
                {
                    \_SB.PC00.LPCB.H_EC._Q20 ()
                }
                Case (0x21)
                {
                    \_SB.PC00.LPCB.H_EC._Q21 ()
                }
                Case (0x22)
                {
                    \_SB.PC00.LPCB.H_EC._Q22 ()
                }
                Case (0x23)
                {
                    \_SB.PC00.LPCB.H_EC._Q23 ()
                }
                Case (0x30)
                {
                    \_SB.PC00.LPCB.H_EC._Q30 ()
                }
                Case (0x33)
                {
                    \_SB.PC00.LPCB.H_EC._Q33 ()
                }
                Case (0x3E)
                {
                    \_SB.PC00.LPCB.H_EC._Q3E ()
                }
                Case (0x3F)
                {
                    \_SB.PC00.LPCB.H_EC._Q3F ()
                }
                Case (0x46)
                {
                    \_SB.PC00.LPCB.H_EC._Q46 ()
                }
                Case (0x50)
                {
                    \_SB.PC00.LPCB.H_EC._Q50 ()
                }
                Case (0x51)
                {
                    \_SB.PC00.LPCB.H_EC._Q51 ()
                }
                Case (0x52)
                {
                    \_SB.PC00.LPCB.H_EC._Q52 ()
                }
                Case (0x53)
                {
                    \_SB.PC00.LPCB.H_EC._Q53 ()
                }
                Case (0x60)
                {
                    \_SB.PC00.LPCB.H_EC._Q60 ()
                }
                Case (0x61)
                {
                    \_SB.PC00.LPCB.H_EC._Q61 ()
                }
                Case (0x62)
                {
                    \_SB.PC00.LPCB.H_EC._Q62 ()
                }
                Case (0x63)
                {
                    \_SB.PC00.LPCB.H_EC._Q63 ()
                }
                Case (0x66)
                {
                    \_SB.PC00.LPCB.H_EC._Q66 ()
                }
                Case (0x79)
                {
                    \_SB.PC00.LPCB.H_EC._Q79 ()
                }
                Case (0x80)
                {
                    \_SB.PC00.LPCB.H_EC._Q80 ()
                }
                Case (0x85)
                {
                    \_SB.PC00.LPCB.H_EC._Q85 ()
                }
                Case (0x86)
                {
                    \_SB.PC00.LPCB.H_EC._Q86 ()
                }
                Case (0x90)
                {
                    \_SB.PC00.LPCB.H_EC._Q90 ()
                }
                Case (0x9D)
                {
                    \_SB.PC00.LPCB.H_EC._Q9D ()
                }
                Case (0xA0)
                {
                    \_SB.PC00.LPCB.H_EC._QA0 ()
                }
                Case (0xA1)
                {
                    \_SB.PC00.LPCB.H_EC._QA1 ()
                }
                Case (0xA2)
                {
                    \_SB.PC00.LPCB.H_EC._QA2 ()
                }
                Case (0xF8)
                {
                    \_SB.PC00.LPCB.H_EC._QF8 ()
                }
            }
        }

        Method (ZECO, 0, NotSerialized)         // EC ports usable?
        {
            If (!(CondRefOf (\_SB.PC00.LPCB.H_EC.EC66) && CondRefOf (\_SB.PC00.LPCB.H_EC.EC62)))
            {
                Return (Zero)
            }

            If (CondRefOf (\ECUP))
            {
                If (!\ECUP)
                {
                    Return (Zero)               // EC in low-power mode (firmware's own ECD2 rule)
                }
            }

            Return (One)
        }

        Method (ZECR, 0, Serialized)            // one QR_EC transaction: event number, Ones = failed
        {
            Local1 = 0x03E8
            While (((EC66 & 0x02) && Local1))
            {
                Stall (0x32)                    // input buffer busy (max ~50 ms, busy-wait)
                Local1--
            }

            If ((EC66 & 0x02))
            {
                Return (Ones)
            }

            If ((EC66 & One))
            {
                ZEQS = EC62                     // discard a stale byte in the output buffer
            }

            EC66 = 0x84                         // QR_EC
            Local1 = 0x03E8
            While ((!(EC66 & One) && Local1))
            {
                Stall (0x32)                    // wait for the answer (max ~50 ms)
                Local1--
            }

            If (!(EC66 & One))
            {
                Return (Ones)
            }

            Return (EC62)
        }

        Method (ZECD, 0, Serialized)            // on wake: drain events left pending across resume
        {
            If (!ZECO ())
            {
                Return (Zero)
            }

            Local7 = Zero
            Local0 = 0x08
            While ((Local0 && (EC66 & 0x20)))
            {
                Local0--
                Local2 = ZECR ()
                If ((Local2 == Ones))
                {
                    Break
                }

                Local7++
                ZEQL = Local2
                ZEQD (Local2)                   // stale key presses from before the wake are dropped
            }

            ZEDC += Local7
            Return (Local7)
        }

        Method (ZECQ, 0, Serialized)            // poll: deliver what macOS did not get
        {
            If (!ZECO ())
            {
                Return (Zero)
            }

            Local7 = Zero
            If (CondRefOf (\_SB.PC00.LPCB.H_EC.LSTE))   // (a) lid from the hall sensor
            {
                Local3 = \_SB.PC00.LPCB.H_EC.LSTE
                If ((Local3 != ZLST))
                {
                    ZLST = Local3
                    ZLCN++
                    If (CondRefOf (\_SB.PC00.LPCB.H_EC.LID0))
                    {
                        Notify (\_SB.PC00.LPCB.H_EC.LID0, 0x80) // macOS re-reads _LID
                    }
                }
            }

            If (ZFNW)                           // Fn-lock reset late by the EC?
            {
                ZFNW--
                If ((ZFNV && CondRefOf (\_SB.PC00.LPCB.H_EC.FEST)))
                {
                    If ((\_SB.PC00.LPCB.H_EC.FEST != ZFNS))
                    {
                        ZFNA ()
                    }
                }
            }

            ZBQC++
            If ((EC66 & 0x20))
            {
                ZSCN++
            }
            Else
            {
                ZSCN = Zero
            }

            Local4 = Zero                       // blind query (b): SCI_EVT not set
            If ((ZSCN >= 0x02))
            {
                ZSCN = Zero
            }
            ElseIf (((ZBQC & 0x03) == Zero))
            {
                Local4 = One
            }
            Else
            {
                Return (Zero)
            }

            Local0 = 0x08
            While (Local0)
            {
                Local0--
                Local2 = ZECR ()
                If (((Local2 == Ones) || (Local2 == Zero)))
                {
                    Break                       // failed / no event
                }

                Local7++
                ZEQL = Local2
                If (Local4)
                {
                    ZBQH++
                }

                ZQRN (Local2)
                If (!(EC66 & 0x20))
                {
                    If (!Local4)
                    {
                        Break
                    }
                }
            }

            ZPDC += Local7
            Return (Local7)
        }
    }
    External (YPTS, MethodObj)                  // 1 Arguments (renamed DSDT XPTS)
    External (YWAK, MethodObj)                  // 1 Arguments (renamed DSDT XWAK)

    Scope (\_SB.ATKD)
    {
        Name (ZQFL, Zero)                       // number of queue resets (diagnostics)
        Name (ZWMC, Zero)                       // WMNB calls (diagnostics)

        Method (WMNB, 3, Serialized)            // ASUS WMI entry: pad short argument buffers
        {
            ZWMC++
            Local0 = Buffer (0x20) {}
            If ((ObjectType (Arg2) == One))     // integer argument: first DWORDs of the buffer
            {
                CreateQWordField (Local0, Zero, ZQW0)
                ZQW0 = Arg2
            }
            ElseIf ((ObjectType (Arg2) == 0x03))
            {
                Local1 = SizeOf (Arg2)
                If ((Local1 > 0x20))
                {
                    Local1 = 0x20
                }

                Local2 = Zero
                While ((Local2 < Local1))
                {
                    Local0 [Local2] = DerefOf (Arg2 [Local2])
                    Local2++
                }
            }
            Else
            {
                Return (\_SB.ATKD.XMNB (Arg0, Arg1, Arg2))
            }

            // DEVS (0x53564544) of device 0x00120057 = battery charge limit: keep the user's setting
            CreateDWordField (Local0, Zero, ZID0)
            If ((((Arg1 & 0xFFFFFFFF) == 0x53564544) && (ZID0 == 0x00120057)))
            {
                Return (One)
            }

            Return (\_SB.ATKD.XMNB (Arg0, Arg1, Local0))
        }

        Method (ZQRS, 0, Serialized)            // empty the ATK event queue (initial state)
        {
            If ((CondRefOf (\_SB.ATKD.AQNO) && CondRefOf (\_SB.ATKD.AQTI)))
            {
                If ((\_SB.ATKD.AQNO != Zero))
                {
                    ZQFL++
                }

                \_SB.ATKD.AQNO = Zero
                \_SB.ATKD.AQHI = Zero
                \_SB.ATKD.AQTI = 0x0F
            }
        }

        Name (ZVOL, Zero)                       // volume/mute keys sent to BrightnessKeys (diagnostics)
        Name (ZLWK, Zero)                       // v1.3: Fn presses left that re-check the lid after a wake

        Method (IANE, 1, Serialized)
        {
            If (_OSI ("Darwin"))
            {
                // v1.3: black screen after lid open = macOS still thinks the lid is closed.
                // The first Fn presses after a wake make macOS re-read the lid sensor again.
                If ((ZLWK && CondRefOf (\_SB.PC00.LPCB.H_EC.LID0)))
                {
                    ZLWK--
                    Notify (\_SB.PC00.LPCB.H_EC.LID0, 0x80) // Status Change
                }

                If ((((Arg0 == 0x30) || (Arg0 == 0x31)) || (Arg0 == 0x32)))
                {
                    If (CondRefOf (\_SB.PC00.GFX0.DD1F))
                    {
                        ZVOL++
                        If ((Arg0 == 0x30))
                        {
                            Notify (\_SB.PC00.GFX0.DD1F, 0x90) // volume up
                        }
                        ElseIf ((Arg0 == 0x31))
                        {
                            Notify (\_SB.PC00.GFX0.DD1F, 0x91) // volume down
                        }
                        Else
                        {
                            Notify (\_SB.PC00.GFX0.DD1F, 0x92) // mute
                        }

                        Return (Zero)
                    }
                }

                If (CondRefOf (\_SB.ATKD.AQNO))
                {
                    If ((\_SB.ATKD.AQNO != Zero))
                    {
                        ZQRS ()
                    }
                }
            }

            \_SB.ATKD.XANE (Arg0)
            Return (Zero)
        }
    }

    Scope (\_SB.PC00.GFX0.DD1F)
    {
        Method (ZDIA, 0, Serialized)            // EC state for BrightnessKeys-UX325 (property UX325ECDiag)
        {
            Local0 = Package (0x11)
                {
                    Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones, Ones
                }
            If (CondRefOf (\ECNO))
            {
                Local0 [Zero] = \ECNO
            }

            If (CondRefOf (\ECUP))
            {
                Local0 [One] = \ECUP
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.EC66))
            {
                Local0 [0x02] = \_SB.PC00.LPCB.H_EC.EC66
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.OSTP))
            {
                Local0 [0x03] = \_SB.PC00.LPCB.H_EC.OSTP
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.OSDT))
            {
                Local0 [0x04] = \_SB.PC00.LPCB.H_EC.OSDT
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.LSTE))
            {
                Local0 [0x05] = \_SB.PC00.LPCB.H_EC.LSTE
            }

            If (CondRefOf (\_SB.ATKP))
            {
                Local0 [0x06] = \_SB.ATKP
            }

            Local0 [0x07] = \_SB.PC00.LPCB.H_EC.ZENC
            Local0 [0x08] = \_SB.PC00.LPCB.H_EC.ZEDC
            Local0 [0x09] = \_SB.PC00.LPCB.H_EC.ZEQL
            Local0 [0x0A] = \_SB.PC00.LPCB.H_EC.ZPDC
            Local0 [0x0B] = \_SB.ATKD.ZQFL
            Local0 [0x0C] = \_SB.PC00.LPCB.H_EC.ZLCN
            Local0 [0x0D] = \_SB.PC00.LPCB.H_EC.ZBQH
            If (CondRefOf (\_SB.PC00.LPCB.H_EC.FEST))
            {
                Local0 [0x0E] = \_SB.PC00.LPCB.H_EC.FEST
            }

            Local0 [0x0F] = \_SB.PC00.LPCB.H_EC.ZFNS
            Local0 [0x10] = \_SB.PC00.LPCB.H_EC.ZFNC
            Return (Local0)
        }

        Method (ZECP, 0, Serialized)            // polled by BrightnessKeys-UX325 every 300 ms
        {
            If (_OSI ("Darwin"))
            {
                If (CondRefOf (\_SB.PC00.LPCB.H_EC.ZECQ))
                {
                    Return (\_SB.PC00.LPCB.H_EC.ZECQ ())
                }
            }

            Return (Zero)
        }
    }

    Method (XPTS, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
            If (((Arg0 == 0x03) && CondRefOf (\_SB.PC00.LPCB.H_EC.FEST)))
            {
                \_SB.PC00.LPCB.H_EC.ZFNS = \_SB.PC00.LPCB.H_EC.FEST   // Fn-lock before sleep
                \_SB.PC00.LPCB.H_EC.ZFNV = One
            }

            If ((Arg0 == 0x05))
            {
                If (CondRefOf (\_SB.PC00.XHCI.PMEE))
                {
                    \_SB.PC00.XHCI.PMEE = Zero
                }
            }
        }

        If (CondRefOf (\YPTS))
        {
            \YPTS (Arg0)
        }
    }

    Method (XWAK, 1, NotSerialized)
    {
        If (CondRefOf (\YWAK))
        {
            \YWAK (Arg0)
        }

        If (_OSI ("Darwin"))
        {
            If (CondRefOf (\_SB.PC00.LPCB.H_EC.ECNT))
            {
                \_SB.PC00.LPCB.H_EC.ECNT (Zero)    // "display on": EC leaves low power (Windows does this)
                \_SB.PC00.LPCB.H_EC.ZENC++
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.ZECD))
            {
                \_SB.PC00.LPCB.H_EC.ZECD ()
            }

            \_SB.ATKD.ZQRS ()
            If (CondRefOf (\_SB.ATKD.INIT))
            {
                If (CondRefOf (\_SB.ATKP))
                {
                    If (\_SB.ATKP)
                    {
                        \_SB.ATKD.INIT (One)
                    }
                }
            }

            If (CondRefOf (\_SB.PC00.LPCB.H_EC.LID0))
            {
                Notify (\_SB.PC00.LPCB.H_EC.LID0, 0x80) // Status Change -> macOS re-reads _LID (hall sensor)
            }

            \_SB.PC00.LPCB.H_EC.ZFNA ()           // Fn-lock back as before sleep (Linux asus-wmi does this)
            \_SB.PC00.LPCB.H_EC.ZFNW = 0x21       // and re-check for ~10 s in the poll
            \_SB.ATKD.ZLWK = 0x1E                 // and again on the next 30 Fn presses
            If (CondRefOf (\_SB.PC00.LPCB.H_EC.LSTE))
            {
                \_SB.PC00.LPCB.H_EC.ZLST = \_SB.PC00.LPCB.H_EC.LSTE
            }
        }
    }
}
