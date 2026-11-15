#!/usr/bin/env bash
# Build release + wrap into an ad-hoc-signed "Claude Vitals.app" (LSUIElement, bundle id)
# so UNUserNotifications + SMAppService work. Personal use: ad-hoc signing is enough.
# Usage: ./make_app.sh             build "./Claude Vitals.app"
#        ./make_app.sh --install   build, move it to /Applications, relaunch
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Vitals.app"
OLD_APP="ClaudeVitals.app"      # the bundle's name before the rename
BIN="ClaudeVitals"
BUNDLE_ID="com.janci.claudevitals"
VERSION="0.1.0"

# Command Line Tools ship no SwiftUI macro plugin, and from the macOS 27 SDK on @State is a
# macro, so builds fail with "plugin for module 'SwiftUIMacros' not found". Without Xcode,
# fall back to the newest installed macOS 26 SDK, where @State is still a property wrapper.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
    SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$SDK" ]]; then
        export SDKROOT="$SDK"
        echo "==> Command Line Tools only: building against $(basename "$SDK")"
    fi
fi

echo "==> swift build -c release"
swift build -c release
BINPATH="$(swift build -c release --show-bin-path)/$BIN"

echo "==> laying out $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINPATH" "$APP/Contents/MacOS/$BIN"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeVitals</string>
    <key>CFBundleDisplayName</key>     <string>Claude Vitals</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$BIN</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
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

# A leftover bundle under the old name has the same bundle id, so macOS may launch it at login
# instead of this one. Only point it out: deleting is the user's call.
warn_old_app() {
    local old
    for old in "$(pwd)/$OLD_APP" "/Applications/$OLD_APP"; do
        if [[ -e "$old" ]]; then
            echo "==> warning: an old copy is still at $old (the app is now \"$APP\")."
            echo "    Delete it so macOS doesn't launch it at login: rm -rf \"$old\""
        fi
    done
}

# --install: replace "/Applications/Claude Vitals.app" with this build and relaunch it. The build is
# moved, not copied, so Spotlight and Launchpad list one Claude Vitals instead of two.
if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP"
    echo "==> installing to $DEST"
    pkill -x "$BIN" || true
    rm -rf "$DEST"
    mv "$APP" "$DEST"
    open "$DEST"
    echo "==> done: $DEST is running"
    warn_old_app
    exit 0
fi

echo "==> done: $(pwd)/$APP"
echo "Run: open \"$APP\"   (or ./make_app.sh --install to put it in /Applications)"
warn_old_app
