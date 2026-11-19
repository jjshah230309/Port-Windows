#!/bin/bash
# Builds dist/Attic.app (ad-hoc signed) plus a zip and a dmg, using only the Command Line Tools.
# Usage: scripts/build-app.sh [version]   (default version: `git describe`, else 0.0.0)
set -euo pipefail

APP_NAME="Attic"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

echo "==> Building $APP_NAME $version (arm64)"
swift build -c release --product "$APP_NAME"
bin_dir="$(swift build -c release --show-bin-path)"

app="dist/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/$APP_NAME" "$app/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/components.json "$app/Contents/Resources/"
[ -d Resources/Licenses ] && cp -R Resources/Licenses "$app/Contents/Resources/"
plutil -replace CFBundleShortVersionString -string "${version%%-*}" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

echo "==> Icon"
scripts/make-icon.sh "$app/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --sign - --entitlements Resources/Attic.entitlements --timestamp=none "$app"
codesign --verify --strict --verbose=2 "$app"

echo "==> Packaging"
ditto -c -k --keepParent "$app" "dist/$APP_NAME-$version-arm64.zip"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$app" -ov -format UDZO "dist/$APP_NAME-$version-arm64.dmg"
echo "Built $app"
