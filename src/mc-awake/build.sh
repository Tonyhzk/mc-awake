#!/bin/bash
# McAwake build script.
#
#   ./build.sh              build McAwake.app into build/
#   ./build.sh --install    build + install to /Applications + (re)launch
#   ./build.sh --release    build + zip a shareable dist/McAwake-<ver>.zip
#
# Requires the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/McAwake.app"

# App icon: generate once, then it's cached in Resources/
if [ ! -f Resources/AppIcon.icns ]; then
  echo "Generating app icon..."
  swift scripts/make-icon.swift /tmp/mcawake-icon-1024.png
  ICONSET=/tmp/McAwake.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/mcawake-icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d /tmp/mcawake-icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$ICONSET" /tmp/mcawake-icon-1024.png
fi

echo "Compiling..."
mkdir -p build
swiftc -O Sources/main.swift Sources/BatteryGuard.swift -o build/McAwake

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp build/McAwake "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns \
   Resources/mcawake-auto.sh \
   Resources/com.mcawake.auto.plist \
   "$APP/Contents/Resources/"
# Strip extended attributes: building inside an iCloud Drive (or Dropbox)
# folder stamps files with file-provider xattrs (com.apple.fileprovider.*)
# that survive cp/ditto into /Applications AND into release zips — and
# Spotlight silently refuses to index bundles carrying them (found live:
# the installed app was invisible to Spotlight/Launchpad).
xattr -cr "$APP"
codesign --force --sign - "$APP" 2>/dev/null

echo "Built $APP (v$VERSION)"

if [ "${1:-}" = "--install" ]; then
  echo "Installing to /Applications..."
  pkill -f "McAwake.app/Contents/MacOS/McAwake" 2>/dev/null || true
  # A pkg-installed copy is owned by root:wheel, so plain rm/cp fail with
  # "Permission denied" — after pkill has already quit the running app,
  # leaving the stale binary installed and nothing in the menu bar. Escalate
  # only for the file operations; `open` stays unprivileged so the app runs
  # as you and not as root.
  if [ -e "/Applications/McAwake.app" ] && [ ! -w "/Applications/McAwake.app" ]; then
    echo "Existing install is root-owned (installed from the .pkg) — sudo:"
    sudo rm -rf "/Applications/McAwake.app"
    sudo cp -R "$APP" /Applications/
  else
    rm -rf "/Applications/McAwake.app"
    cp -R "$APP" /Applications/
  fi
  open "/Applications/McAwake.app"
  echo "McAwake is running — look for 🦉 or 💤 in the menu bar."
elif [ "${1:-}" = "--release" ]; then
  mkdir -p dist
  ZIP="dist/McAwake-${VERSION}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Shareable archive: $ZIP"

  # Installer package for non-developers: double-click → wizard →
  # /Applications, then postinstall launches the app as the console
  # user. Installer-placed files carry no quarantine flag, so the app
  # itself never needs the right-click → Open dance — only the pkg does.
  PKG="dist/McAwake-${VERSION}.pkg"
  PKGSCRIPTS=$(mktemp -d)
  cp scripts/pkg-postinstall "$PKGSCRIPTS/postinstall"
  chmod 755 "$PKGSCRIPTS/postinstall"
  pkgbuild --component "$APP" \
           --install-location /Applications \
           --identifier com.mcawake.app.pkg \
           --version "$VERSION" \
           --scripts "$PKGSCRIPTS" \
           "$PKG" >/dev/null
  rm -rf "$PKGSCRIPTS"
  echo "Installer package: $PKG"
fi
