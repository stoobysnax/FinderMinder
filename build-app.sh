#!/bin/bash
# Builds FinderMinder.app into ./build. Requires the Xcode Command Line Tools
# (run `xcode-select --install` once if `swift` is not found).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/FinderMinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FinderMinder" "$APP/Contents/MacOS/FinderMinder"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS can track the Accessibility permission.
codesign --force --deep --sign - --identifier com.stoobysnax.FinderMinder "$APP"

echo "Built $APP"
echo "Move it to /Applications and open it:  mv \"$APP\" /Applications/ && open /Applications/FinderMinder.app"
