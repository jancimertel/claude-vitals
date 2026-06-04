#!/usr/bin/env bash
# Build release + wrap into an ad-hoc-signed ClaudeVitals.app (LSUIElement, bundle id)
# so UNUserNotifications + SMAppService work. Personal use: ad-hoc signing is enough.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeVitals.app"
BIN="ClaudeVitals"
BUNDLE_ID="com.janci.claudevitals"
VERSION="0.1.0"

echo "==> swift build -c release"
swift build -c release
BINPATH="$(swift build -c release --show-bin-path)/$BIN"

echo "==> laying out $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINPATH" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeVitals</string>
    <key>CFBundleDisplayName</key>     <string>Claude Vitals</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$BIN</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key> <string>Reads ~/.claude only. No network.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> done: $(pwd)/$APP"
echo "Run: open $APP   (or move it to /Applications)"
