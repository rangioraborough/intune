#!/bin/bash
## Build "MacAgent Console.app" for the IT Mac that the fleet reports to.
##   ./build-console.sh                  signed with the Developer ID Application certificate
##   APP_IDENTITY=- ./build-console.sh   ad-hoc, for this Mac only
## Output: dist/MacAgent Console.app (copy it to /Applications on the IT Mac).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/MacAgentCore/Paths.swift)
APP_IDENTITY="${APP_IDENTITY:-Developer ID Application: Tony Myers (25ZM6S7AH2)}"
APP="dist/MacAgent Console.app"

swift build -c release --product MacAgentConsole
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacAgentConsole "$APP/Contents/MacOS/MacAgentConsole"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>nz.co.myers.macagent.console</string>
    <key>CFBundleName</key><string>MacAgent Console</string>
    <key>CFBundleExecutable</key><string>MacAgentConsole</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
if [ "$APP_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP" && echo "==> Built $APP"
