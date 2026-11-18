# Topbarac spec

macOS port of the GNOME extension Topbar Resource, with management tools on top. Decisions agreed on 2026-11-18.

## Scope

- Name Topbarac, bundle ID `com.farvisun.topbarac`, English UI (strings ready for a String Catalog later).
- macOS 26+ only, Liquid Glass, Swift 6.2, SwiftPM (no Xcode project), universal binary.
- Distribution: non-sandboxed, ad-hoc signed DMG/zip on GitHub Releases, Sparkle updates, Homebrew cask in
  `farvisun/homebrew-tap`, landing page in `site/` on GitHub Pages. Notarization later, once a Developer ID exists.
- Widgets: CPU, Memory, Disk, Temperature + fans (read-only, never writes the SMC), GPU, Network, Battery.
- Menu bar: one status item per widget; optional combined item with a tabbed popover.
- Management: process manager, memory tools (purge), disk tools (eject, Trash, caches), alerts with notification
  actions.
- History: 1 min / 10 min / 1 h in memory; opt-in on-disk history (SQLite, tiers 10 s / 1 min / 10 min).

## Data sources

| Widget | Source | Notes |
|---|---|---|
| CPU | `host_processor_info`, `hw.perflevel*`, IOReport "CPU Stats", `getloadavg` | E-cores are numbered first on Apple Silicon. IOReport "CPU Energy" reads 0 for non-root on macOS 27, so CPU power is hidden when 0. |
| Memory | `host_statistics64`, `kern.memorystatus_vm_pressure_level`, `vm.swapusage` | Used = app (internal - purgeable) + wired + compressed, like Activity Monitor. |
| Disk | `mountedVolumeURLs` (important-usage capacity), `IOBlockStorageDriver` Statistics | Whole disks only, so partitions are not counted twice. |
| Temperature | `IOHIDEventSystemClient` (PrimaryUsagePage 0xFF00, usage 5), SMC `Tg*` keys, `F*Ac/Mn/Mx` | M3 has no HID GPU sensor; GPU temperatures come from the SMC. |
| GPU | `IOAccelerator` PerformanceStatistics, IOReport "GPU Stats"/"Energy Model" | |
| Network | `sysctl(NET_RT_IFLIST2)` 64-bit counters | VPN/tunnel interfaces are listed but not added to totals. |
| Battery | IOPowerSources, `AppleSmartBattery` | Amperage is unsigned in the registry; reinterpret the bits. SystemLoad (mW) gives system power. |
| Processes | `proc_pid_rusage` (own processes), `/bin/ps` (setuid, other users), `responsibility_get_pid_responsible_for_pid` | Helpers fold into the responsible app. |
| Sleep blockers | `IOPMCopyAssertionsByProcess` | Only assertion types that block system or display sleep. |
| Wi‑Fi | CoreWLAN | SSID needs Location permission and is usually nil; not requested. |
| Latency | ICMP echo over `SOCK_DGRAM`/`IPPROTO_ICMP` (no root) | Every datagram ICMP socket sees every reply: match identifier and sequence. Some routers never answer. |
| Bluetooth batteries | IORegistry `BatteryPercent`, `system_profiler SPBluetoothDataType -json` | system_profiler is slow; read at most once a minute. |
| App usage history | process samples every 30 s while History is on | Hourly buckets of CPU seconds and energy joules per app in `app_usage`. |
| Per-app network | `nettop -P -x -L 0 -s 2` run under `script` | nettop takes ~5 s to start and block-buffers into pipes, hence one long-running process on a pty while the Network popover is open. |

## Performance notes

- Probe costs on an M3 Pro (per call): CPU 0.02 ms, memory 0.003 ms, disk 0.04 ms, network 1 ms, battery 0.3 ms,
  GPU 1.2 ms, HID temperatures 0.8 ms, full temperature probe 1.7 ms, IOReport 1.6 ms.
- The menu bar update itself dominates: every change makes AppKit re-snapshot the status item for each display.
  Status items are bitmaps, template images when nothing is past a threshold, and are only replaced when the drawn
  content changes. IOReport runs only while a popover shows it or a power metric is in the menu bar; widgets needed
  only for alerts are sampled every fifth tick.
- Measured: ~3 % of one core with the default four items at 1 s refresh, ~0.1 % at 5 s.

## Verification checklist

See README "Build". Live probes: `TOPBARAC_LIVE=1 swift test`. Screens: `Topbarac --snapshot <dir>`.
