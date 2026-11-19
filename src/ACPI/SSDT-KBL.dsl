/*
 * ASUS ZenBook 13 OLED (UX325EA) - Hotkey & Keyboard Backlight SSDT v5.2
 * Target: Intel Core i7-1165G7 (Tiger Lake), Samsung ATNA33XC01 OLED, Iris Xe in -wexoff mode
 *
 * Requires these OpenCore ACPI->Patch renames (already in config.plist):
 *   DSDT  BRTN+0x09 -> XRTN+0x09   (method header, 1 match)
 *   DSDT  _Q66      -> XQ66        (1 match)
 *
 * v5.2 (2026-11-19): BRTN notifies AsusSMC AND DD1F (see BRTN). v5.1 changes vs v5.0:
 *  1. DD1F is no longer defined unconditionally. The OEM DSDT already declares
 *     External(\_SB.PC00.GFX0.DD1F), so firmware (Intel IgfxSsdt) owns that device.
 *     A second definition triggers AE_ALREADY_EXISTS and can make macOS reject the
 *     whole table (BRTN/SKBV/_Q66 then vanish, so every hotkey goes dead).
 *     DD1F is now created only when firmware did not provide one.
 *  2. BRTN delivers each brightness press over exactly ONE path:
 *       AsusSMC active (ATKP=1)  -> ATKD.IANE(0x10 up / 0x20 down)  (AsusSMC dispatches TopCase key)
 *       otherwise                -> Notify(DD1F, 0x86/0x87)         (BrightnessKeys.kext)
 *     v5.0 fired both, so a single Fn+F4/F5 press could move the slider two steps.
 *  3. SKBV now maps the AsusSMC range 0..255 proportionally to EC levels 0..3.
 *     v5.0 used (Arg0 & 0x7F), so a macOS value of 128 (50%) switched the backlight OFF.
 *  4. _Q66 (Fn+F7) cycles 0 -> 1 -> 2 -> 3 -> 0 deterministically and no longer calls
 *     IANE(0xC4/0xC5). That call made AsusSMC/macOS write SKBV straight back and
 *     override the level that had just been set.
 */

