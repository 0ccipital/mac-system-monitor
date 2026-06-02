import Foundation

/// Reads hardware temperature sensors on Apple Silicon via the private IOHID
/// thermal-sensor API. The symbols are not in the public SDK, so we resolve
/// them at runtime with dlsym — if anything is missing the reader simply
/// reports no data and the UI hides the metric.
final class ThermalReader {
    private typealias CreateFn       = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn  = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias CopyEventFn    = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn     = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer?, CFString) -> Unmanaged<CFTypeRef>?

    // kIOHIDEventTypeTemperature == 15; field base is (type << 16).
    private let kTemperatureType: Int64 = 15
    private let kTemperatureField: Int32 = 15 << 16

    private var client: UnsafeMutableRawPointer?
    private let copyServices: CopyServicesFn?
    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private let copyProperty: CopyPropertyFn?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)

        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let c = create(kCFAllocatorDefault) else { return }

        // PrimaryUsagePage 0xff00 (AppleVendor), PrimaryUsage 5 (temperature sensor).
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(c, matching as CFDictionary)
        client = c
    }

    /// Hottest SoC die sensor (`tdie*`) in °C, or nil if none. The die sensors
    /// are the meaningful "chip temperature"; we skip battery/SSD/board/`tcal`.
    func temperature() -> Double? {
        guard let client, let copyServices, let copyEvent, let getFloat, let copyProperty,
              let servicesU = copyServices(client) else { return nil }

        let services = servicesU.takeRetainedValue()
        let count = CFArrayGetCount(services)
        guard count > 0 else { return nil }

        var hottest: Double?
        for i in 0..<count {
            guard let svc = CFArrayGetValueAtIndex(services, i) else { continue }
            let svcMut = UnsafeMutableRawPointer(mutating: svc)
            guard let name = copyProperty(svcMut, "Product" as CFString)?.takeRetainedValue() as? String,
                  name.contains("tdie") else { continue }
            guard let event = copyEvent(svcMut, kTemperatureType, 0, 0) else { continue }
            let temp = getFloat(event, kTemperatureField)
            // copyEvent returns a +1 CFTypeRef as a raw pointer; balance it.
            Unmanaged<AnyObject>.fromOpaque(event).release()
            if temp > 0, temp < 150 { hottest = Swift.max(hottest ?? temp, temp) }
        }
        return hottest
    }
}

/// Real-time package power (CPU + GPU + ANE + DRAM + display + …) via the
/// private IOReport energy counters. Power = energy consumed between two samples
/// ÷ elapsed time, so it tracks load as fast as it's polled — unlike the SMC
/// battery telemetry, which only refreshes every ~30–60 s. Symbols are resolved
/// with dlsym so a missing framework degrades to "unavailable" rather than
/// crashing.
final class PowerReportReader {
    private typealias CopyChannelsFn  = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubFn     = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn         = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn       = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias StringGetFn     = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntValueFn      = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamplesFn?
    private let delta: DeltaFn?
    private let iterate: IterateFn?
    private let channelName: StringGetFn?
    private let unitLabel: StringGetFn?
    private let intValue: IntValueFn?

    private let subscription: AnyObject?
    private let subbedChannels: CFMutableDictionary?

    private var prevSample: CFDictionary?
    private var prevTime: TimeInterval = 0
    private var lastWatts: Double?

    // Top-level power rails in the "Energy Model" group. These are aggregates
    // (the cryptic per-cluster channels like PCPUDTL*/ECPU* are their
    // components, deliberately excluded to avoid double-counting). Summing them
    // approximates total package power and stays responsive. Names vary by chip;
    // unknown ones simply don't match. Held as CFStrings so the per-channel
    // test uses CFEqual with no Swift String bridging (the group has ~200
    // channels and only ~14 matter).
    private let wantedNames: [CFString] = [
        "CPU Energy", "GPU Energy", "ANE", "ANE Energy", "DRAM",
        "DISP", "DISPEXT", "AMCC", "DCS", "ISP", "AVE", "MSR",
        "PCIe Port 0 Energy", "PCIe Port 1 Energy"
    ].map { $0 as CFString }

    /// True when the API resolved and a subscription exists. The UI uses this
    /// so the row stays visible even before the first baseline sample.
    var isAvailable: Bool { subscription != nil && subbedChannels != nil }

    /// Drop the baseline (e.g. after display wake) so the next reading is fresh
    /// rather than an average spanning the gap.
    func reset() { prevSample = nil; prevTime = 0 }

    init() {
        let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }

        createSamples = sym("IOReportCreateSamples", CreateSamplesFn.self)
        delta = sym("IOReportCreateSamplesDelta", DeltaFn.self)
        iterate = sym("IOReportIterate", IterateFn.self)
        channelName = sym("IOReportChannelGetChannelName", StringGetFn.self)
        unitLabel = sym("IOReportChannelGetUnitLabel", StringGetFn.self)
        intValue = sym("IOReportSimpleGetIntegerValue", IntValueFn.self)

        guard let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsFn.self),
              let createSub = sym("IOReportCreateSubscription", CreateSubFn.self),
              let chans = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            subscription = nil; subbedChannels = nil; return
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, chans, &subbed, 0, nil) else {
            subscription = nil; subbedChannels = nil; return
        }
        subscription = subU.takeRetainedValue()
        subbedChannels = subbed?.takeRetainedValue()
    }

    /// Total package power in watts. nil until a baseline sample exists
    /// (first call) or if the API is unavailable.
    func sampleWatts() -> Double? {
        guard let createSamples, let delta, let iterate, let channelName,
              let unitLabel, let intValue, let subbedChannels, let subscription
        else { return nil }

        let subPtr = Unmanaged.passUnretained(subscription).toOpaque()
        guard let nowU = createSamples(subPtr, subbedChannels, nil) else { return nil }
        let now = nowU.takeRetainedValue()
        let t = ProcessInfo.processInfo.systemUptime

        defer { prevSample = now; prevTime = t }
        guard let prev = prevSample, let diffU = delta(prev, now, nil) else { return nil }
        let dt = t - prevTime
        guard dt > 0 else { return nil }
        let diff = diffU.takeRetainedValue()

        let acc = Accumulator()
        iterate(diff) { ch in
            // Compare the raw CFString via CFEqual — no Swift String allocation
            // for the ~200 channels we don't want.
            guard let nameCF = channelName(ch)?.takeUnretainedValue() else { return 0 }
            guard self.wantedNames.contains(where: { CFEqual(nameCF, $0) }) else { return 0 }
            let unit = (unitLabel(ch)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
            let scale: Double
            switch unit {
            case "nJ": scale = 1e-9
            case "uJ", "µJ": scale = 1e-6
            case "mJ": scale = 1e-3
            case "J": scale = 1
            default: return 0
            }
            acc.joules += Double(intValue(ch, 0)) * scale
            return 0
        }
        // At very short intervals the counters may not have advanced (delta 0);
        // hold the previous value rather than reporting a spurious ~0 W.
        if acc.joules == 0, let last = lastWatts { return last }
        let watts = acc.joules / dt
        lastWatts = watts
        return watts
    }

    /// Reference box so the `@convention(block)` iterate callback can accumulate
    /// into captured mutable state (a struct/var can't be captured by-ref there).
    private final class Accumulator { var joules = 0.0 }
}
