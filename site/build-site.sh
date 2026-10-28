#!/bin/bash
## Build a school's site resources package: "MacAgent Site - <SCHOOL>.pkg".
## It installs the files listed in site/<school>/files.txt into
## /Library/Application Support/MacAgent/Site/, where the agent's config refers to them by name.
##
##   site/build-site.sh rbs
##
## Upload it to Intune as a second macOS app (PKG) next to MacAgent. Bump site/<school>/VERSION
## when files change so Intune sees an upgrade.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHOOL="${1:?usage: site/build-site.sh <school folder, e.g. rbs>}"
DIR="site/$SCHOOL"
[ -f "$DIR/files.txt" ] || { echo "no $DIR/files.txt"; exit 1; }
VERSION=$(cat "$DIR/VERSION")
ID="nz.co.myers.macagent.site.$SCHOOL"
PKG_IDENTITY="${PKG_IDENTITY:-Developer ID Installer: Tony Myers (25ZM6S7AH2)}"
NAME=$(echo "$SCHOOL" | tr '[:lower:]' '[:upper:]')
OUT="site/dist/MacAgent Site - $NAME-$VERSION.pkg"

ROOT=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$ROOT" "$WORK"' EXIT
DEST="$ROOT/Library/Application Support/MacAgent/Site"
mkdir -p "$DEST" site/dist

echo "==> MacAgent Site - $NAME $VERSION"
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    src=$(echo "${line%%->*}" | sed 's/[[:space:]]*$//')
    dst=$(echo "${line##*->}" | sed 's/^[[:space:]]*//')
    [ -f "$src" ] || { echo "missing: $src"; exit 1; }
    mkdir -p "$DEST/$(dirname "$dst")"
    cp -X "$src" "$DEST/$dst"   # no extended attributes, or pkgbuild adds ._ files
    echo "    $dst"
done < "$DIR/files.txt"
chmod -R a+rX "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

COMPONENT="$WORK/component.pkg"
COPYFILE_DISABLE=1 pkgbuild --root "$ROOT" --identifier "$ID" --version "$VERSION" --install-location / \
    --ownership recommended "$COMPONENT" >/dev/null

if security find-identity -v -p basic | grep -qF "$PKG_IDENTITY"; then
    productbuild --package "$COMPONENT" --sign "$PKG_IDENTITY" --timestamp "$OUT" >/dev/null
else
    productbuild --package "$COMPONENT" "$OUT" >/dev/null
    echo "!!  '$PKG_IDENTITY' not in the keychain: package is UNSIGNED."
fi
echo "==> Built $OUT"
