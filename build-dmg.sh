#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
if (( $# != 1 )); then
  print -u2 -- "usage: ${0:t} <version>"
  exit 64
fi

VERSION="$1"
VERSION_PATTERN='^[0-9]+([.][0-9]+){0,2}$'
if [[ ! "$VERSION" =~ $VERSION_PATTERN ]]; then
  print -u2 -- "error: version must contain one to three numeric components, such as 1.2.3"
  exit 64
fi

APP_NAME="MirrorPhone"
APP_BUNDLE="$ROOT/$APP_NAME.app"
INFO_PLIST="$ROOT/Resources/Info.plist"
ICON_FILE="$ROOT/Resources/MirrorPhone.icns"
DMG_BACKGROUND="$ROOT/Resources/DMGBackground.png"
TEAM_ID="${MIRRORPHONE_TEAM_ID:-X5X4TD477G}"
NOTARY_PROFILE="${MIRRORPHONE_NOTARY_PROFILE:-MirrorPhone}"
SIGNING_IDENTITY="${MIRRORPHONE_SIGNING_IDENTITY:-}"
SKIP_NOTARIZATION="${MIRRORPHONE_SKIP_NOTARIZATION:-0}"
VOLUME_NAME="$APP_NAME Installer"
DIST_DIR="$ROOT/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mirrorphone-release.XXXXXX")"
INSTALLER_APP="$WORK_DIR/$APP_NAME.app"
MOUNT_DIR="$WORK_DIR/mount"
RW_DMG="$WORK_DIR/$APP_NAME-rw.dmg"
MOUNTED=0

cleanup() {
  if (( MOUNTED )); then
    diskutil eject force "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -- "error: $*"
  exit 1
}

for tool in codesign diskutil osascript pgrep plutil security xattr xcrun; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

[[ -f "$INFO_PLIST" ]] || fail "missing $INFO_PLIST"
[[ -f "$ICON_FILE" ]] || fail "missing $ICON_FILE"
[[ -f "$DMG_BACKGROUND" ]] || fail "missing $DMG_BACKGROUND"

if pgrep -f -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  fail "quit $APP_NAME before creating a release so its bundle can be signed safely"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
    | sed -n "s/.*\"\(Developer ID Application:.*($TEAM_ID)\)\".*/\1/p" \
    | head -n 1)"
fi

[[ -n "$SIGNING_IDENTITY" ]] || fail \
  "no Developer ID Application identity for team $TEAM_ID was found in Keychain"
[[ "$SIGNING_IDENTITY" != "-" ]] || fail \
  "release bundles require a Developer ID Application identity, not an ad-hoc signature"

FINAL_DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

print -- "Building $APP_NAME $VERSION..."
MIRRORPHONE_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  MIRRORPHONE_BUILD_CONFIGURATION=release \
  "$ROOT/build-debug.sh" >/dev/null
