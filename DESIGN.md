# SysMonitor — Design & Decisions

This document explains how the pieces fit together, *why* each was chosen over
the alternatives, and how to build something like it yourself or extend what's
here. It's written to be read top-to-bottom, but each decision section stands
alone.

---

## 1. The mental model

A menu-bar monitor is, at its core, three things:

1. **A clock** — something that fires on an interval.
2. **Readers** — functions that, when asked, return a number from the OS.
3. **A sink** — somewhere to display the numbers (a status-bar label) and a
   place to configure what's shown (a popover).

Everything in this project is one of those three. If you keep that shape in
mind, the code is small and the extension points are obvious: to add a metric
you write a reader; to change cadence you change the clock; to change
presentation you touch the sink.

```
        ┌─────────────┐   every 2s    ┌──────────────────┐
        │   Timer     │ ───────────▶  │  MetricsManager  │
        │ (the clock) │   .refresh()  │   (coordinator)  │
        └─────────────┘               └────────┬─────────┘
                                                │ calls
                          ┌─────────────────────┼─────────────────────┐
                          ▼                      ▼                     ▼
                  ┌──────────────┐      ┌────────────────┐    ┌──────────────────┐
                  │ CPUReader    │      │ SystemReaders  │    │ ThermalReader    │
                  │ NetworkReader│      │ PowerReader    │    │ PowerReportReader│
                  └──────────────┘      └────────────────┘    │ (private API)    │
                          │ cache: [MetricKind: MetricSample]  └──────────────────┘
                          ▼
        ┌───────────────────────────┐         ┌──────────────────────────────┐
        │ status item attributedTitle│ ◀────── │ onUpdate([BarSegment]) closure│
        │        (the sink)         │          └──────────────────────────────┘
        └───────────────────────────┘
                          ▲ @Published samples / enabled
        ┌───────────────────────────┐
        │ MenuContentView (SwiftUI) │  popover: list + checkboxes
        └───────────────────────────┘
```

---

## 2. How the parts work together

The flow lives across a few small files: the model + manager
([Metrics.swift](Sources/SysMonitor/Metrics.swift)), the readers
([Readers.swift](Sources/SysMonitor/Readers.swift) for public APIs,
[Sensors.swift](Sources/SysMonitor/Sensors.swift) for the private dlsym ones),
the AppKit shell ([main.swift](Sources/SysMonitor/main.swift)), and the SwiftUI
popover ([MenuContentView.swift](Sources/SysMonitor/MenuContentView.swift)),
plus [Logger.swift](Sources/SysMonitor/Logger.swift) and
[LoginItem.swift](Sources/SysMonitor/LoginItem.swift):

1. **`main.swift` boots an `NSApplication`** with a custom `AppDelegate` and
   sets the activation policy to `.accessory` (no Dock icon, no main window).
   It creates one `NSStatusItem` and one `NSPopover` whose content is a SwiftUI
   view hosted in an `NSHostingController`. The repeating `Timer` lives in
   `MetricsManager` (so its interval is user-configurable; see §3.9).

2. **The `Timer` calls `MetricsManager.refresh()`.** For each reader group that
   is *due* (pinned to the bar, or popover open — and past its throttle period),
   the manager reads a value, formats two strings — a long one for the popover
   and a compact one for the bar — and stores them in a `cache`
   (`[MetricKind: MetricSample]`). See §3.9 for why it reads only what's needed.

3. **Two consumers react:**
   - The **bar label**: `refresh()` composes an ordered `[BarSegment]` (each an
     optional SF Symbol + its text) from the pinned metrics and hands it to the
     `onUpdate` closure. `AppDelegate` turns that into an `NSAttributedString`
     (symbols as template-image attachments) and sets it as the status button's
     `attributedTitle`. The manager doesn't know about AppKit; the closure is
     the seam.
   - The **popover**: `MenuContentView` observes the manager (`@ObservedObject`).
     The `@Published samples` is assigned *only while the popover is open*
     (§3.9), so a closed popover does no SwiftUI work; when open, changes
     re-render the rows automatically.

