#!/bin/bash
# Builds LCX Mixer, signs it, installs it to Applications and launches it.
# Usage: ./scripts/build.sh            (release build + install + launch)
#        ./scripts/build.sh --no-run   (build and install only)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="LCX Mixer"
EXE="LCXMixer"

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "==> Building"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling app bundle"
APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Extension" "$APP/Contents/Resources/ChromeExtension"
BUILD_ID="$(date +%Y%m%d%H%M%S)"
EXT="$APP/Contents/Resources/ChromeExtension"
# Every script carries the build ID (the site files under sites/ too), so copies left in a tab
# by an older build never answer this one.
find "$EXT" -name '*.js' -exec sed -i '' "s/__BUILD_ID__/$BUILD_ID/g" {} +
printf '{"build":"%s"}\n' "$BUILD_ID" > "$EXT/build.json"
echo "    extension build $BUILD_ID"
if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
  iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGNED=0
if [ -n "$IDENTITY" ]; then
  echo "    using: $IDENTITY"
  codesign --force --sign "$IDENTITY" --identifier org.lcxmixer.app "$APP" && SIGNED=1
else
  echo "    WARNING: the Apple Development certificate is missing or not trusted."
  security find-identity -p codesigning 2>&1 | grep "Apple Development" | sed 's/^/    found (not valid): /'
  echo "    Usually the Apple WWDR G3 intermediate certificate is missing:"
  echo "    https://www.apple.com/certificateauthority/AWWDRCAG3.cer  (download, double-click to install)"
fi
if [ "$SIGNED" != "1" ]; then
  echo "    Signing ad hoc. macOS will ask for the audio permission again after every rebuild."
  codesign --force --sign - --identifier org.lcxmixer.app "$APP"
fi

echo "==> Installing"
pkill -x "$EXE" 2>/dev/null || true
sleep 0.5
DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"
echo "    installed to $DEST/$APP_NAME.app"

if [ "${1:-}" != "--no-run" ]; then
  echo "==> Launching"
  open "$DEST/$APP_NAME.app"
fi
echo "==> Done"
