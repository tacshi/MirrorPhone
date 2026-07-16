import CoreGraphics

/// The phase of a forwarded touch gesture.
enum TouchPhase: Sendable {
  case down
  case move
  case up
  case cancel
}

/// Receives touch and keyboard events mapped from Mac input. Touch coordinates
/// are in pixels of a `frameWidth`×`frameHeight` video frame. Implemented by
/// sources that can forward input to the real device (Android); iOS sources
/// return `nil` from `MirrorSource.touchSink` and all input is a no-op.
@MainActor
protocol TouchInputSink: AnyObject {
  func send(_ phase: TouchPhase, x: Int, y: Int, frameWidth: Int, frameHeight: Int)
  /// Forwards an Android key press (`keycode` from android.view.KeyEvent,
  /// `metaState` Android meta flags).
  func sendKey(down: Bool, keycode: Int, metaState: Int)
  /// Types text on the device as if from a hardware keyboard.
  func sendText(_ text: String)
}

@MainActor
protocol MirrorSource: AnyObject {
  var onFrame: ((CGImage) -> Void)? { get set }
  var onStatus: ((String) -> Void)? { get set }
  /// The input sink for this source, or `nil` when the source cannot forward
  /// touch input (e.g. iOS capture, which is one-way). Declared here (not only
  /// in the extension) so it dynamically dispatches to each source's override.
  var touchSink: TouchInputSink? { get }

  func start() async throws
  func stop() async
}

extension MirrorSource {
  var touchSink: TouchInputSink? { nil }
}

@MainActor
protocol DeviceDetectingMirrorSource: MirrorSource {
  var onDeviceDetected: ((String) -> Void)? { get set }
}

enum CompanionPlatform: String, Hashable, Sendable {
  case ios
  case android
}

struct ConnectedCompanion: Hashable, Sendable {
  let platform: CompanionPlatform
  let name: String
}

@MainActor
protocol CompanionSelectingMirrorSource: DeviceDetectingMirrorSource {
  var onDevicesChanged: (([ConnectedCompanion], CompanionPlatform?) -> Void)? { get set }
  func select(_ platform: CompanionPlatform)
}