[[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE was not produced"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Release signing uses Apple's trusted timestamp service. build-debug.sh avoids
# network-dependent timestamps for local builds, so its signatures are replaced here.
xattr -cr "$APP_BUNDLE"
if [[ -f "$APP_BUNDLE/Contents/Helpers/adb" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE/Contents/Helpers/adb"
fi
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  --identifier com.rockyshi.mirrorphone \
  --entitlements "$ROOT/Resources/MirrorPhone.entitlements" \
  "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

print -- "Creating the one-click installer..."
mkdir -p \
  "$INSTALLER_APP/Contents/MacOS" \
  "$INSTALLER_APP/Contents/Resources/Payload"
ditto "$APP_BUNDLE" "$INSTALLER_APP/Contents/Resources/Payload/$APP_NAME.app"
cp "$ICON_FILE" "$INSTALLER_APP/Contents/Resources/MirrorPhone.icns"

cat > "$INSTALLER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>MirrorPhone</string>
    <key>CFBundleExecutable</key>
    <string>MirrorPhone Installer</string>
    <key>CFBundleIconFile</key>
    <string>MirrorPhone</string>
    <key>CFBundleIdentifier</key>
    <string>com.rockyshi.mirrorphone.installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MirrorPhone Installer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST
plutil -replace CFBundleShortVersionString -string "$VERSION" "$INSTALLER_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$INSTALLER_APP/Contents/Info.plist"

cat > "$INSTALLER_APP/Contents/MacOS/MirrorPhone Installer" <<'INSTALLER'
#!/bin/zsh
set -euo pipefail

INSTALLER_CONTENTS="${0:A:h:h}"
INSTALLER_BUNDLE="${INSTALLER_CONTENTS:h}"
PAYLOAD="$INSTALLER_CONTENTS/Resources/Payload/MirrorPhone.app"
TARGET="/Applications/MirrorPhone.app"
VOLUME_PATH="${INSTALLER_BUNDLE:h}"

[[ -d "$PAYLOAD" ]] || exit 1

/usr/bin/osascript - "$PAYLOAD" "$TARGET" <<'APPLESCRIPT'
on run arguments
    set sourcePath to item 1 of arguments
    set targetPath to item 2 of arguments
    set installCommand to "/bin/rm -rf " & quoted form of targetPath & " && " & ¬
        "/usr/bin/ditto --rsrc --extattr " & quoted form of sourcePath & " " & quoted form of targetPath
    do shell script installCommand with administrator privileges
end run
APPLESCRIPT

# The installer itself is running from the disk image. Let it exit before a
# detached helper retries the unmount, so Finder never reports the volume busy.
cd /
/usr/bin/nohup /bin/zsh -c '
  volume="$1"
  /bin/sleep 1
  for attempt in {1..10}; do
    /usr/sbin/diskutil eject "$volume" >/dev/null 2>&1 && exit 0
    /bin/sleep 1
  done
  /usr/sbin/diskutil eject force "$volume" >/dev/null 2>&1
' _ "$VOLUME_PATH" </dev/null >/dev/null 2>&1 &!
INSTALLER
chmod 755 "$INSTALLER_APP/Contents/MacOS/MirrorPhone Installer"

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$INSTALLER_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALLER_APP"

APP_SIZE_KB="$(du -sk "$INSTALLER_APP" | awk '{print $1}')"
DMG_SIZE_MB=$(( APP_SIZE_KB / 1024 + 64 ))
mkdir -p "$MOUNT_DIR" "$DIST_DIR"
rm -f "$FINAL_DMG"

diskutil image create blank \
  --size "${DMG_SIZE_MB}m" \
  --fs APFS \
  --volumeName "$VOLUME_NAME" \
  "$RW_DMG" >/dev/null
diskutil image attach \
  --mountPoint "$MOUNT_DIR" \
  "$RW_DMG" >/dev/null
MOUNTED=1

ditto "$INSTALLER_APP" "$MOUNT_DIR/$APP_NAME.app"
mkdir -p "$MOUNT_DIR/.background"
cp "$DMG_BACKGROUND" "$MOUNT_DIR/.background/background.png"
touch "$MOUNT_DIR/.metadata_never_index"

/usr/bin/osascript - "$MOUNT_DIR" <<'APPLESCRIPT'
on run arguments
    set mountPath to item 1 of arguments
    set mountedFolder to (POSIX file mountPath) as alias
    set backgroundFile to (POSIX file (mountPath & "/.background/background.png")) as alias
    tell application "Finder"
        open mountedFolder
        set mountedWindow to container window of mountedFolder
        set current view of mountedWindow to icon view
        set toolbar visible of mountedWindow to false
        set statusbar visible of mountedWindow to false
        set pathbar visible of mountedWindow to false
        set bounds of mountedWindow to {100, 100, 820, 580}
        set theViewOptions to icon view options of mountedWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 144
        set text size of theViewOptions to 14
        set background picture of theViewOptions to backgroundFile
        set position of item "MirrorPhone.app" of mountedFolder to {360, 190}
        update mountedFolder without registering applications
        delay 2
        close mountedWindow
    end tell
end run
APPLESCRIPT

sync
diskutil eject "$MOUNT_DIR" >/dev/null
MOUNTED=0

diskutil image create from \
  --format UDZO \
  "$RW_DMG" \
  "$FINAL_DMG" >/dev/null

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$FINAL_DMG"
codesign --verify --verbose=2 "$FINAL_DMG"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
  print -- "Skipping notarization because MIRRORPHONE_SKIP_NOTARIZATION=1."
else
  print -- "Submitting to Apple notary service with profile $NOTARY_PROFILE..."
  xcrun notarytool submit \
    "$FINAL_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$FINAL_DMG"
  xcrun stapler validate "$FINAL_DMG"
fi

print -- "$FINAL_DMG"