DefinitionBlock ("", "SSDT", 2, "ASUS", "KBL", 0x00001002)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.ATKD.IANE, MethodObj)    // 1 Arguments
    External (_SB_.ATKP, IntObj)
    External (_SB_.PC00.GFX0, DeviceObj)
    External (_SB_.PC00.GFX0.DD1F, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.KBLL, FieldUnitObj)
    External (_SB_.PC00.LPCB.H_EC.ECD2, MethodObj)    // 2 Arguments
    External (_SB_.PC00.LPCB.H_EC.XQ66, MethodObj)    // 0 Arguments
    External (XRTN, MethodObj)              // 1 Arguments
    External (KBLV, FieldUnitObj)
    External (KBLC, FieldUnitObj)
    External (OSYS, FieldUnitObj)

    // =========================================================================
    // 1. Fallback panel device for BrightnessKeys.kext
    //    Created ONLY if firmware did not already define \_SB.PC00.GFX0.DD1F.
    // =========================================================================
    If (_OSI ("Darwin"))
    {
        If (!CondRefOf (\_SB.PC00.GFX0.DD1F))
        {
            Scope (\_SB.PC00.GFX0)
            {
                Device (DD1F)
                {
                    Name (_ADR, 0x0400)  // _ADR: Address
                    Method (_BCL, 0, NotSerialized)  // _BCL: Brightness Control Levels
                    {
                        Return (Package (0x0D)
                        {
                            0x64, 0x64, Zero, 0x0A, 0x14, 0x1E, 0x28,
                            0x32, 0x3C, 0x46, 0x50, 0x5A, 0x64
                        })
                    }

                    Method (_BCM, 1, NotSerialized)  // _BCM: Brightness Control Method
                    {
                    }

                    Method (_BQC, 0, NotSerialized)  // _BQC: Brightness Query Current
                    {
                        Return (0x64)
                    }

                    Method (_DCS, 0, NotSerialized)  // _DCS: Display Current Status
                    {
                        Return (0x1F)
                    }

                    Method (_DGS, 0, NotSerialized)  // _DGS: Display Graphics State
                    {
                        Return (0x0F)
                    }

                    Method (_DSS, 1, NotSerialized)  // _DSS: Device Set State
                    {
                    }
                }
            }
        }
    }

    // =========================================================================
    // 2. Root BRTN replacement (original renamed to XRTN)
    //    _Q15 (Fn+F4) -> QLIB(0x26) -> BRTN(0x87)  brightness down
    //    _Q16 (Fn+F5) -> QLIB(0x27) -> BRTN(0x86)  brightness up
    // =========================================================================
    Method (BRTN, 1, Serialized)
    {
        If (_OSI ("Darwin"))
        {
            Local0 = Zero
            If (CondRefOf (\_SB.ATKD.IANE))
            {
                If (CondRefOf (\_SB.ATKP))
                {
                    If (\_SB.ATKP)
                    {
                        Local0 = One    // AsusSMC has called ATKD.INIT and listens for IANE
                    }
                }
            }

            // v5.2: deliver over BOTH paths. In -wexoff mode macOS has no native
            // backlight, so ZenBookHelper catches whichever event arrives (NX brightness
            // key from AsusSMC, or F14/F15 from BrightnessKeys) and merges duplicates
            // that arrive within 70 ms into one step.
            If (((Arg0 == 0x86) && Local0))
            {
                \_SB.ATKD.IANE (0x10)   // AsusSMC: TopCase Brightness Up
            }
            ElseIf (((Arg0 == 0x87) && Local0))
            {
                \_SB.ATKD.IANE (0x20)   // AsusSMC: TopCase Brightness Down
            }

            If (CondRefOf (\_SB.PC00.GFX0.DD1F))
            {
                Notify (\_SB.PC00.GFX0.DD1F, Arg0)  // BrightnessKeys.kext -> F14/F15
            }
        }
        ElseIf (CondRefOf (\XRTN))
        {
            \XRTN (Arg0)
        }
    }

    // =========================================================================
    // 3. Embedded Controller scope: one writer for the keyboard backlight
    // =========================================================================
    Scope (\_SB.PC00.LPCB.H_EC)
    {
        // Set keyboard backlight level 0..3 using the same EC sequence as ASUS SLKI
        Method (ZKBL, 1, Serialized)
        {
            Local0 = Arg0
            If ((Local0 > 0x03))
            {
                Local0 = 0x03
            }

            If (CondRefOf (\KBLC))
            {
                \KBLC |= 0x80
            }

            KBLL = Local0
            If (CondRefOf (\KBLV))
            {
                \KBLV = Local0
            }

            ECD2 (0x72, 0xB2)
            Return (Local0)
        }

        Device (KBLI)
        {
            Name (_HID, "KBL0001")  // _HID: Hardware ID
            Method (_INI, 0, NotSerialized)  // _INI: Initialize
            {
                If (_OSI ("Darwin"))
                {
                    If (CondRefOf (\OSYS))
                    {
                        \OSYS = 0x07DF  // Windows 2015: QLIB only calls BRTN when OSYS >= 0x07DC
                    }

                    ZKBL (0x02)         // keyboard backlight level 2 at boot
                }
            }
        }

        // Fn+F7: deterministic cycle 0 -> 1 -> 2 -> 3 -> 0 (no AsusSMC round-trip)
        Method (_Q66, 0, Serialized)  // _Qxx: EC Query, xx=0x00-0xFF
        {
            If (_OSI ("Darwin"))
            {
                Local0 = (KBLL & 0x0F)
                Local0++
                If ((Local0 > 0x03))
                {
                    Local0 = Zero
                }

                ZKBL (Local0)
            }
            ElseIf (CondRefOf (\_SB.PC00.LPCB.H_EC.XQ66))
            {
                \_SB.PC00.LPCB.H_EC.XQ66 ()
            }
        }

        // Extra EC brightness queries (not used by the UX325EA EC, kept as harmless fallback)
        Method (_Q0E, 0, NotSerialized)  // _Qxx: EC Query, xx=0x00-0xFF
        {
            If (_OSI ("Darwin"))
            {
                \BRTN (0x87)
            }
        }

        Method (_Q0F, 0, NotSerialized)  // _Qxx: EC Query, xx=0x00-0xFF
        {
            If (_OSI ("Darwin"))
            {
                \BRTN (0x86)
            }
        }
    }

    // =========================================================================
    // 4. AsusSMC keyboard backlight entry point
    //    AsusSMC calls SKBV(LKSB/16): range 0..255. Map proportionally to EC 0..3.
    //    0 -> off, 1..85 -> 1, 86..170 -> 2, 171..255 -> 3
    // =========================================================================
    Scope (\_SB.ATKD)
    {
        Method (SKBV, 1, Serialized)
        {
            Local0 = Arg0
            If ((Local0 > 0xFF))
            {
                Local0 = 0xFF
            }

            Local1 = (((Local0 * 0x03) + 0xFE) / 0xFF)
            Return (\_SB.PC00.LPCB.H_EC.ZKBL (Local1))
        }
    }
}
