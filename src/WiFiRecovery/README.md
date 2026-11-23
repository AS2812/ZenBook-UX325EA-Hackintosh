# Wi-Fi recovery 2.1 (itlwm + HeliPort)

| File | Role |
|---|---|
| `WakeCheck.m` | login agent (every 15 s and after each wake), the root `--retry-ip` DHCP job and the **ZenBook Wi-Fi Repair** app (one binary) |
| `RecoveryPolicy.h` | pure decision logic: open HeliPort, rescan, radio on, radio restart, wait |
| `test-recovery.c` | replays of login, wake, empty network list, stalls and manual off against the policy |
| `ConfigureEFI.swift` | enables itlwm, disables AirportItlwm, drops `-novht` / `-noht40` in every `config*.plist`, runs `ocvalidate`, backs up and reads back |
| `itlwm-api/` | itlwm 2.3 user-client structures from HeliPort's ClientKit (BSD-3-Clause, see `LICENSE`) |

```sh
clang -Wall -Werror test-recovery.c -o /tmp/test-recovery && /tmp/test-recovery
clang -target x86_64-apple-macos14.0 -fobjc-arc -Wall -Werror -framework Cocoa \
      -framework SystemConfiguration -framework IOKit WakeCheck.m -o WakeCheck
./WakeCheck --status          # driver / radio / link state, read only
```

The packaged installer additionally checks that it runs on the intended internal SSD before it
touches the EFI partition; that guard is specific to one machine and is not published.
