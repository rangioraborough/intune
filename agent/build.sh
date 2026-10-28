#!/bin/bash
## Build a universal, signed MacAgent .pkg ready to upload to Intune as a macOS app (PKG).
##
##   ./build.sh                 build, sign app, sign pkg (if the Installer cert is present)
##   NOTARY_PROFILE=macagent ./build.sh
##                              ...and notarise + staple. Create the profile once with:
##                              xcrun notarytool store-credentials macagent --apple-id ... --team-id 25ZM6S7AH2
##
## Override signing identities with APP_IDENTITY / PKG_IDENTITY, or set APP_IDENTITY=- for an
## ad-hoc signed local test build.

set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/MacAgentCore/Paths.swift)
[ -n "$VERSION" ] || { echo "could not read AgentVersion.current"; exit 1; }
BUNDLE_ID="nz.co.myers.macagent"
APP_IDENTITY="${APP_IDENTITY:-Developer ID Application: Tony Myers (25ZM6S7AH2)}"
PKG_IDENTITY="${PKG_IDENTITY:-Developer ID Installer: Tony Myers (25ZM6S7AH2)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

DIST="dist"
ROOT="$DIST/root"
APP="$ROOT/Applications/MacAgent.app"
PKG="$DIST/MacAgent-$VERSION.pkg"

echo "==> MacAgent $VERSION"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/Library/LaunchDaemons" "$ROOT/Library/LaunchAgents"

echo "==> Testing"
swift test --quiet

## The command line tools can't build multi-arch in one go, so build each slice and lipo them.
for arch in arm64 x86_64; do
    echo "==> Building $arch"
    swift build -c release --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch"
done
lipo -create -output "$APP/Contents/MacOS/macagent" \
    .build/arm64/release/macagent .build/x86_64/release/macagent
lipo -create -output "$APP/Contents/MacOS/MacAgentMenu" \
    .build/arm64/release/MacAgentMenu .build/x86_64/release/MacAgentMenu
lipo -info "$APP/Contents/MacOS/macagent" "$APP/Contents/MacOS/MacAgentMenu"

sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift packaging/make-icon.swift "$PWD/packaging/AppIcon.icns"
cp vendor/Installomator.sh "$APP/Contents/Resources/Installomator.sh"
chmod 755 "$APP/Contents/Resources/Installomator.sh"
cp packaging/launchd/nz.co.myers.macagent.daemon.plist "$ROOT/Library/LaunchDaemons/"
cp packaging/launchd/nz.co.myers.macagent.session.plist packaging/launchd/nz.co.myers.macagent.menu.plist \
    "$ROOT/Library/LaunchAgents/"

echo "==> Signing apps ($APP_IDENTITY)"
sign() {   # bundle, identifier
    if [ "$APP_IDENTITY" = "-" ]; then
        codesign --force --sign - --identifier "$2" "$1"
    else
        codesign --force --options runtime --timestamp --identifier "$2" --sign "$APP_IDENTITY" "$1"
    fi
    codesign --verify --strict --verbose=1 "$1"
}
## The CLI is a second executable in Contents/MacOS: sign it first, then the bundle seals it in.
sign "$APP/Contents/MacOS/macagent" "$BUNDLE_ID.cli"
sign "$APP" "$BUNDLE_ID"

echo "==> Packaging"
## pkgbuild marks bundles relocatable by default: if a copy of MacAgent.app with the same bundle ID
## exists anywhere else, Installer would "upgrade" that one instead. Pin it to its real path.
pkgbuild --analyze --root "$ROOT" "$DIST/component.plist" >/dev/null
for i in $(seq 0 $(( $(/usr/libexec/PlistBuddy -c "Print" "$DIST/component.plist" | grep -c "RootRelativeBundlePath") - 1 ))); do
    /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$DIST/component.plist"
done
pkgbuild --root "$ROOT" --component-plist "$DIST/component.plist" --scripts packaging/scripts \
    --identifier "$BUNDLE_ID" --version "$VERSION" \
    --install-location / --ownership recommended "$DIST/component.pkg" >/dev/null
rm "$DIST/component.plist"

signed=0
if security find-identity -v -p basic | grep -qF "$PKG_IDENTITY"; then
    productbuild --package "$DIST/component.pkg" --sign "$PKG_IDENTITY" --timestamp "$PKG" >/dev/null
    signed=1
else
    productbuild --package "$DIST/component.pkg" "$PKG" >/dev/null
    echo "!!  '$PKG_IDENTITY' not in the keychain: $PKG is UNSIGNED."
    echo "    Create a Developer ID Installer certificate at developer.apple.com to sign it."
fi
rm "$DIST/component.pkg"

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$signed" = 1 ]; then
        echo "==> Notarising"
        xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$PKG"
    else
        echo "!!  Skipping notarisation: the pkg isn't signed."
    fi
fi

echo "==> Built $PKG"
shasum -a 256 "$PKG"
