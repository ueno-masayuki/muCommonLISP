#!/bin/bash
# make-app.sh — build muCommonLISP.app (macOS application bundle)
# usage: scripts/make-app.sh  (from the repository root)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== building (release) =="
swift build -c release --product muCommonLISP

BIN=".build/release/muCommonLISP"
APP="dist/muCommonLISP.app"

echo "== assembling ${APP} =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/muCommonLISP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>muCommonLISP</string>
    <key>CFBundleDisplayName</key>     <string>muCommonLISP</string>
    <key>CFBundleIdentifier</key>      <string>jp.mu.commonlisp</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleExecutable</key>      <string>muCommonLISP</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true

echo "done: $APP"
echo "open it with:  open $APP"
