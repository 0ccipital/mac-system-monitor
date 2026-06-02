#!/bin/bash
# Build, deploy to ~/Applications, and register to launch at login.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="com.local.sysmonitor"
DEST="$HOME/Applications/SysMonitor.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$DEST/Contents/MacOS/SysMonitor"
UID_NUM="$(id -u)"

# 1. Build the bundle.
./build.sh

# 2. Stop any running/registered instance.
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x SysMonitor 2>/dev/null || true
sleep 1

# 3. Deploy to a stable location.
echo "▸ Deploying to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R SysMonitor.app "$DEST"

# 4. Write the LaunchAgent. KeepAlive only on crash (SuccessfulExit=false), so
#    the app restarts if it crashes but a clean Quit (exit 0) stays quit.
echo "▸ Installing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                  <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>              <true/>
    <key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key>           <string>Interactive</string>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
</dict>
</plist>
PLIST_EOF

# 5. Load it (also starts it now via RunAtLoad).
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "✓ Deployed to $DEST and registered at login."
echo "  Running now via launchd. Quit from the popover; relaunches at next login."
