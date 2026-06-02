import Cocoa
import SwiftUI

/// Owns the status item and popover, and bridges `MetricsManager` to AppKit:
/// renders the bar segments into the status button's `attributedTitle`, and
/// pauses monitoring while the display sleeps.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let metrics = MetricsManager()
    private var latestSegments: [BarSegment] = []
    private let barFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    private let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    private var symbolCache: [String: NSImage] = [:]   // built once per symbol name

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Tabular digits keep numbers from jittering as they change, while
        // proportional letters stay compact (full monospace was too wide).
        statusItem.button?.font = barFont

        let hosting = NSHostingController(rootView: MenuContentView(metrics: metrics))
        hosting.sizingOptions = [.preferredContentSize]   // size popover to content; no clipping
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting

        metrics.onUpdate = { [weak self] segments in self?.updateButton(segments) }
        metrics.start()

        // Stop all monitoring while the display is asleep — the menu bar can't
        // be seen, so there's nothing to update.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaySlept),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displayWoke),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func displaySlept() { metrics.pause() }
    @objc private func displayWoke() { metrics.resume() }

    private func updateButton(_ segments: [BarSegment]) {
        latestSegments = segments
        // While the popover is open, freeze the label so the button width — and
        // thus the popover's anchor — doesn't shift under the cursor on refresh
        // or when toggling a checkbox. The latest value is applied on close.
        guard !popover.isShown else { return }
        applyBar(segments)
    }

    private func applyBar(_ segments: [BarSegment]) {
        guard let button = statusItem.button else { return }
        if segments.isEmpty {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                                   accessibilityDescription: "System Monitor")
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.image = nil
        button.attributedTitle = makeTitle(segments)
    }

    /// Cached template symbol image (created once per name, not per refresh).
    private func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else { return nil }
        image.isTemplate = true
        symbolCache[name] = image
        return image
    }

    /// Build the menu-bar label: each segment's optional SF Symbol (as a
    /// template image attachment, so it tints with the menu bar) followed by
    /// its text, segments joined by a single space.
    private func makeTitle(_ segments: [BarSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: barFont]))
            }
            if let name = segment.symbol, let image = symbol(name) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let h = image.size.height
                attachment.bounds = CGRect(x: 0, y: (barFont.capHeight - h) / 2,
                                           width: image.size.width, height: h)
                result.append(NSAttributedString(attachment: attachment))
            }
            result.append(NSAttributedString(string: segment.text, attributes: [.font: barFont]))
        }
        return result
    }

    func popoverDidClose(_ notification: Notification) {
        metrics.setPopoverOpen(false)
        applyBar(latestSegments)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            metrics.setPopoverOpen(true)   // read everything before showing
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
