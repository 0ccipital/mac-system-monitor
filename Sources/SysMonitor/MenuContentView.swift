import SwiftUI

/// The popover: one checkbox row per available metric (with live value and
/// tooltip), the refresh-interval slider, the launch-at-login toggle, and Quit.
/// A pure projection of `MetricsManager` — all writes go back through it.
struct MenuContentView: View {
    @ObservedObject var metrics: MetricsManager
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text("System Monitor").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                ForEach(MetricKind.allCases) { kind in
                    if let sample = metrics.samples[kind], sample.available {
                        row(kind, sample)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Update interval")
                    Spacer()
                    Text(String(format: "%.1fs", metrics.interval))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                // Live drag updates the label only; persist + reschedule once on release.
                Slider(value: intervalBinding,
                       in: MetricsManager.minInterval...MetricsManager.maxInterval,
                       step: 0.1,
                       onEditingChanged: { editing in if !editing { metrics.commitInterval() } })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .help("How often metrics refresh. 0.1 s is for debugging.")

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { LoginItem.setEnabled($0) }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help("Start System Monitor automatically when you log in.")

            Divider()

            HStack {
                Text("Check items to pin to the menu bar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var intervalBinding: Binding<Double> {
        Binding(get: { metrics.interval }, set: { metrics.previewInterval($0) })
    }

    private func row(_ kind: MetricKind, _ sample: MetricSample) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: binding(kind))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: kind.icon)
                .frame(width: 18)
                .foregroundColor(.secondary)
            Text(kind.title)
            Spacer()
            Text(sample.detail)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(kind.help)
    }

    private func binding(_ kind: MetricKind) -> Binding<Bool> {
        Binding(
            get: { metrics.enabled.contains(kind) },
            set: { metrics.setEnabled(kind, $0) }
        )
    }
}
