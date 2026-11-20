// UX325EA internal keyboard; the active PNP0303-compatible device is LPCB.PS2K.
// VoodooPS2 2.3.7 reads RMCF through the controller's ACPI parent at probe.
DefinitionBlock ("", "SSDT", 2, "ZENBK", "PS2KEYS", 1)
{
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC._Q66, MethodObj)

    Scope (\_SB.PC00.LPCB.PS2K)
    {
        Name (RMCF, Package ()
        {
            "Keyboard", Package ()
            {
                "Custom PS2 Map", Package ()
                {
                    Package () {},  // VoodooPS2's array marker
                    "e027=0",       // retain stock disabled discrete Fn toggle
                    "e028=0",       // retain stock disabled discrete trackpad toggle
                    "3b=e020",      // F1 -> mute
                    "3c=e02e",      // F2 -> volume down
                    "3d=e030",      // F3 -> volume up
                    "3e=65",        // F4 -> brightness down (F14)
                    "3f=66",        // F5 -> brightness up (F15)
                    "41=e0f7"       // F7 -> RKA7
                }
            }
        })

        // VoodooPS2 calls RKA7 on both edges. Cycle the illumination once per press.
        Method (RKA7, 1, Serialized)
        {
            If (Arg0 && _OSI ("Darwin"))
            {
                \_SB.PC00.LPCB.H_EC._Q66 ()
            }
        }
    }
}
