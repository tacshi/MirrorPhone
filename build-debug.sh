#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
# Release by default: the H.264 parse/decode path must outrun 120 Hz phone
# displays, and debug-mode Swift is several times slower there.
CONFIGURATION="${MIRRORPHONE_BUILD_CONFIGURATION:-release}"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="$ROOT/MirrorPhone.app"
SIGNING_IDENTITY="${MIRRORPHONE_SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGNING_IDENTITY="$(
    print -r -- "$AVAILABLE_IDENTITIES" \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

cd "$ROOT"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BUILD_DIR/MirrorPhone" "$APP_DIR/Contents/MacOS/MirrorPhone"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/MirrorPhone.icns" "$APP_DIR/Contents/Resources/MirrorPhone.icns"

ADB_PATH="$(command -v adb 2>/dev/null || true)"
if [[ -z "$ADB_PATH" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB_PATH="$HOME/Library/Android/sdk/platform-tools/adb"
fi
if [[ -n "$ADB_PATH" ]]; then
  cp -L "$ADB_PATH" "$APP_DIR/Contents/Helpers/adb"
  codesign \
    --force \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR/Contents/Helpers/adb"
else
  echo "warning: adb was not found; the packaged app will support iPhone/iPad only" >&2
fi

AUDIO_JAR="$("$ROOT/build-android-audio-server.sh" | tail -n1 || true)"
if [[ -n "$AUDIO_JAR" && -f "$AUDIO_JAR" ]]; then
  # The dex jar is device-side data pushed over adb, never executed on the Mac,
  # so it lives in Resources. codesign treats anything outside Contents/Resources
  # as nested code that would need its own signature.
  cp "$AUDIO_JAR" "$APP_DIR/Contents/Resources/mirrorphone-audio-server.jar"
else
  echo "warning: Android audio server was not built; Android mirroring will be video-only" >&2
fi

codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign "$SIGNING_IDENTITY" \
  --identifier com.rockyshi.mirrorphone \
  --entitlements "$ROOT/Resources/MirrorPhone.entitlements" \
  "$APP_DIR"

echo "$APP_DIR"
