import Foundation

/// Launch-at-login via a per-user LaunchAgent. Presence of the plist controls
/// whether launchd starts the app at the next login. `KeepAlive` restarts the
/// app on a crash but lets a clean Quit (exit 0) stick. Toggling off just
/// removes the plist — it does not disturb the running instance.
enum LoginItem {
    static let label = "com.local.sysmonitor"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>                  <string>\(label)</string>
                <key>ProgramArguments</key>       <array><string>\(exe)</string></array>
                <key>RunAtLoad</key>              <true/>
                <key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
                <key>ProcessType</key>            <string>Interactive</string>
                <key>LimitLoadToSessionType</key> <string>Aqua</string>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
