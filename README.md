# Vitals

A menu bar app for this Mac (MacBook Pro 14-inch, M5) that shows what the hardware is doing. Built 2026-10-29.

The menu bar shows the hottest spot on the chip (`44°`); the thermometer icon becomes a fan while the fan spins.
Click it for the panel:

- **Temperatures**: hottest chip sensor, a 5-minute graph, chip average, SSD, battery. "All sensors…" opens a window
  with every sensor live.
- **Fan**: off, or rpm and % of max speed (this Mac's one fan runs 2,317 to 6,550 rpm and often sits fully off).
- **Power**: whole-Mac power draw in watts; battery %, charging state, charger watts, health, charge cycles.
- **CPU** per core (4 Super + 6 Efficiency), **GPU**, **memory** (used, pressure, swap), **disk**, **network** speed.
- **Busiest apps** by CPU (100% = one full core, as in Activity Monitor). macOS's own state: Cool / Warm / Hot.

Orange is the only colour and means one thing: running hot or under strain.

## Build and install

```bash
./build.sh install   # builds, copies to ~/Applications/Vitals.app, starts it
```

Swift package, no Xcode project. `Sources/Sensors` (C) reads the hardware, `Sources/Vitals` is the app.

## Where the numbers come from

| Reading | Source | Needs a password? |
|---|---|---|
| Temperatures | Apple silicon's named sensors via the private `IOHIDEventSystemClient` API ("PMU tdie" = on the chip, "NAND" = SSD, "gas gauge" = battery) | No |
| Fan, power draw | The SMC (system management controller): keys `FNum`, `F0Ac`, `F0Mn`, `F0Mx`, `PSTR` | No |
| Battery | `AppleSmartBattery` in the IO registry; health from `system_profiler SPPowerDataType` (matches System Settings) | No |
| CPU, memory, swap | Mach `host_processor_info`, `host_statistics64`, `vm.swapusage` (memory shown in 1024s, like Activity Monitor) | No |
| GPU | `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` | No |
| Network | `getifaddrs` byte counters on the `en*` interfaces (Wi-Fi and wired) | No |
| Busiest apps | `ps -Aceo pid,pcpu,comm -r` | No |

Checked against the system's own tools on 2026-10-29: CPU vs `top`, battery vs `pmset`, swap vs `sysctl`, disk vs
`df`, network vs `netstat` (app 1.2 MB/s, netstat 1,241 KB/s).

Private API risk: the temperature API is undocumented. A future macOS could rename or remove sensors; the panel then
shows `--` instead of a number.

## What it costs the Mac

Measured with the built-in benchmark (`getrusage`, own CPU plus the `ps` it starts, 60 s each, 2026-10-29):

| State | Updates | CPU |
|---|---|---|
| Panel closed (almost always) | chip temperature + fan, every 5 s | **0.2% of one core** |
| Panel open | everything, every 2 s | **2% of one core**, plus drawing the panel (not measured) |

Not measured: battery drain in watts directly. The timer has a tolerance so macOS can batch its wake-ups with others.

## Test switches (off unless set at launch)

```bash
open --env VITALS_SNAPSHOT=/some/folder ~/Applications/Vitals.app   # opens the panel, saves readings.txt + PNGs
open -W --env VITALS_BENCH=closed --env VITALS_BENCH_OUT=/some/file ~/Applications/Vitals.app   # or =open
```

## Not tested yet

- The "Open at login" checkbox (registering a login item is a change to his Mac's settings, so it was left to him).
- The fan-spinning view and the orange "hot" colours: the fan stayed off and nothing ran hot during testing.
