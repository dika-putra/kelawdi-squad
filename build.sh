#!/bin/bash
# Builds build/Kelawdi Squad.app (menu bar only, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"
# Universal binary (Apple Silicon and Intel).
swift build -c release --arch arm64 --arch x86_64
APP="build/Kelawdi Squad.app"
# Build id shown in the popup header: short git hash, "-dirty" when there are uncommitted changes.
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
git diff --quiet HEAD -- 2>/dev/null || BUILD="$BUILD-dirty"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/KelawdiSquad" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp assets/AppIcon.icns assets/MenuBarIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Kelawdi Squad</string>
<key>CFBundleIdentifier</key><string>com.dienn.kelawdisquad</string>
<key>CFBundleExecutable</key><string>KelawdiSquad</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleShortVersionString</key><string>0.1.5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Brings a minimized Claude window back when you click Show.</string>
</dict></plist>
PLIST
# SIGN_ID=<codesigning identity> keeps the same signature across builds, so the Accessibility permission survives rebuilds.
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"
