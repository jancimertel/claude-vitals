#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from make_icon.swift. The .icns is committed, so make_app.sh
# doesn't need this; run it only after changing the drawing.
set -euo pipefail
cd "$(dirname "$0")"

# Same Command Line Tools SDK fallback as make_app.sh.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
    SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "$SDK" ]] && export SDKROOT="$SDK"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift make_icon.swift "$TMP/icon.png"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "==> wrote $(pwd)/AppIcon.icns"
