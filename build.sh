#!/bin/bash
# Build SysMonitor and assemble a runnable .app bundle.
# Compiles with swiftc directly (the SwiftPM manifest API in the installed
# Command Line Tools is broken), so no Xcode/SwiftPM is required.
set -euo pipefail

cd "$(dirname "$0")"

APP="SysMonitor.app"
BIN_NAME="SysMonitor"
OUT=".build/direct"

echo "▸ Compiling…"
mkdir -p "$OUT"
swiftc -O -o "$OUT/$BIN_NAME" \
    Sources/SysMonitor/*.swift \
    -framework Cocoa -framework SwiftUI -framework IOKit \
    -target arm64-apple-macosx13.0

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SysMonitor</string>
    <key>CFBundleDisplayName</key>     <string>System Monitor</string>
    <key>CFBundleExecutable</key>      <string>SysMonitor</string>
    <key>CFBundleIdentifier</key>      <string>com.local.sysmonitor</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing…"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  Run with:  open $APP"
echo "  Or for logs:  ./$APP/Contents/MacOS/$BIN_NAME"
