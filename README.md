<p align="center">
  <img src="Resources/MirrorPhone.png" width="160" height="160" alt="MirrorPhone app icon">
</p>

<h1 align="center">MirrorPhone</h1>

<p align="center">Mirror iPhone, iPad, and Android screens over USB on macOS.</p>

MirrorPhone is a native Swift and AppKit application for viewing mobile devices from a Mac. It uses the system USB capture path for iPhone and iPad, and ADB for Android. Android devices can also be controlled with the Mac's mouse, trackpad, and keyboard.

All device communication stays local. MirrorPhone does not use a network service or cloud relay.

## Platform support

| | Video | Audio | Input |
| --- | --- | --- | --- |
| iPhone and iPad | USB capture through CoreMediaIO and AVFoundation | Included in the muxed capture stream | View-only |
| Android | ADB `screenrecord`, decoded with VideoToolbox | Android 11 or later; device-dependent | Mouse, trackpad, and keyboard on Android 11 or later |

iOS and iPadOS do not expose a public system-wide input-injection API comparable to Android's ADB interface. MirrorPhone therefore does not forward input to Apple mobile devices.

## Features

- Automatic discovery of connected iPhone, iPad, and Android devices
- Multiple independent device windows with one exclusive window per physical device
- Independent Auto, Quality, Balanced, and Performance capture profiles per window
- Low-latency native video decoding and orientation changes
- iPhone and iPad audio through the USB capture stream
- Android taps, drags, scrolling, text entry, navigation keys, and keyboard shortcuts
- Automatic recovery when Android's `screenrecord` session reaches its time limit
- MP4 screen recording at up to 60 fps with H.264 video and AAC device audio
- Actual-size display mode and PNG frame capture
- No iOS companion app or Android APK installation

For Android audio and input, the build packages small dex helpers that are copied to `/data/local/tmp` and launched as the ADB shell user with `app_process`. They are not installed as applications.

## Requirements

- macOS 14 or later
- Xcode with a Swift 6.2 toolchain
- A data-capable USB cable
- Android SDK Platform Tools (`adb`) for Android support
- Android SDK platform files, Build Tools (`d8`), and a JDK for Android audio and input support

The video-only iPhone and iPad build does not require the Android SDK.

## Build

Clone the repository, then run:

```sh
./scripts/build-debug.sh
open MirrorPhone.app
```

Despite its name, `scripts/build-debug.sh` builds an optimized executable by default because the H.264 decode path must keep pace with high-refresh-rate displays. Set `MIRRORPHONE_BUILD_CONFIGURATION=debug` when a debug build is required.

The script packages the app, bundles `adb` from `PATH` or the standard Android SDK location, and builds the Android helpers when the required SDK tools are available. Missing Android helper dependencies do not stop the build; the affected audio or input feature is disabled instead.

Useful build overrides:

| Variable | Purpose |
| --- | --- |
| `MIRRORPHONE_SIGNING_IDENTITY` | Code-signing identity; falls back to `DEVELOPER_ID_APPLICATION`, then to the first Developer ID Application certificate in Keychain, then to ad hoc signing |
| `DEVELOPER_ID_APPLICATION` | Developer ID Application identity, honoured when `MIRRORPHONE_SIGNING_IDENTITY` is unset |
| `MIRRORPHONE_BUILD_CONFIGURATION` | Swift build configuration, `release` or `debug` |
| `MIRRORPHONE_ANDROID_AUDIO_JAR` | Runtime path to a prebuilt Android audio helper |
| `MIRRORPHONE_ANDROID_INPUT_JAR` | Runtime path to a prebuilt Android input helper |

Run the test suite with:

```sh
swift test
```

## Connect a device

MirrorPhone opens one window at launch. Choose **File > New Window** or press <kbd>Command</kbd> + <kbd>N</kbd> to mirror another connected device. A new window claims the first connected device that is not already in use; if none is available, it waits until one connects. Attaching a device never creates an extra window by itself.

Each physical device belongs to one window at a time. Devices claimed by other windows remain listed as **In Another Window** but cannot be selected. If a device disconnects, its window keeps the reservation and reconnects automatically when that same device returns. Closing the window releases the claim. Capture, input, resizing, and MP4 recording remain independent, so different windows can record simultaneously.

### iPhone or iPad

1. Connect the unlocked device by USB.
2. Tap **Trust** on the device if prompted.
3. Allow video access when macOS requests it.
4. Allow microphone access to hear and record device audio. Denying it leaves video capture and video-only recording available.

The device remains view-only in MirrorPhone.

### Android

1. Enable Developer options and USB debugging.
2. Connect the unlocked device by USB and select a USB mode that permits debugging, such as File Transfer.
3. Accept the **Allow USB debugging** prompt on the device.

