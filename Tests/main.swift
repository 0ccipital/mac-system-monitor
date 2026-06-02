import Foundation

// Lightweight test runner (no XCTest — SwiftPM is unavailable here). Compiles
// the reader sources directly; see test.sh. Exits non-zero on any failure.
//
//   argv[1] = seconds for the value-range test (default 30)

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so output survives a crash

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print((ok ? "  ok    " : "  FAIL  ") + msg)
    if !ok { failures += 1 }
}

// MARK: Smoke — construction and one-shot reads must not crash.
print("== smoke ==")
let cpu = CPUReader()
let net = NetworkReader()
let thermal = ThermalReader()
let power = PowerReportReader()
_ = cpu.sample()
_ = net.sample()
_ = power.sampleWatts()
_ = MetricsManager()                       // init wiring (timer/logger/readers)
check(true, "readers + manager construct")
check(SystemReaders.memory() != nil, "memory() returns a value")
check(!SystemReaders.uptime().isEmpty, "uptime() formats")
check(!SystemReaders.disks().isEmpty, "disks() finds ≥1 local volume")

// MARK: Value ranges over time — every reading must stay plausible.
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30
print("== value ranges (\(Int(seconds))s) ==")
_ = cpu.sample(); _ = net.sample(); _ = power.sampleWatts()   // establish baselines

let deadline = Date().addingTimeInterval(seconds)
var ticks = 0
while Date() < deadline {
    Thread.sleep(forTimeInterval: 1)
    ticks += 1
    if let c = cpu.sample() { check((0...100).contains(c), "cpu \(Int(c.rounded()))% ∈ 0–100") }
    if let m = SystemReaders.memory() {
        let p = Double(m.used) / Double(m.total) * 100
        check((0...100).contains(p) && m.used <= m.total, "mem \(Int(p.rounded()))% ∈ 0–100")
    }
    if let n = net.sample() { check(n.down >= 0 && n.up >= 0, "net ↓\(Int(n.down)) ↑\(Int(n.up)) ≥ 0") }
    if let d = SystemReaders.diskUsage() { check((0...100).contains(d), "disk \(Int(d.rounded()))% ∈ 0–100") }
    if let b = SystemReaders.battery() { check((0...100).contains(b.percent), "battery \(Int(b.percent.rounded()))% ∈ 0–100") }
    if power.isAvailable, let w = power.sampleWatts() { check(w >= 0 && w < 200, "power \(String(format: "%.1f", w))W ∈ 0–200") }
    if let t = thermal.temperature() { check(t > 0 && t < 150, "temp \(Int(t.rounded()))°C ∈ 0–150") }
}

print("\nticks: \(ticks)  •  \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