4. **Toggling a checkbox** writes through a `Binding` into
   `MetricsManager.setEnabled(_:_:)`, which updates the `enabled` set, persists
   it to `UserDefaults`, and recomposes the bar. State lives in exactly one
   place (the manager); both the bar and the popover are projections of it.

The key structural idea: **the manager is UI-agnostic and owns all state.**
AppKit talks to it through a closure; SwiftUI talks to it through
`ObservableObject`. Either UI could be removed without touching the readers.

---

## 3. Decisions

Each decision below is framed as **what / why / alternatives**, so you can see
what you'd swap if your constraints differ.

### 3.1 UI: AppKit status item + a SwiftUI popover (hybrid)

**What.** The menu-bar item is `NSStatusItem` (AppKit). The dropdown content is
SwiftUI, embedded via `NSHostingController` inside an `NSPopover`.

**Why.** Two requirements pulled in different directions:
- The bar label needs precise, frequent text updates and full control over
  font/title — AppKit's `NSStatusItem.button` does this directly and reliably.
- The popover is a *form* (a list of rows with checkboxes) — exactly what
  SwiftUI is best at. Writing that list in AppKit would be far more code
  (`NSTableView` or stacked `NSButton`s with target/action wiring).

The hybrid takes the strong half of each framework. `NSHostingController`
bridging SwiftUI into an AppKit popover is a well-trodden, stable path.

**Alternatives.**
- **SwiftUI `MenuBarExtra` (macOS 13+).** Pure SwiftUI, much less boilerplate —
  you'd delete `main.swift`'s AppDelegate entirely. The catch: the menu-bar
  *label* is more constrained (it renders a `Text`/`Image` view, and complex or
  rapidly-updating labels can be finicky), and you have less control over exact
  title formatting. Great choice if you want minimal code and your label is
  simple. **This is the modern default and worth considering first** if you're
  starting fresh.
- **Pure AppKit (`NSMenu`).** Use the status item's `menu` with one
  `NSMenuItem` per source, `.state = .on/.off` for the checkmarks. Zero SwiftUI.
  Downside: an `NSMenu` closes every time you click an item, so toggling
  several checkboxes is click-reopen-click. The popover stays open, which suits
  "tick a few boxes" better.

### 3.2 Updating: a polling timer, not push notifications

**What.** A `Timer` fires every 2 s and re-reads everything.

**Why.** The metrics here (CPU load, memory, throughput) have no "changed"
event to subscribe to — they're sampled quantities. CPU % and network rate are
*defined* as deltas over an interval, so you need two samples spaced in time
regardless. Polling is the natural model and 2 s is a good balance of liveliness
vs. wakeups.

**Alternatives.**
- **`DispatchSourceTimer`** instead of `Timer` if you want to read on a
  background queue and marshal results to the main thread — worth it if a reader
  ever becomes slow. Today every read is sub-millisecond, so the main-thread
  `Timer` is simpler and fine.
- **Event-driven** sources exist for *some* signals (e.g. `IOPSNotification`
  callbacks for power-source changes, `NSWorkspace` notifications). You could
  use those to update battery state instantly and poll the rest. Added
  complexity isn't worth it for a 2 s monitor.
- **Adaptive cadence** — poll slower when the popover is closed, faster when
  open. A nice optimization; not implemented to keep things obvious.

### 3.3 Metric model: an enum + a uniform `MetricSample`

**What.** `MetricKind` is a `CaseIterable` enum (one case per source).
`refresh()` produces a `[MetricKind: MetricSample]`, where `MetricSample`
carries `detail` (popover string), `bar` (compact string), and `available`.

**Why.** This makes the UI *data-driven*: `MenuContentView` just iterates
`MetricKind.allCases` and renders whatever is available. Adding a metric is
"add an enum case + produce its sample" — the popover, the checkbox, and
persistence all light up for free because they key off the enum. The
`available` flag is how machine-specific sources (battery on a desktop) vanish
without special-casing the UI.

