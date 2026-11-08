#!/bin/sh
# Build the Telltale executable and wrap it in build/Telltale.app (ad-hoc signed, no Dock icon).
# Usage: Scripts/bundle.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Telltale"

APP="build/Telltale.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Telltale"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $PWD/$APP"
