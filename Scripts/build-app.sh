#!/bin/bash
# Builds Repose in release mode and wraps it in dist/Repose.app.
# The bundle is ad-hoc signed so macOS can attach the Accessibility grant to it.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Repose.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Repose" "$APP/Contents/MacOS/Repose"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --identifier com.repose.app "$APP"

echo
echo "Built $APP"
echo "Launch with:  open \"$APP\""
