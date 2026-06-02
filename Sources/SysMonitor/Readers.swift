import Foundation
import IOKit
import IOKit.ps

/// The host port is a well-known port; fetch it once instead of on every read
/// (each `mach_host_self()` call adds a port reference that would otherwise leak).
let machHostPort = mach_host_self()

// MARK: - Stateless readers (public APIs)

/// One-shot system reads with no retained state. Each returns `nil` when the
/// metric isn't available on this machine (e.g. battery on a desktop).
enum SystemReaders {
    /// "In use" memory, matching Activity Monitor's "Memory Used":
    /// app memory (internal − purgeable) + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let appMemory = stats.internal_page_count >= stats.purgeable_count
            ? UInt64(stats.internal_page_count - stats.purgeable_count) : 0
        let used = (appMemory + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return (used, total)
    }

    /// Percent used on the boot volume (`/`).
    static func diskUsage() -> Double? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let avail = values.volumeAvailableCapacity, total > 0
        else { return nil }
        return Double(total - avail) / Double(total) * 100
    }

    /// Percent used for each mounted, browsable, *local* (non-network) volume.
    /// Firmlinked duplicates (same name + capacity) are de-duped.
    static func disks() -> [(name: String, percent: Double)] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        guard let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var seen = Set<String>()
        var out: [(String, Double)] = []
        for url in vols {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.volumeIsLocal == true, v.volumeIsBrowsable == true,
                  let total = v.volumeTotalCapacity, total > 0,
                  let avail = v.volumeAvailableCapacity, let name = v.volumeName else { continue }
            if seen.insert("\(name)|\(total)").inserted {
                out.append((name, Double(total - avail) / Double(total) * 100))
            }
        }
        return out
    }

    /// Battery charge percent and *actual* charging state (not merely "on AC",
    /// which is true at 100% too). `nil` on machines without a battery.
    static func battery() -> (percent: Double, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0
            else { continue }
            let charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            return (Double(cur) / Double(max) * 100, charging)
        }
        return nil
    }

    /// Human-readable uptime, e.g. "2d 3h", "9h 46m", "45m".
    static func uptime() -> String {
        let t = Int(ProcessInfo.processInfo.systemUptime)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Battery power flow (from AppleSmartBattery)

enum PowerReader {
    /// Signed battery wattage: + charging (power in), − discharging (power out).
    /// `nil` on machines without a battery. The SMC refreshes this only every
    /// ~30–60 s, so it changes slowly regardless of poll rate — for real-time
    /// consumption see `PowerReportReader` (Power Draw).
    static func batteryFlowWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // Fetch just the two keys we need rather than copying the whole
        // AppleSmartBattery dictionary (which is large — telemetry, cell data…).
        func intProperty(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        guard let voltage = intProperty("Voltage"),    // mV
              let amperage = intProperty("Amperage")    // mA, signed
        else { return nil }

        return Double(voltage) / 1000.0 * Double(amperage) / 1000.0
    }
}

// MARK: - CPU (stateful: utilization = busy/total tick deltas between samples)

final class CPUReader {
    private var prev: host_cpu_load_info?
    private var last: Double?

    /// Drop the baseline (e.g. after display wake) so the next sample doesn't
    /// report an average spanning the gap.
    func reset() { prev = nil }

    /// Overall CPU load 0–100 across all cores, or `nil` before a baseline
    /// exists. Holds the last value when two samples land in the same tick
    /// window (sub-second intervals), so the metric never blinks out.
    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(machHostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { prev = info }
        guard let p = prev else { return nil }

        let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return last }
        let pct = busy / total * 100
        last = pct
        return pct
    }
}

// MARK: - Network (stateful: throughput = byte deltas / elapsed time)

final class NetworkReader {
    private var prev: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    /// Virtual interface prefixes that mirror or don't represent real traffic
    /// (VPN tunnels, AirDrop/Wi-Fi-aware, bridges, VMs) — counting them would
    /// double-count or inflate throughput.
    private static let virtualPrefixes = ["lo", "utun", "awdl", "llw", "bridge",
                                          "gif", "stf", "ap", "vmnet", "anpi", "vnic"]

    func reset() { prev = nil }

    /// Aggregate download/upload bytes-per-second across physical interfaces,
    /// or `nil` if the interface list can't be read. Returns `(0, 0)` before a
    /// baseline exists or if counters wrap.
    func sample() -> (down: Double, up: Double)? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  (flags & IFF_LOOPBACK) == 0,
                  let data = cur.pointee.ifa_data else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if Self.virtualPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let nd = data.assumingMemoryBound(to: if_data.self)
            rx += UInt64(nd.pointee.ifi_ibytes)
            tx += UInt64(nd.pointee.ifi_obytes)
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { prev = (rx, tx, now) }
        guard let p = prev else { return (0, 0) }
        let dt = now - p.time
        guard dt > 0 else { return (0, 0) }
        let down = rx >= p.rx ? Double(rx - p.rx) / dt : 0   // clamp counter wrap/reset
        let up = tx >= p.tx ? Double(tx - p.tx) / dt : 0
        return (down, up)
    }
}
