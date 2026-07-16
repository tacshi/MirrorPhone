# MirrorPhone

A native Swift + AppKit viewer for USB-connected iOS and Android devices. It is intentionally view-only: device interaction is disabled, and no companion app is installed on the phone.

## USB backends

- **iPhone/iPad:** enables macOS's CoreMediaIO screen-capture devices and receives the trusted device's muxed display stream through AVFoundation, using the same system path exposed to QuickTime capture. The muxed stream carries the device's audio, which MirrorPhone plays through the Mac's default output.
- **Android:** uses ADB over USB debugging to receive the device's built-in `screenrecord` H.264 stream. MirrorPhone decodes it directly with VideoToolbox and automatically refreshes the stream when Android's three-minute recording window ends. Because `screenrecord` is video-only, device audio is captured separately (scrcpy-style): a tiny `app_process` helper is run over ADB to stream the output mix (`REMOTE_SUBMIX`) as PCM, which the Mac plays. Audio requires **Android 11 or newer** and is best-effort — mirroring continues without it.

The app discovers connected devices continuously, selects the first one automatically, and switches immediately when another device is selected. No iOS app, Android APK, ADB command-line interaction, network connection, or cloud service is required at runtime. The packaged Mac app includes the local ADB binary found when it is built.

## Build and run

```sh
./build-debug.sh
open MirrorPhone.app
```

The build automatically uses the first Developer ID Application identity in Keychain so macOS privacy permissions remain associated with the app across rebuilds. Set `MIRRORPHONE_SIGNING_IDENTITY` to override it. It falls back to an ad-hoc signature only when no Developer ID identity is available.

Create a signed and notarized release disk image with:

```sh
./build-dmg.sh 1.0.0
```

The version argument is applied to the packaged app and installer metadata and used in the disk-image filename. The release script selects the Developer ID Application certificate for team `X5X4TD477G`, submits with the stored `MirrorPhone` notarytool profile, and writes the stapled disk image under `dist/`. Set `MIRRORPHONE_SIGNING_IDENTITY`, `MIRRORPHONE_TEAM_ID`, or `MIRRORPHONE_NOTARY_PROFILE` to override those defaults.

Install Android SDK Platform Tools on the build Mac so `build-debug.sh` can bundle `adb`. During Swift development, MirrorPhone also finds `adb` through `ANDROID_SDK_ROOT`, `ANDROID_HOME`, the standard Android SDK folder, Homebrew, or `PATH`.

Android audio additionally needs a full Android SDK (`android.jar` plus `d8`) and `javac` at build time: `build-debug.sh` compiles the device-side capturer (`AndroidAudioServer/`) into a dex jar and bundles it under `Contents/Resources`. If the SDK is missing the build still succeeds, and Android mirroring is video-only. Set `MIRRORPHONE_ANDROID_AUDIO_JAR` to point the app at a prebuilt jar during Swift development.

## Connect a device

### iPhone or iPad

1. Connect the unlocked device with a data-capable USB cable.
2. Tap **Trust** on the device if prompted.
3. If macOS asks for video access, allow MirrorPhone. The app first opens the muxed USB screen device directly and only shows permission recovery when AVFoundation rejects that input.
4. If macOS asks for microphone access, allow it to hear the device. Audio rides on the same muxed capture device; denying it only mutes playback and leaves video mirroring intact.

### Android

1. Enable Developer options and USB debugging.
2. Connect the unlocked device with a data-capable USB cable and choose a USB mode that exposes debugging, such as File Transfer.
3. Accept the device's **Allow USB debugging** prompt.

Android audio (11+) plays through the Mac automatically. It relies on the `REMOTE_SUBMIX` output mix, whose routing is device- and OEM-dependent: the phone may fall silent while its audio is redirected to the Mac, and audio that was already playing when mirroring started can take a moment to route in (restart playback on the phone if a stream stays silent). Some vendors restrict output-audio capture entirely, in which case mirroring stays video-only.

The window follows the received frame orientation and remains fitted to the mobile display width. Use the toolbar or View menu for actual size and the camera button or File menu to save the current frame as PNG.
