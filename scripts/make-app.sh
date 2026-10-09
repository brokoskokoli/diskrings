#!/bin/bash
# Baut build/DiskRings.app aus dem Release-Build.
# Signatur vorerst ad hoc; Developer ID, Hardened Runtime und Notarisierung folgen in M7.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DiskRings.app
BUNDLE_ID=de.stefanrichter.DiskRings
VERSION=${VERSION:-0.3.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}

echo "==> swift build -c release"
swift build -c release --product DiskRings
BIN="$(swift build -c release --show-bin-path)/DiskRings"

echo "==> Bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskRings"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>DiskRings</string>
    <key>CFBundleDisplayName</key><string>DiskRings</string>
    <key>CFBundleExecutable</key><string>DiskRings</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Stefan Richter</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "==> $APP"