Click or drag in the mirrored display to send touch input. Mouse-wheel and trackpad scrolling are translated into swipe gestures. When the MirrorPhone window is active, text, navigation keys, and common Command-key shortcuts are forwarded to Android.

Android audio and input require Android 11 or later. Audio capture depends on Android version and vendor policy; unsupported devices continue mirroring without sound. The phone may be muted while its output is routed to the Mac.

## Choose capture quality

Use the quality selector in a window's titlebar or choose **View > Quality Profile**. Each window has its own selection; changing one device does not affect another already-open window. The most recently selected mode becomes the default for new windows and future launches.

| Profile | iPhone and iPad | Android |
| --- | --- | --- |
| Auto | Starts Balanced, reduces quality after sustained decode or display pressure, and restores it after a longer healthy period | Same adaptive policy |
| Quality | AVFoundation High preset | Native resolution at 12 Mbps |
| Balanced | 1080p or Medium preset | Up to 1080 short edge / 1920 long edge at 8 Mbps |
| Performance | 720p or Low preset | Up to 720 short edge / 1280 long edge at 4 Mbps |

Auto evaluates one-second windows independently for each device. It steps down after three overloaded windows, waits at least 15 seconds between changes, and steps up only after 20 healthy windows. Profiles change resolution and Android transport bitrate without adding a frame-rate cap, so the source continues at its native cadence.

External iPhone and iPad capture devices do not always support every AVFoundation preset. MirrorPhone uses the nearest supported profile and shows the effective level in the titlebar. If an Android encoder rejects a level, MirrorPhone falls through to the next lower one for that connection. The Smart X3 Pro framebuffer fallback remains fixed at native quality because resizing after capture would not reduce its USB or capture cost.

## Record the device screen

Choose **File > Start Recording…**, press <kbd>Command</kbd> + <kbd>R</kbd>, or use the record button beside the image-capture action. Pick the MP4 destination before recording starts, then use the same action to stop.

Recordings contain only the device surface—not the MirrorPhone window, pointer, or recording indicator. Live mirroring stays at the device's native cadence, while recording preserves the source timestamps and cadence up to 60 fps; higher-refresh sources are sampled without slowing the mirror. The frame visible at start defines one fixed, even-sized canvas. If the device rotates, the correctly oriented image is aspect-fit over black bars rather than changing the MP4 dimensions. Android's periodic `screenrecord` refresh continues in the same file.

Quality changes also remain in the same file. MirrorPhone keeps the original recording canvas and encoder settings, aspect-fitting later source resolutions as needed; Android audio and input continue while its video subprocess changes profile.

Device audio is recorded when the source exposes it. Microphone denial on iPhone/iPad, Android versions before 11, vendor restrictions, or an interrupted audio stream never stop the video; the on-screen muted badge identifies a video-only recording. Switching devices, disconnecting, closing the window, or quitting safely finalizes the current file before continuing.

## Application shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>Command</kbd> + <kbd>N</kbd> | Open a new device window |
| <kbd>Command</kbd> + <kbd>0</kbd> | Show the current frame at actual size |
| <kbd>Command</kbd> + <kbd>R</kbd> | Start or stop an MP4 recording |
| <kbd>Command</kbd> + <kbd>S</kbd> | Save the current frame as a PNG |

## Release build

`scripts/build-dmg.sh` creates a signed, notarized disk image:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
MIRRORPHONE_NOTARY_PROFILE="YOUR_NOTARYTOOL_PROFILE" \
./scripts/build-dmg.sh 1.0.0
```

The signing identity is resolved from `MIRRORPHONE_SIGNING_IDENTITY`, then `DEVELOPER_ID_APPLICATION`. Exporting `DEVELOPER_ID_APPLICATION` from your shell profile leaves only the `notarytool` profile to pass per release. Set `MIRRORPHONE_TEAM_ID` instead to look the identity up in Keychain by team. The finished disk image is written to `dist/`.

To build the disk image and upload it with a SHA-256 checksum to a draft GitHub Release, run:

```sh
./scripts/release.sh 1.0.0
```

The release script requires a clean branch that exactly matches its remote upstream and an authenticated GitHub CLI. Select the Developer ID identity with `DEVELOPER_ID_APPLICATION` (or `MIRRORPHONE_TEAM_ID`) and the `notarytool` Keychain profile with `MIRRORPHONE_NOTARY_PROFILE`; the script does not accept or store signing credentials. Review the draft release before publishing it.

## Contributing

Bug reports and pull requests are welcome. Please include the macOS version, device model, mobile OS version, and relevant build or runtime output when reporting device-specific problems.
