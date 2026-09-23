#!/bin/bash
# Builds MacSense.app, one universal binary for Intel and Apple silicon Macs.
#   ./build.sh                      build into build/MacSense.app
#   ./build.sh --install            also put it on the Desktop as ~/Desktop/MacSense.app
#   ./build.sh --pkg                also make build/MacSense-<version>.pkg, which installs into
#                                   /Applications (upload it to Jamf for Self Service)
#   ARCHS=x86_64 ./build.sh         one architecture only: faster while iterating
# Needs only the Xcode Command Line Tools (swiftc, clang). No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="${ARCHS:-x86_64 arm64}"
INSTALL=0
PKG=0
for ARG in "$@"; do
  case "$ARG" in
    --install) INSTALL=1 ;;
    --pkg) PKG=1 ;;
    *) echo "unknown option: $ARG (use --install and/or --pkg)" >&2; exit 2 ;;
  esac
done
APP="build/MacSense.app"
BUNDLE_ID="com.brokengearindustries.macsense"
MIN_MACOS="12.0"
CACHE=".cache"   # compiler module cache; kept between builds so rebuilds are quick
FRAMEWORKS=(-framework AppKit -framework WebKit -framework IOKit -framework DiskArbitration -framework SystemConfiguration -framework PDFKit)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj "$CACHE"

BINARIES=()
for ARCH in $ARCHS; do
  echo "compiling $ARCH…"
  clang -O2 -Wall -Wextra -target "$ARCH-apple-macos$MIN_MACOS" -c Sources/smc.c -o "build/obj/smc-$ARCH.o"
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MIN_MACOS" \
    -module-cache-path "$CACHE/module-cache" \
    -import-objc-header Sources/Bridge.h \
    Sources/*.swift "build/obj/smc-$ARCH.o" "${FRAMEWORKS[@]}" \
    -o "build/obj/MacSense-$ARCH"
  BINARIES+=("build/obj/MacSense-$ARCH")
done
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/MacSense"

cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto UI "$APP/Contents/Resources/UI"

swiftc -O -swift-version 5 -module-cache-path "$CACHE/module-cache" tools/make_icon.swift -o build/obj/make_icon
build/obj/make_icon build/obj/AppIcon.iconset
iconutil -c icns build/obj/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/MacSense"))"

if [[ "$PKG" == 1 ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
  pkgbuild --component "$APP" --install-location /Applications --identifier "$BUNDLE_ID" \
    --version "$VERSION" "build/MacSense-$VERSION.pkg"
  echo "package: build/MacSense-$VERSION.pkg (unsigned; Jamf installs it as root, so no quarantine warning)"
fi

if [[ "$INSTALL" == 1 ]]; then
  DEST="$HOME/Desktop/MacSense.app"
  if [[ -e "$DEST" ]]; then
    # Only ever replace a copy of this app, never something else that happens to share the name.
    EXISTING=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$EXISTING" != "$BUNDLE_ID" ]]; then
      echo "not replacing $DEST: it isn't MacSense v2 (bundle id '${EXISTING:-none}')" >&2
      exit 1
    fi
    rm -rf "$DEST"
  fi
  ditto "$APP" "$DEST"
  echo "installed $DEST"
fi
