import Foundation

/// Appends a CSV line of all metric values to ~/Documents/SysMonitor.csv every
/// few seconds, rolling the file so it never exceeds ~1 MB. File I/O runs on a
/// background queue. nil if Documents isn't writable.
final class MetricsLogger {
    private let url: URL
    private let queue = DispatchQueue(label: "com.local.sysmonitor.log", qos: .background)
    private let maxBytes = 1_000_000
    private let columns = MetricKind.allCases
    private let stamp = ISO8601DateFormatter()

    init?() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        url = docs.appendingPathComponent("SysMonitor.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? header().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func header() -> String {
        (["timestamp"] + columns.map { $0.title }).joined(separator: ",") + "\n"
    }

    /// Called on the read queue; builds the line there, writes on the log queue.
    func log(_ values: [MetricKind: MetricSample]) {
        let ts = stamp.string(from: Date())
        let cells = columns.map { kind -> String in
            let s = values[kind]
            let v = (s?.available == true) ? (s?.detail ?? "") : ""
            return v.replacingOccurrences(of: ",", with: ";")   // keep CSV intact
        }
        let line = ([ts] + cells).joined(separator: ",") + "\n"
        queue.async { self.append(line) }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        rollIfNeeded()
    }

    /// When the file passes the cap, keep the most recent ~half (whole lines)
    /// behind a fresh header. Cheap because it only fires every few thousand lines.
    private func rollIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(maxBytes / 2)
        guard let nl = tail.firstIndex(of: 0x0A) else { return }
        var out = Data(header().utf8)
        out.append(tail[tail.index(after: nl)...])
        try? out.write(to: url, options: .atomic)
    }
}