**Alternatives.**
- **A protocol** `Metric { var title; func sample() -> MetricSample }` with one
  type per metric and an array of them. More "OO", and better if metrics grew
  complex per-type behavior. For ~10 simple readers the enum is less ceremony.
- **Per-metric `@Published` properties** on the manager. Simpler to write at
  first but the UI can no longer loop generically — every new metric means
  editing the view. The dictionary keeps the view closed to change.

### 3.4 Reading the OS: mach/BSD/IOKit directly

**What.** CPU and memory use mach `host_statistics`/`host_statistics64`;
network uses BSD `getifaddrs`; battery and power use IOKit (`IOKit.ps` and the
`AppleSmartBattery` IORegistry entry).

**Why.** These are the same primitives Activity Monitor and tools like *Stats*
use. They're public, dependency-free, and fast. The only mildly fiddly part is
the C-interop dance in Swift (`withUnsafeMutablePointer` +
`withMemoryRebound` to hand mach a typed buffer) — see `CPUReader` and
`SystemReaders.memoryUsage()`.

A subtlety worth noting (it's a common bug): **CPU % and network rate are
stateful.** A single `host_statistics` call returns *cumulative* ticks since
boot; "usage right now" is `(busy_now − busy_prev) / (total_now − total_prev)`.
That's why `CPUReader` and `NetworkReader` are classes that retain the previous
sample, while the stateless reads live in the `SystemReaders` enum.

**Alternatives.**
- **Shelling out** to `top`, `vm_stat`, `ioreg`, `pmset` and parsing text.
  Easiest to prototype, but slow (spawns a process per read), brittle (output
  formats change), and ugly. Fine for a one-off script, wrong for a resident
  app.
- **A library** (e.g. `SystemKit`/`SMCKit`-style packages). Saves you the
  C-interop, adds a dependency. Since the interop is ~15 lines per reader and we
  wanted zero dependencies, direct calls won.

### 3.5 Temperature: the private-API problem

**What.** Hardware temperatures on Apple Silicon aren't in any public API. The
working approach is the private **IOHID** thermal-sensor interface
(`IOHIDEventSystemClientCreate`, `…CopyServices`,
`IOHIDServiceClientCopyEvent`, `IOHIDEventGetFloatValue`). These symbols aren't
in the SDK headers. `ThermalReader` resolves them **at runtime with `dlsym`**
and calls them through `@convention(c)` function-pointer typealiases. The
matching dictionary selects temperature sensors
(`PrimaryUsagePage 0xff00`, `PrimaryUsage 5`); each service's event is read at
field `kIOHIDEventTypeTemperature << 16`.

**Which sensor.** Enumerating the sensors (via each service's `Product` name)
on an M-series machine returns ~46: SoC die clusters (`tdie1…10`, ~36–39 °C),
device/board (`tdev*`), a PMU calibration reading (`tcal`, ~52 °C, suspiciously
flat), plus battery and NAND. Averaging them all dilutes the real chip temp with
cool battery/SSD readings; a naive max headlines the misleading `tcal`. So the
reader filters to **`tdie*` and reports the hottest** — the standard "CPU
temperature" meaning and the number that reflects thermal headroom.

**Why `dlsym`.** Because the symbols are private, you have three ways to reach
them, and `dlsym` is the safest:
- It **fails gracefully**: if a symbol or the framework is missing, you get a
  `nil` function pointer, the reader returns `nil`, and the UI hides the metric.
  Nothing crashes, nothing fails to launch.
- It introduces **no link-time dependency** on private symbols — the binary
  links only public `IOKit`.

**Why this is fragile (and honest about it).** It's a private interface: Apple
can change it, sensor naming varies by chip, and an OS update could break it.
That's the price of temperature data on Apple Silicon — there is no supported
path. The code is deliberately defensive so that when it breaks, *only*
temperature disappears.

**Alternatives.**
- **A C shim target** declaring the private prototypes in a header and linking
  `IOKit`. Cleaner call sites (no `unsafeBitCast`), but it *link-depends* on
  private symbols, so a missing symbol becomes a launch failure instead of a
  graceful `nil`. Also needs SwiftPM/a C target, which we're avoiding (§3.6).
- **The SMC route** (`AppleSMC`, FourCC keys like `TC0P`). The classic
  pre-Apple-Silicon method; on Apple Silicon the keys changed and IOHID is the
  more reliable source.
- **`powermetrics`.** Accurate and detailed, but requires `sudo` and spawns a
  process — unusable for an unprivileged resident app.

### 3.6 Build system: `swiftc` directly

**What.** `build.sh` invokes `swiftc` on the source files and then hand-builds
the `.app` bundle (make `Contents/MacOS`, copy binary, write `Info.plist`,
`codesign --sign -`).

**Why.** The first attempt used a SwiftPM `Package.swift`. It failed: the
PackageDescription library shipped in the installed Command Line Tools is
version-skewed against the toolchain, so even a trivial manifest fails to link
(`Undefined symbols … PackageDescription.Package.__allocating_init`). Rather
than fight a broken SwiftPM, compiling the four files directly is *simpler* and
has no moving parts:

```sh
swiftc -O -o SysMonitor Sources/SysMonitor/*.swift \
    -framework Cocoa -framework SwiftUI -framework IOKit \
    -target arm64-apple-macosx13.0
```

A menu-bar app also needs a real bundle (a bare executable can't carry the
`Info.plist` that sets `LSUIElement`), so the script assembles one by hand —
which is genuinely all an `.app` is: a directory with a known layout.

**Alternatives.**
- **Xcode project + `xcodebuild`.** The conventional path; gives you
  asset catalogs, entitlements UI, archiving, notarization. Overkill here and
  requires a full Xcode install (we only have Command Line Tools).
- **SwiftPM (`swift build`)** — the intended tool, currently broken in this
  environment. On a machine with a matching toolchain you could restore a
  `Package.swift` and `swift build` would work; you'd still hand-bundle the
  `.app` afterward (SwiftPM produces a bare executable for an `executableTarget`).

### 3.7 Launch at login: a LaunchAgent

**What.** `install.sh` copies the app to `~/Applications` and writes a
`launchd` user agent at `~/Library/LaunchAgents/com.local.sysmonitor.plist`
with `RunAtLoad=true`, `KeepAlive=false`, loaded via `launchctl bootstrap`.

**Why.** A LaunchAgent is the robust, scriptable way to start a locally-built,
ad-hoc-signed app at login. `RunAtLoad` starts it at login; `KeepAlive=false`
means the popover's **Quit** actually quits (a `true` value would relaunch it
immediately). It needs no special signing or entitlements and is trivial to
remove (`launchctl bootout` + delete the plist).

**Alternatives.**
- **`SMAppService.mainApp.register()` (macOS 13+).** The modern, Apple-blessed
  API; shows up in System Settings ▸ General ▸ Login Items and can be toggled
  in-app. It expects a properly code-signed app in a stable location and can be
  finicky with ad-hoc signing — which is why the script uses a LaunchAgent. If
  you later sign the app properly, `SMAppService` is the nicer long-term choice
  and lets you add an in-app "Start at login" toggle.
- **`osascript` "Login Items"** (`System Events`). The old AppleScript trick.
  Works, but it's the legacy mechanism and prompts for Automation permission.
- **Dragging into System Settings ▸ Login Items** by hand. Fine for one user,
  not scriptable.

### 3.8 Real-time power: IOReport energy counters, not battery telemetry

**What.** The "Power Draw" metric reads the SoC energy counters (CPU + GPU +
ANE) through the private **IOReport** framework: subscribe to the
`"Energy Model"` channel group, take a sample now, diff it against the previous
sample, and divide the energy delta by the elapsed time to get watts.
`PowerReportReader` resolves the IOReport symbols with `dlsym` (same graceful
pattern as temperature, §3.5).

**Why — and how the decision was reached.** The first implementation read
`AppleSmartBattery → PowerTelemetryData.SystemLoad`, which *is* total system
power. But it appeared frozen for ~a minute at a time. Sampling the IORegistry
once a second proved the cause: **every `AppleSmartBattery` field — even raw
`Voltage`/`Amperage` — updates only every ~30–60 s.** The SMC publishes battery
telemetry on its own slow cadence, so no polling rate can make it livelier.
That's a property of the source, not the code.

IOReport is different in kind: it exposes *cumulative energy counters*, so
"power right now" is a delta you compute yourself over whatever interval you
choose. Polling at 10 Hz yields a 10 Hz power readout. This is exactly how
`powermetrics`, `asitop`, and `macmon` get live power.

The `"Energy Model"` group exposes many rails. `PowerReportReader` sums the
top-level ones — `CPU Energy`, `GPU Energy`, `ANE`, `DRAM`, `DISP`/`DISPEXT`
(display), `AMCC`, `DCS`, `ISP`, `AVE`, `MSR`, PCIe — to approximate **total
package power**. (The cryptic per-cluster channels like `PCPUDTL*`/`ECPU*` are
*components* of `CPU Energy` and are excluded to avoid double-counting; a unit
gotcha: GPU reports in `nJ` while CPU/DRAM report in `mJ`, so each channel's
unit label is read and scaled individually.) Idle lands ~2.5 W vs. a ~3–4 W
battery discharge — the residual gap is backlight brightness, SSD, Wi-Fi, and
DC conversion losses, which aren't on any SoC rail. There is no responsive
whole-machine figure on Apple Silicon; this is as close as it gets.

So there are two power metrics, by design, because they answer different
questions:
- **Battery Power** (§3.1's `PowerReader`) — net charge/discharge at the
  battery. Inherently slow (SMC-limited), but that's fine for "am I charging."
- **Power Draw** (`PowerReportReader`) — real-time package consumption.

**Alternatives.**
- **`SystemLoad` from the SMC** — true whole-system watts, but ~30–60 s stale.
  Keep it if you want total power and don't care about latency.
- **`powermetrics`** — most detailed, but needs `sudo` and a subprocess. Wrong
  for a resident, unprivileged app.
- **Narrowing to compute only** — drop `DRAM`/`DISP`/etc. from the summed set
  in `PowerReportReader` to report just CPU+GPU+ANE if you want pure compute
  power rather than the fuller package figure.

> **A note on the timer and sub-second intervals.** Because power is now an
> energy *delta over elapsed time*, the reader measures the real elapsed time
> between samples rather than assuming the nominal interval — so the watts stay
> correct whether you poll at 0.1 s or 10 s. The refresh `Timer` is added to the
> run loop in `.common` mode so it keeps firing while the popover is open.

### 3.9 Efficiency: do the least work that preserves functionality

**What.** A monitor that measurably loads the machine corrupts its own reading.
Several measures keep SysMonitor's own footprint near zero without dropping any
feature:

0. **Reads run off the main thread.** The `Timer` fires on main and dispatches
   the sensor reads to a serial `workQueue` (utility QoS); only the resulting
   snapshot is marshaled back to main to update the bar and (if visible) the
   SwiftUI view. The reader objects, their throttle state, and the read-side
   cache live exclusively on that queue, so there are no locks and no main-thread
   stalls. A `force`/`isReading` guard drops a tick if the previous read is still
   in flight, so fast intervals never pile up.

1. **Read only what's shown.** When the popover is *closed*, `refresh()` reads
   only the metrics pinned to the bar; everything else is skipped. When it's
   *open*, it reads all of them (to show every row live). Opening the popover
   triggers an immediate full read so nothing is stale.
2. **Throttle slow sources.** Each reader group has a minimum period
   (`due(_:_:_:_:)`). Battery/SMC data only changes every ~30–60 s, disk fills
   slowly, uptime ticks by the minute — so these are capped (8 s / 15 s / 30 s)
   regardless of the refresh interval. CPU, memory, network, and SoC power stay
   live every tick. Throttling can't reduce functionality because these values
   don't *change* faster than the cap anyway.
3. **Don't render an invisible view.** `samples` (the `@Published` the SwiftUI
   popover observes) is assigned *only while the popover is open*. When closed,
   the bar is composed from a private `cache` instead, so closing the popover
   stops all SwiftUI body recomputation.
4. **Coalesce wakeups.** The refresh `Timer` sets `tolerance = interval * 0.2`,
   letting the OS batch its wakeups with other timers — fewer discrete CPU
   wake-ups, lower idle power, no perceptible change in liveliness.
5. **Pause when the display sleeps.** `NSWorkspace` screen sleep/wake
   notifications pause and resume the timer. If you can't see the menu bar,
   there's nothing to compute.

Plus micro-optimizations: the battery-flow reader fetches just `Voltage` and
`Amperage` (not the whole `AppleSmartBattery` dict); IOReport channel matching
uses `CFEqual` on raw CFStrings (no `String` allocation across the ~200-channel
walk); SF Symbol images and `mach_host_self()` are cached once.

**Logging interaction.** The rolling CSV log (`MetricsLogger`, §3.10) needs
*every* value, which would conflict with "read only what's pinned." It's
reconciled inside the one read loop: every `logInterval` (5 s) the loop reads as
if the popover were open and logs the full snapshot, so there's a single sampler
(no double-advancing the stateful delta readers) and the steady-state bar still
reads only what's pinned.

**Measured.** Popover closed with the default pins: **0.0% CPU, ~13 MB**.
Worst case — 0.1 s interval with all 11 metrics pinned (≈10 full reads/sec
including the IOReport channel walk and IOHID sensor reads): **~5–7% CPU**. The
realistic resident cost is indistinguishable from zero.

**Alternatives / further ideas.**
- **Narrower IOReport subscription.** The subscription still covers the whole
  `"Energy Model"` group, so `IOReportIterate` walks ~200 channels to find ~14
  (now via allocation-free `CFEqual`). Subscribing to only the needed channels
  would cut the walk itself, at the cost of more setup and chip-specific lists.
- **Pause on battery / Low Power Mode.** Could slow the interval automatically
  when unplugged. Not done — it changes behavior the user didn't ask for, and
  the cost is already negligible.

### 3.10 Logging, launch-at-login, and tests

**Rolling CSV log (`MetricsLogger`).** Appends one line per `logInterval` to
`~/Documents/SysMonitor.csv`, with a column per metric. File I/O is on its own
background queue. When the file passes ~1 MB it's rewritten keeping the most
recent ~half behind a fresh header — a bounded, single-file roll (cheap because
it only fires every few thousand lines). Values are the human-readable detail
strings with commas stripped, so the CSV stays valid.

**Launch-at-login (`LoginItem`).** A per-user **LaunchAgent** rather than
`SMAppService`, because the LaunchAgent also gives crash-restart
(`KeepAlive = {SuccessfulExit = false}` — restart on crash, but a clean Quit at
exit 0 stays quit), and because an ad-hoc-signed app doesn't satisfy
`SMAppService.mainApp` cleanly. The toggle just writes/removes the plist
(pointing at `Bundle.main.executablePath`); presence controls the next login.
Toggling off leaves the running instance alone. `install.sh` writes the same
plist for the initial deploy.

**Tests (`test.sh` + `Tests/main.swift`).** No XCTest/SwiftPM here, so the test
runner compiles the reader sources (`Metrics`/`Sensors`/`Logger`) plus its own
`main.swift` directly. It covers two things the audit cared about: *smoke*
(constructors and the manager don't crash; the real app launches and survives)
and *value ranges* (every reading stays plausible — CPU 0–100, memory 0–100,
power 0–200 W, temp 0–150 °C — sampled once a second over a window, default
30 s). Stateful readers expose `reset()` partly for the wake path and partly to
keep them testable.

---

## 4. Building one yourself: the smallest version

If you want to understand the skeleton, here's a complete menu-bar app in one
file. Save as `main.swift`, then
`swiftc main.swift -framework Cocoa -o demo && ./demo`:

```swift
import Cocoa

final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)            // no Dock icon
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let used = ProcessInfo.processInfo.physicalMemory   // placeholder "reader"
            self?.item.button?.title = "RAM \(used / 1_073_741_824) GB"
        }
    }
}

let app = NSApplication.shared
let d = Delegate(); app.delegate = d
app.run()
```

That's the clock + a reader + the sink. SysMonitor is this plus: real readers,
a popover for configuration, and a build/deploy script. Add a popover with:

```swift
let popover = NSPopover()
popover.behavior = .transient
popover.contentViewController = NSHostingController(rootView: MyView())
// on button click: popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
```

---

## 5. Extending SysMonitor

### 5.1 Add a new metric (worked example: GPU %, fans, swap, …)

Because the model is data-driven (§3.3), adding a metric is four small edits in
[Metrics.swift](Sources/SysMonitor/Metrics.swift):

1. **Add the enum case** and its `title` / `icon` (SF Symbol name):
   ```swift
   case swap
   // in title:  case .swap: return "Swap"
   // in icon:   case .swap: return "arrow.left.arrow.right"
   ```

2. **Write the reader.** Stateless? Add to `SystemReaders`. Needs the previous
   sample (a rate or a delta)? Make it a small class like `CPUReader`.
   ```swift
   static func swapUsage() -> Double? {
       var xsw = xsw_usage()
       var size = MemoryLayout<xsw_usage>.size
       guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0, xsw.xsu_total > 0 else { return nil }
       return Double(xsw.xsu_used) / Double(xsw.xsu_total) * 100
   }
   ```

3. **Emit a sample** in `refresh()`:
   ```swift
   if let v = SystemReaders.swapUsage() {
       next[.swap] = MetricSample(detail: pct(v), bar: "SWAP \(pct(v))", available: true)
   } else {
       next[.swap] = MetricSample(detail: "—", bar: "", available: false)
   }
   ```

4. **Nothing else.** The popover row, its checkbox, the bar token, and
   persistence all work automatically — they iterate `MetricKind.allCases`.

The same recipe covers **fan speed** (IOHID, like temperature but
`PrimaryUsage` for fans / a different event type), **GPU %** (IOKit
`AGXAccelerator`/IOReport), or **per-core CPU** (`host_processor_info` with
`PROCESSOR_CPU_LOAD_INFO` instead of the aggregate).

### 5.2 Change the refresh interval

This is now built in: `MetricsManager` owns the `Timer`, persists `interval` to
`UserDefaults`, and exposes `setInterval(_:)`, which reschedules. The popover's
slider binds to it (`MenuContentView.intervalBinding`). To widen the range, edit
`MetricsManager.minInterval` / `maxInterval`. To change the *control* (e.g. a
`Stepper` or preset buttons instead of a slider), swap the view — the manager
side is unchanged.

### 5.3 Add an "Adapter wattage" / power-in metric

`AppleSmartBattery` also exposes `AdapterDetails` (negotiated adapter watts) and
`PowerTelemetryData.SystemPowerIn` (instantaneous input — but SMC-slow, §3.8).
Extend `PowerReader` to pull another field, add an
`.adapterPower` case, and emit it — same pattern as §5.1. You could then show
"96 W in / 30 W to battery / 66 W to system" by combining the three power
fields.

### 5.4 Add an in-app "Start at login" toggle

Sign the app properly, then use `SMAppService.mainApp` (§3.7): a SwiftUI
`Toggle` whose binding calls `register()` / `unregister()` and reads
`.status`. Drop the LaunchAgent step from `install.sh` in that case.

### 5.5 The bar tokens — how the label is rendered

The menu-bar label is the most-iterated part of the app (see
[CHANGELOG.md](CHANGELOG.md)); this is where it landed and why.

**Composition.** `refresh()` builds a compact `bar` string per metric;
`composeBar()` turns the pinned, available ones into an ordered `[BarSegment]`
(`symbol: String?`, `text: String`) and calls `onUpdate`. `AppDelegate.makeTitle`
renders that to an `NSAttributedString`:

- **Symbols.** The percentage metrics (CPU, RAM %, Disk, Battery) lead with
  their drawer SF Symbol instead of a text label — reusing `MetricKind.icon`
  via `barSymbol`. Each is a template-image `NSTextAttachment` (so it tints with
  the menu bar), vertically centered on the font's cap height. The rest carry
  their own unit text (`10.3G`, `14.7K↓`, `1.6W`, `31°C`) and get no symbol.
- **Font.** `monospacedDigitSystemFont`, weight `.bold`: digits are **tabular**
  (numbers don't jitter as they change) but letters stay **proportional**
  (compact). Bold for legibility at menu-bar size.
- **Compactness over fixed width.** Tokens aren't padded, so each is as narrow
  as its content and sections are single-space separated. A token only changes
  width when its digit *count* changes (`99%`→`100%`) — an accepted trade for
  tightness. Network uses a single-letter unit and trailing arrow (`netBar`).

**Why this and not the alternatives we tried:** a fully-monospaced,
space-padded bar gives *never-shifting* fixed width but is noticeably wider; we
chose compactness. To go back, left-pad each numeric field to a constant width
and switch the font to `monospacedSystemFont`. For colored segments or
sparklines instead, build the `NSAttributedString` with colored runs, or draw
into an `NSImage` and set `button.image`.

To tweak: change which metrics show symbols in `MetricKind.barSymbol`; adjust
symbol size/weight in `makeTitle`'s `SymbolConfiguration`; edit the per-metric
`bar:` strings in `refresh()`.

---

## 6. Alternatives at a glance

| Concern | This project | Main alternative | When to switch |
|---|---|---|---|
| Menu-bar UI | `NSStatusItem` + SwiftUI popover | SwiftUI `MenuBarExtra` | Starting fresh, simple label → use `MenuBarExtra` |
| Popover config UI | SwiftUI list | AppKit `NSMenu` checkmarks | Want a classic menu, fewer frameworks |
| Update model | configurable `Timer` (`.common` mode) | `DispatchSourceTimer` / event callbacks | Readers get slow, or you need instant power events |
| Metric model | enum + sample dict | one type per metric (protocol) | Metrics gain complex per-type behavior |
| OS reads | mach/BSD/IOKit | shell out / 3rd-party lib | Prototyping (shell) / avoid C-interop (lib) |
| Real-time power | IOReport energy deltas via `dlsym` | SMC `SystemLoad` / `powermetrics` | Want whole-system watts (SMC, but stale) / detail+root (powermetrics) |
| Temperature | private IOHID via `dlsym` | C shim / SMC / `powermetrics` | Need cleaner calls (shim) — at cost of graceful fallback |
| Build | `swiftc` + hand bundle | Xcode / SwiftPM | Need notarization/assets (Xcode); SwiftPM once fixed |
| Login | LaunchAgent | `SMAppService` | After proper code-signing → nicer in-app toggle |

---

## 7. Things deliberately left out

- **No persistence of metric *values*** — only which metrics are pinned. A
  monitor shows "now"; history would mean a store and graphs.
- **No notarization / Developer ID signing** — ad-hoc signing is enough for a
  locally-built personal tool. Distributing to others would require signing +
  notarization (and then `SMAppService` becomes the better login mechanism).
- **No settings window** — the popover is the only surface. Interval and a
  "start at login" toggle would be the first additions if it grew.
