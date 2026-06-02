import Foundation
import Combine

// Metric model, the manager (refresh loop + bar composition), and formatting.
// The sensor readers live in Readers.swift (public APIs) and Sensors.swift
// (private dlsym APIs).

// MARK: - Metric model

/// Every metric the app can read. This is the single source of truth: the
/// popover rows, the persisted pin set, and the bar all iterate `allCases`, so
/// adding a metric is "add a case (+ its `title`/`icon`/`help`) and produce a
/// `MetricSample` for it in `MetricsManager.performReads`".
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case memoryGB
    case disk
    case networkDown
    case networkUp
    case battery
    case power
    case systemPower
    case temperature
    case uptime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory %"
        case .memoryGB: return "Memory (GB)"
        case .disk: return "Disk"
        case .networkDown: return "Network ↓"
        case .networkUp: return "Network ↑"
        case .battery: return "Battery"
        case .power: return "Battery Power"
        case .systemPower: return "Power Draw"
        case .temperature: return "Temperature"
        case .uptime: return "Uptime"
        }
    }

    /// SF Symbol used in the dropdown.
    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .memoryGB: return "memorychip.fill"
        case .disk: return "internaldrive"
        case .networkDown: return "arrow.down.circle"
        case .networkUp: return "arrow.up.circle"
        case .battery: return "battery.100"
        case .power: return "bolt.fill"
        case .systemPower: return "bolt.horizontal.fill"
        case .temperature: return "thermometer.medium"
        case .uptime: return "clock"
        }
    }

    /// SF Symbol shown to the left of the value in the menu bar, for the
    /// metrics that read as a bare percentage. Others carry their own unit
    /// text (G, W, °C, ↑/↓) and get no symbol.
    var barSymbol: String? {
        switch self {
        case .cpu, .memory, .disk, .battery: return icon
        default: return nil
        }
    }

    /// Hover tooltip shown on the dropdown row.
    var help: String {
        switch self {
        case .cpu: return "Overall CPU load across all cores."
        case .memory: return "Memory in use as a percent of physical RAM (app + wired + compressed)."
        case .memoryGB: return "Memory in use / total, in GB."
        case .disk: return "Used space on each mounted local volume."
        case .networkDown: return "Download throughput (base-2 K/M per second)."
        case .networkUp: return "Upload throughput (base-2 K/M per second)."
        case .battery: return "Battery charge level; shows charging state in the row."
        case .power: return "Power into (+) or out of (−) the battery. SMC-limited (~30–60 s)."
        case .systemPower: return "Real-time package power: CPU + GPU + ANE + DRAM + display."
        case .temperature: return "Hottest SoC die sensor (tdie)."
        case .uptime: return "Time since last boot."
        }
    }
}

/// A single read of one metric: a long form for the dropdown (`detail`) and a
/// compact form for the menu-bar label (`bar`). `available == false` means the
/// metric isn't readable on this machine — the UI hides such rows and the bar
/// omits them.
struct MetricSample {
    var detail: String
    var bar: String
    var available: Bool

    /// An available reading.
    init(_ detail: String, bar: String) {
        self.init(detail: detail, bar: bar, available: true)
    }

    private init(detail: String, bar: String, available: Bool) {
        self.detail = detail
        self.bar = bar
        self.available = available
    }

    /// The shared "no data" value (hidden in the popover, omitted from the bar).
    static let unavailable = MetricSample(detail: "—", bar: "", available: false)
}

/// One piece of the menu-bar label: an optional leading SF Symbol plus its text.
struct BarSegment {
    let symbol: String?
    let text: String
}

// MARK: - Manager

/// Owns all state and the refresh loop; UI-agnostic (AppKit talks to it through
/// `onUpdate`, SwiftUI through `@Published`).
///
/// Threading: sensor reads run on a private serial `workQueue` (the readers,
/// their throttle bookkeeping, and `qCache` are touched *only* there). Each tick
/// marshals an immutable snapshot back to the main thread, which owns all the
/// `@Published` state and the timer. The two sides communicate only via the
/// snapshot and the `enabled`/`popoverOpen` values captured at dispatch — no
/// shared mutable state, so no locks.
final class MetricsManager: ObservableObject {
    @Published private(set) var samples: [MetricKind: MetricSample] = [:]   // main only
    @Published private(set) var enabled: Set<MetricKind>                    // main only
    @Published private(set) var interval: Double                            // main only

