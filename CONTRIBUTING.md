# Contributing

This is a public-domain tool ([Unlicense](LICENSE)) — fork it, hack on it, ship
your own version. No CLA, no attribution required. PRs are welcome but not
expected; if you fork and improve it, that's the whole point.

## Requirements

- Apple Silicon Mac, macOS 13+
- Xcode **Command Line Tools** (`xcode-select --install`) — no full Xcode, no
  Swift Package Manager, no third-party dependencies.

## Build · run · test

```sh
./build.sh    # compile + assemble SysMonitor.app
./install.sh  # build, deploy to ~/Applications, register at login
./test.sh     # smoke + 30-second value-range tests  (./test.sh 5 for a short run)
```

`build.sh` compiles `Sources/SysMonitor/*.swift` directly with `swiftc` and
assembles the `.app` bundle by hand (see [DESIGN.md](DESIGN.md) §3.6 for why no
SwiftPM).

## Code layout

| File | Role |
|---|---|
| `Sources/SysMonitor/Metrics.swift` | Metric model + `MetricsManager` (refresh loop, bar) |
| `Sources/SysMonitor/Readers.swift` | Public-API readers (CPU, memory, disk, network, battery, uptime) |
| `Sources/SysMonitor/Sensors.swift` | Private-API readers via `dlsym` (temperature, power) |
| `Sources/SysMonitor/main.swift` | AppKit shell: status item + popover |
| `Sources/SysMonitor/MenuContentView.swift` | SwiftUI popover |
| `Sources/SysMonitor/Logger.swift`, `LoginItem.swift` | CSV log, launch-at-login |

## Adding a metric

The model is data-driven, so this is small — see [DESIGN.md](DESIGN.md) §5.1:

1. Add a `case` to `MetricKind` (and its `title` / `icon` / `help`).
2. Produce a `MetricSample` for it in `MetricsManager.performReads` (use an
   existing reader or add one to `Readers.swift`).

The popover row, its checkbox, persistence, logging, and the bar token all light
up automatically because everything iterates `MetricKind.allCases`.

## Good to know

- Temperature and Power Draw use **private** Apple frameworks resolved at
  runtime; they degrade gracefully (the row disappears) but can break on OS
  updates or vary by chip.
- Architecture & decisions: [DESIGN.md](DESIGN.md). Change history:
  [CHANGELOG.md](CHANGELOG.md).
