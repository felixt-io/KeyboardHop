#!/bin/bash
# Builds a universal KeyboardHop.app and a .dmg into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="dist/KeyboardHop.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Per-arch builds + lipo (works with Command Line Tools only, no full Xcode needed)
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
lipo -create \
  .build/arm64-apple-macosx/release/KeyboardHop \
  .build/x86_64-apple-macosx/release/KeyboardHop \
  -output "$APP/Contents/MacOS/KeyboardHop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

codesign --force --sign - "$APP"        # ad-hoc signature (not notarized)

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "KeyboardHop" -srcfolder "$STAGE" -ov -format UDZO "dist/KeyboardHop-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "Built dist/KeyboardHop.app and dist/KeyboardHop-$VERSION.dmg"
