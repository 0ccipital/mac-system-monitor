# Changelog

Feature-by-feature history of SysMonitor, including the pivots and what drove
them. For the *why* behind the architecture, see [DESIGN.md](DESIGN.md); this
file is the narrative of how the app got there.

Dates are when the work landed (all in one development session, 2026-06-02).

---

## 1 — Initial app

A menu-bar-only macOS app (no Dock icon) showing live system metrics, with a
popover to choose which appear in the bar.

- **UI:** AppKit `NSStatusItem` for the bar + a SwiftUI popover hosted in an
  `NSPopover` (DESIGN §3.1). Per-metric checkboxes, persisted to `UserDefaults`.
- **Metrics:** CPU, Memory %, Disk, Network ↑/↓, Battery %, Uptime — all from
  public mach/BSD/IOKit APIs (DESIGN §3.4).
- **Temperature:** private IOHID thermal sensors resolved at runtime with
  `dlsym`, so a missing API degrades gracefully instead of crashing (§3.5).
- **Build/deploy:** compiled with `swiftc` (SwiftPM's manifest API is broken in
  the installed Command Line Tools, §3.6) and bundled into a `.app` by
  `build.sh`; `install.sh` deploys to `~/Applications` and registers a
  LaunchAgent for launch-at-login (§3.7).

## 2 — Battery power (charge / discharge)

- Added **Battery Power**: signed wattage from `AppleSmartBattery`
  Voltage × Amperage — `+W` charging (in), `−W` discharging (out).

## 3 — Total power draw, GB memory, configurable interval

- **Power Draw (first cut):** wanted whole-system watts. Read
  `PowerTelemetryData.SystemLoad` from the SMC.
- **Memory (GB):** split memory into two pinnable metrics — `Memory %` and
  `Memory (GB)`.
- **Update interval:** moved the refresh `Timer` into `MetricsManager` and added
  a popover slider (0.1 s–10 s), persisted.

## 4 — Power Draw made real-time; bug fixes

- **Discovery:** sampling `AppleSmartBattery` once a second showed *every* field
  (incl. `SystemLoad`, raw `Voltage`/`Amperage`) only refreshes every ~30–60 s —
  the SMC's cadence. No poll rate could make it live.
- **Pivot:** switched **Power Draw** to the private **IOReport** `Energy Model`
  energy counters (via `dlsym`), where power = energy-delta ÷ elapsed-time and
  updates every sample (DESIGN §3.8).
- **Fixes:**
  - CPU vanished from the bar at fast intervals (zero tick-delta → `nil`); now
    holds its last value.
  - Popover jumped on every click and clipped on the right; fixed by freezing
    the bar label while the popover is open and setting the hosting controller's
    `sizingOptions` (DESIGN §3.1).

## 5 — Power Draw widened to package power

- **Issue:** SoC compute power (CPU+GPU+ANE) read far below the battery
  discharge — correct, but it looked wrong (0.1 W idle).
- **Fix:** probed the `Energy Model` group and summed the full set of top-level
  rails — CPU, GPU, ANE, **DRAM, display (DISP), AMCC, …** — for a package-power
  figure (~2.5 W idle, much closer to discharge). Added hold-last so it can't
  dip to a spurious ~0 W at fast intervals. (Unit gotcha handled: GPU reports in
  nJ while others use mJ.)

## 6 — Efficiency pass

Goal: the monitor shouldn't measurably load the machine it measures (DESIGN
§3.9). Measured **~0% CPU / ~13 MB idle**; ~5–7% only in the extreme (0.1 s, all
metrics pinned).

- Read **only the pinned metrics** when the popover is closed; read everything
  (live) when it's open.
- **Throttle** slow sources (battery/SMC 8 s, disk 15 s, uptime 30 s) regardless
  of interval.
- Publish the SwiftUI `samples` **only while the popover is open**.
- `Timer.tolerance` for wakeup coalescing; **pause on display sleep**.
- Lighter battery read (fetch two keys, not the whole `AppleSmartBattery` dict).

## 7 — Bar formatting: fixed-width → compact

- **First attempt:** truly non-shifting fixed-width tokens (fully monospaced
  font + space-padded fields, one-decimal network in both KB/s & MB/s).
- **Pivot:** that was too wide. Switched to **compact**: `monospacedDigit` font
  (tabular digits, proportional letters), no padding, single-space separators,
  and a compact network format `value+unit+arrow` (`14.7K↓`). Compactness chosen
  over never-shifting (DESIGN §5.5).

## 8 — SF Symbols in the bar

- Replaced the `CPU` / `RAM` / `DISK` / `BAT` text labels with their drawer SF
  Symbols, rendered as template-image attachments in the button's
  `attributedTitle` (reuses `MetricKind.icon` via `barSymbol`).

## 9 — Bold values

- Menu-bar values set to bold weight for legibility; symbols left at regular
  weight so they don't overwhelm the numbers.

## 10 — Quality audit fixes

A pass over correctness, accuracy, micro-performance, and daily usability
(grades and rationale in the audit). Changes:

**Accuracy**
- Battery now uses the real charging flag (`kIOPSIsChargingKey`), not "on AC"
  (which is true at 100% too).
- Network excludes virtual interfaces (`utun`/`awdl`/`bridge`/`vmnet`/…) so VPN
  tunnels no longer double-count throughput.
- **Temperature = hottest SoC die** (`tdie*`), replacing the mean-of-all-sensors
  (which diluted the real temp with battery/SSD/board readings). Enumerated the
  46 sensors to pick this.
- **Memory = "in use"** (app + wired + compressed), matching Activity Monitor's
  "Memory Used".
- Network bar/detail normalized to **base-2** (1024) units consistently.

**Performance / efficiency**
- IOReport channel filtering now compares CFStrings via `CFEqual` — no Swift
  `String` allocation across the ~200-channel walk.
- SF Symbol images cached (built once per name, not per refresh).
- `mach_host_self()` cached once instead of per read.
- Interval slider debounced — persists/reschedules on release, not every drag tick.
- **Sensor reads moved to a background queue**; UI updates marshaled to main.
- On display wake, baselines reset so the first reading is fresh (no average
  spanning sleep).

**Usability / reliability**
- **Launch-at-login toggle** in the popover (manages the LaunchAgent).
- LaunchAgent `KeepAlive` now restarts on crash but lets a clean Quit stick.
- Hover **tooltips** on each metric row.
- Disk shows **every mounted local volume** (not just the boot disk) in the row.
- **Rolling CSV log** of all values to `~/Documents/SysMonitor.csv` (capped ~1 MB).
- **Tests** (`test.sh`): smoke (construct + launch) and 30-second value-range checks.

The 0.1 s interval floor was intentionally kept (it's for debugging); threshold
coloring and click-through were intentionally skipped.
