/*
 * ASUS ZenBook 13 OLED (UX325EA) - wake / shutdown / hotkey SSDT v1.2 (2026-11-20)
 *
 * Requires these OpenCore ACPI->Patch renames (DSDT only, 1 match each):
 *   14 06 "XPTS" 01 -> 14 06 "YPTS" 01   (ASUS' empty XPTS hook, called from _PTS)
 *   14 06 "XWAK" 01 -> 14 06 "YWAK" 01   (ASUS' empty XWAK hook, called last in _WAK)
 *   "IANE" 09       -> "XANE" 09         (ATKD.IANE method header: queue + Notify of ASUS hotkeys)
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
 * 1. IANE: an entry still waiting when a new key arrives is stale -> empty the queue first.
 * 2. XWAK: after every wake empty the queue and call ATKD.INIT again (as Windows does).
 * 3. XPTS(5): on Shut Down, the USB controller may not wake the laptop straight back up.
 */
DefinitionBlock ("", "SSDT", 2, "ZENBK", "WAKE", 0x00001200)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.ATKD.INIT, MethodObj)        // 1 Arguments
    External (_SB_.ATKD.XANE, MethodObj)        // 1 Arguments (renamed DSDT IANE)
    External (_SB_.ATKD.AQNO, IntObj)
    External (_SB_.ATKD.AQHI, IntObj)
    External (_SB_.ATKD.AQTI, IntObj)
    External (_SB_.ATKP, IntObj)
    External (_SB_.PC00.XHCI.PMEE, FieldUnitObj)
    External (_SB_.PC00.GFX0.DD1F, DeviceObj)
    External (YPTS, MethodObj)                  // 1 Arguments (renamed DSDT XPTS)
    External (YWAK, MethodObj)                  // 1 Arguments (renamed DSDT XWAK)

    Scope (\_SB.ATKD)
    {
        Name (ZQFL, Zero)                       // number of queue resets (diagnostics)

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

        Method (IANE, 1, Serialized)
        {
            If (_OSI ("Darwin"))
            {
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

    Method (XPTS, 1, NotSerialized)
    {
        If (_OSI ("Darwin"))
        {
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
        }
    }
}
