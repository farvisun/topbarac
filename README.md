# Topbarac

Your whole Mac, one glance up. A menu bar system monitor for macOS 26+ with Liquid Glass popovers, and tools to act on
what you see: quit runaway processes, free memory, eject disks, empty the Trash, and get alerted before things go wrong.

The macOS sibling of [Topbar Resource](https://farvisun.github.io/topbar-resource/) for GNOME.
Website: <https://farvisun.github.io/topbarac/>

## Widgets

Each widget is its own menu bar item (or combine them all into one item with a tabbed popover). Every widget offers
five panel styles (Numbers, Sparkline, Bars, Ring, Level meter), optional value and label, and warning/critical
thresholds that turn it yellow or red.

| Widget | Menu bar | Popover |
|---|---|---|
| CPU | usage or power | stacked user/system chart, P/E core bars, frequency, load average, uptime |
| Memory | percent, amount or pressure | stacked app/wired/compressed chart, cached and swap, pressure, free inactive memory |
| Disk | space used, busy time or read/write speed | every volume with purgeable space, eject/open, mirrored read/write chart, Trash and caches |
| Temperature | CPU, GPU, SSD, hottest sensor or fan RPM | all sensors grouped with session min/max, fans (read-only) |
| GPU | usage, memory or power | renderer/tiler engines, memory in use, frequency, power |
| Network | download, upload or both | per-interface rates, session totals, apps using the network |
| Battery | charge, watts or time left | power in/out chart, health, cycles, voltage, adapter |

Every popover lists the top processes for its metric, with helpers folded into their app. Hover to quit; right-click to
force quit, kill, reveal in Finder or copy the PID. Processes of other users can be stopped after an administrator
prompt; system processes are protected. "Show All" opens a searchable process window.

Alerts fire when a rule holds for a duration ("CPU above 90 % for 60 s") and name the process to blame, with a Quit
button in the notification. Charts show 1 min / 10 min / 1 h from memory; turn on History to keep averages on disk
(10 s for 7 days, 1 min for 90 days, 10 min after that) and chart days, months or everything. Export to CSV anytime.

## Install

```sh
brew install --cask farvisun/tap/topbarac
```

Or download `Topbarac.dmg` from the [latest release](https://github.com/farvisun/topbarac/releases/latest). The app is
ad-hoc signed (not notarized yet): the first time, right-click → Open, or run
`xattr -dr com.apple.quarantine /Applications/Topbarac.app`. Updates arrive through Sparkle.

## Build

Needs Xcode 26+ (Swift 6.2, macOS 26 SDK).

```sh
scripts/build-app.sh release --run   # build build/Topbarac.app and launch it
scripts/build-app.sh debug           # debug build
swift build                          # compile only
swift test                           # unit tests
TOPBARAC_LIVE=1 swift test           # plus live probe tests on real hardware (sensors, battery, nettop)
```

`Topbarac --snapshot <dir> [--wait 30]` samples for a while, renders every popover and the panel styles to PNG in light
and dark, then quits (used for the website screenshots). `--open cpu` opens a popover at launch; `--settings` opens
Settings.

## How it works

- `Sources/TopbaracCore`: sampling with no UI. One `DispatchSourceTimer` on a serial queue drives every probe:
  `host_processor_info`, `host_statistics64`, `NET_RT_IFLIST2`, `IOBlockStorageDriver`, IOPowerSources and
  `AppleSmartBattery`, `IOAccelerator`, the HID event system for temperatures, the SMC (read-only) for fans and GPU
  temperatures, IOReport for frequencies and power, `proc_pid_rusage` plus `/bin/ps` for processes, a streaming
  `nettop` for per-app traffic. Private APIs are resolved at runtime; when one is missing the value is hidden.
- `Sources/Topbarac`: AppKit status items rendered as bitmaps (template images when nothing is past a threshold, so
  macOS tints them per display), SwiftUI popovers and settings, Swift Charts.
- Detail data (sensor list, process list, per-app network, frequencies) is read only while a popover is open.

Idle cost on an M3 Pro with the default four items at 1 s refresh is about 3 % of one core, almost all of it macOS
redrawing the menu bar items; at a 5 s refresh it is about 0.1 %.

## Release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`, add `.github/release-notes/vX.Y.Z.md`.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow builds a universal app, the zip and DMG, signs the
   zip for Sparkle, publishes the GitHub release with `appcast.xml`, and updates the cask in `farvisun/homebrew-tap`.

Repository secrets: `SPARKLE_ED_PRIVATE_KEY` (EdDSA private key matching `SUPublicEDKey`, exported with
`generate_keys --account topbarac -x key.txt`) and `TAP_DEPLOY_KEY` (deploy key with write access to the tap).
The website in `site/` deploys to GitHub Pages from the `production` branch.

## Privacy

No accounts, no analytics. The only network request is the daily update check. No root, no helper daemon. History is
stored only if you turn it on, in `~/Library/Application Support/Topbarac`.

## License

MIT
