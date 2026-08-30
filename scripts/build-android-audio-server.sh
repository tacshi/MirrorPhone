#!/bin/zsh
# Compiles the device-side Android audio capturer into a dex jar that can be
# launched with `app_process`. On success the jar path is printed on stdout;
# if the Android SDK is missing it warns on stderr and exits 0 so packaging can
# continue with video-only Android mirroring.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
SRC="$ROOT/AndroidAudioServer/com/rockyshi/mirrorphone/AudioServer.java"
COMMON_SRC="$ROOT/AndroidServerCommon/com/rockyshi/mirrorphone/ShellContext.java"
OUT_DIR="$ROOT/.build/android-audio-server"
JAR="$OUT_DIR/mirrorphone-audio-server.jar"

ANDROID_JAR="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -n1)"
D8="$(ls "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -n1)"

if [[ -z "$ANDROID_JAR" || -z "$D8" || ! -x "$(command -v javac || true)" ]]; then
  echo "warning: Android SDK (android.jar/d8) or javac not found; skipping audio server build" >&2
  exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/classes"
javac --release 11 -cp "$ANDROID_JAR" -d "$OUT_DIR/classes" "$COMMON_SRC" "$SRC"
"$D8" --min-api 30 --output "$JAR" "$OUT_DIR/classes/com/rockyshi/mirrorphone"/*.class
echo "$JAR"