    /// Allowed refresh-interval range (seconds).
    static let minInterval = 0.1
    static let maxInterval = 10.0

    /// Called on the main thread after each refresh with the menu-bar segments.
    var onUpdate: (([BarSegment]) -> Void)?

    // --- workQueue-only state (sensor reads never touch the main thread) ---
    private let workQueue = DispatchQueue(label: "com.local.sysmonitor.read", qos: .utility)
    private let cpu = CPUReader()
    private let net = NetworkReader()
    private let thermal = ThermalReader()
    private let powerReport = PowerReportReader()
    private let logger = MetricsLogger()
    private var qCache: [MetricKind: MetricSample] = [:]   // last-known per metric
    private var lastRead: [String: TimeInterval] = [:]     // per-group throttle
    private var lastLog: TimeInterval = -.greatestFiniteMagnitude

    // --- main-thread state ---
    private var timer: Timer?
    private var cache: [MetricKind: MetricSample] = [:]
    private var popoverOpen = false
    private var isReading = false

    private static let enabledKey = "enabledMetrics"
    private static let intervalKey = "refreshInterval"
    private let logInterval: TimeInterval = 5

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.enabledKey) as? [String] {
            enabled = Set(saved.compactMap(MetricKind.init(rawValue:)))
        } else {
            enabled = [.cpu, .memory]
        }
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = saved > 0 ? saved : 2.0
    }

    func start() { scheduleTimer(); refreshNow() }

    /// Pause/resume while the display sleeps (nothing to show, nothing to read).
    func pause() { timer?.invalidate(); timer = nil }
    func resume() {
        // Drop stale baselines so the first post-wake reading is fresh next tick
        // rather than an average spanning the sleep.
        workQueue.async { self.cpu.reset(); self.net.reset(); self.powerReport.reset() }
        scheduleTimer()
        refreshNow()
    }

    /// Opening reads everything immediately so every row is fresh.
    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
        if open { refreshNow() }
    }

    /// Live slider drag: update the label only — no persist, no timer churn.
    func previewInterval(_ seconds: Double) {
        interval = min(Self.maxInterval, max(Self.minInterval, seconds))
    }
    /// Drag ended: persist and reschedule once (debounced).
    func commitInterval() {
        UserDefaults.standard.set(interval, forKey: Self.intervalKey)
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval * 0.2   // let the OS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func setEnabled(_ kind: MetricKind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
        composeBar()
    }

    // Timer-driven; drops if a read is still in flight (no pileup at 0.1 s).
    func refresh() { enqueueRead(force: false) }
    // User/event-driven (start, open, wake); always runs.
    func refreshNow() { enqueueRead(force: true) }

    private func enqueueRead(force: Bool) {
        if !force && isReading { return }
        isReading = true
        let en = enabled, open = popoverOpen
        workQueue.async {
            let snapshot = self.performReads(enabled: en, popoverOpen: open)
            DispatchQueue.main.async {
                self.cache = snapshot
                self.composeBar()
                if self.popoverOpen { self.samples = snapshot }
                self.isReading = false
            }
        }
    }

    /// Runs on workQueue. Reads the due metrics into `qCache`, logs every
    /// `logInterval`, and returns a snapshot of all last-known values.
    private func performReads(enabled: Set<MetricKind>, popoverOpen: Bool) -> [MetricKind: MetricSample] {
        let now = ProcessInfo.processInfo.systemUptime
        let logging = now - lastLog >= logInterval
        let readAll = popoverOpen || logging   // logging needs every value

        func due(_ group: String, _ kinds: [MetricKind], _ minPeriod: TimeInterval) -> Bool {
            let needed = readAll || kinds.contains { enabled.contains($0) }
            guard needed else { return false }
            if let last = lastRead[group], now - last < minPeriod { return false }
            lastRead[group] = now
            return true
        }

        if due("cpu", [.cpu], 0) {
            qCache[.cpu] = cpu.sample().map {
                let p = Int($0.rounded()); return MetricSample("\(p)%", bar: "\(p)%")
            } ?? .unavailable
        }

        if due("memory", [.memory, .memoryGB], 0) {
            if let mem = SystemReaders.memory() {
                let p = Int((Double(mem.used) / Double(mem.total) * 100).rounded())
                let gib = 1024.0 * 1024 * 1024
                qCache[.memory] = MetricSample("\(p)%", bar: "\(p)%")
                qCache[.memoryGB] = MetricSample(
                    String(format: "%.1f / %.0f GB", Double(mem.used) / gib, Double(mem.total) / gib),
                    bar: String(format: "%.1fG", Double(mem.used) / gib))
            } else {
                qCache[.memory] = .unavailable
                qCache[.memoryGB] = .unavailable
            }
        }

        if due("disk", [.disk], 15) {
            let all = SystemReaders.disks()
            // Bar shows the boot volume (or the first volume); the row lists all.
            if let headline = SystemReaders.diskUsage() ?? all.first?.percent {
                let detail = all.isEmpty ? "\(Int(headline.rounded()))%"
                    : all.map { "\($0.name) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
                qCache[.disk] = MetricSample(detail, bar: "\(Int(headline.rounded()))%")
            } else {
                qCache[.disk] = .unavailable
            }
        }

        if due("net", [.networkDown, .networkUp], 0) {
            if let (down, up) = net.sample() {
                qCache[.networkDown] = MetricSample(rate(down), bar: netBar("↓", down))
                qCache[.networkUp] = MetricSample(rate(up), bar: netBar("↑", up))
            } else {
                qCache[.networkDown] = .unavailable
                qCache[.networkUp] = .unavailable
            }
        }

        if due("battery", [.battery], 8) {
            qCache[.battery] = SystemReaders.battery().map { percent, charging in
                let p = Int(percent.rounded())
                return MetricSample("\(p)%\(charging ? " (charging)" : "")", bar: "\(p)%")
            } ?? .unavailable
        }

        if due("batteryPower", [.power], 8) {
            qCache[.power] = PowerReader.batteryFlowWatts().map { watts -> MetricSample in
                let mag = Int(abs(watts).rounded())
                if abs(watts) < 0.3 { return MetricSample("≈0 W", bar: "0W") }
                if watts > 0 { return MetricSample(String(format: "+%.1f W in", watts), bar: "+\(mag)W") }
                return MetricSample(String(format: "−%.1f W out", abs(watts)), bar: "−\(mag)W")
            } ?? .unavailable
        }

        if due("systemPower", [.systemPower], 0) {
            if powerReport.isAvailable {
                qCache[.systemPower] = powerReport.sampleWatts().map {
                    MetricSample(String(format: "%.2f W", $0), bar: String(format: "%.1fW", $0))
                } ?? MetricSample("…", bar: "")   // available, awaiting first baseline
            } else {
                qCache[.systemPower] = .unavailable
            }
        }

        if due("temp", [.temperature], 2) {
            qCache[.temperature] = thermal.temperature().map {
                let t = Int($0.rounded()); return MetricSample("\(t)°C", bar: "\(t)°C")
            } ?? .unavailable
        }

        if due("uptime", [.uptime], 30) {
            let up = SystemReaders.uptime()
            qCache[.uptime] = MetricSample(up, bar: up)
        }

        if logging {
            lastLog = now
            logger?.log(qCache)
        }
        return qCache
    }

    private func composeBar() {
        let segments = MetricKind.allCases.compactMap { kind -> BarSegment? in
            guard enabled.contains(kind), let s = cache[kind], s.available, !s.bar.isEmpty else { return nil }
            return BarSegment(symbol: kind.barSymbol, text: s.bar)
        }
        onUpdate?(segments)
    }

    // MARK: Formatting (base-2 / network "spec" units)

    /// Detail-row network string (the popover has room for full units).
    private func rate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    /// Compact bar token: value + single-letter unit + direction arrow, e.g.
    /// "14.7K↓" / "1.6M↑". Base-2 (1024) to match the detail row.
    private func netBar(_ arrow: String, _ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        let value: Double, unit: String
        if kb < 1024 { value = kb; unit = "K" } else { value = kb / 1024; unit = "M" }
        return String(format: "%.1f", value) + unit + arrow
    }
}
