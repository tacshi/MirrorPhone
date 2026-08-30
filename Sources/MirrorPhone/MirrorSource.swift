import CoreGraphics

/// The phase of a forwarded touch gesture.
enum TouchPhase: Equatable, Sendable {
  case down
  case move
  case up
  case cancel
}

/// A location independent of device resolution. `(0, 0)` is the display's
/// top-left and `(1, 1)` is its bottom-right.
struct NormalizedPoint: Equatable, Sendable {
  let x: Double
  let y: Double

  init?(point: CGPoint, in referenceSize: CGSize) {
    guard referenceSize.width > 0, referenceSize.height > 0 else { return nil }
    let maximumX = max(referenceSize.width - 1, 0)
    let maximumY = max(referenceSize.height - 1, 0)
    x = maximumX > 0 ? Double(min(max(point.x, 0), maximumX) / maximumX) : 0
    y = maximumY > 0 ? Double(min(max(point.y, 0), maximumY) / maximumY) : 0
  }

  func point(in referenceSize: CGSize) -> CGPoint {
    CGPoint(
      x: CGFloat(x) * max(referenceSize.width - 1, 0),
      y: CGFloat(y) * max(referenceSize.height - 1, 0)
    )
  }
}

/// A touch relative to the video surface that produced it. Backends can use
/// the normalized location directly or recover coordinates in that surface.
struct DeviceTouchEvent: Equatable, Sendable {
  let phase: TouchPhase
  let location: NormalizedPoint
  let referenceSize: CGSize

  init?(phase: TouchPhase, point: CGPoint, referenceSize: CGSize) {
    guard let location = NormalizedPoint(point: point, in: referenceSize) else {
      return nil
    }
    self.phase = phase
    self.location = location
    self.referenceSize = referenceSize
  }
}

enum DeviceKeyPhase: Equatable, Sendable {
  case down
  case up
}

/// Semantic keys shared by every device backend. Printable input without a
/// shortcut modifier is represented by `DeviceInputEvent.text` instead.
enum DeviceKey: Equatable, Hashable, Sendable {
  case enter
  case keypadEnter
  case backspace
  case forwardDelete
  case tab
  case escape
  case leftArrow
  case rightArrow
  case downArrow
  case upArrow
  case home
  case end
  case pageUp
  case pageDown
  case character(Character)
}

struct DeviceInputModifiers: OptionSet, Equatable, Hashable, Sendable {
  let rawValue: UInt8

  static let shift = DeviceInputModifiers(rawValue: 1 << 0)
  static let option = DeviceInputModifiers(rawValue: 1 << 1)
  static let control = DeviceInputModifiers(rawValue: 1 << 2)
  static let command = DeviceInputModifiers(rawValue: 1 << 3)
}

struct DeviceKeyEvent: Equatable, Sendable {
  let phase: DeviceKeyPhase
  let key: DeviceKey
  let modifiers: DeviceInputModifiers
}

enum DeviceInputEvent: Equatable, Sendable {
  case touch(DeviceTouchEvent)
  case key(DeviceKeyEvent)
  case text(String)
}

/// Receives platform-neutral input translated from Mac mouse and keyboard
/// events. Each source adapts these semantics to its platform's input API.
@MainActor
protocol DeviceInputSink: AnyObject {
  func send(_ event: DeviceInputEvent)
}

@MainActor
protocol MirrorSource: AnyObject {
  var onFrame: ((CGImage) -> Void)? { get set }
  var onStatus: ((String) -> Void)? { get set }
  /// The input sink for this source, or `nil` when the source cannot forward
  /// input (e.g. the current iOS capture source, which is one-way). Declared
  /// here so it dynamically dispatches to each source's implementation.
  var inputSink: DeviceInputSink? { get }

  func start() async throws
  func stop() async
}

extension MirrorSource {
  var inputSink: DeviceInputSink? { nil }
}

@MainActor
protocol RecordableMirrorSource: MirrorSource {
  var recordingTap: MirrorRecordingTap { get }
}

@MainActor
protocol QualityAdjustableMirrorSource: MirrorSource {
  var qualityState: MirrorQualityState { get }
  var onQualityStateChanged: ((MirrorQualityState) -> Void)? { get set }

  /// Updates the desired profile without replacing the source. Implementations
  /// may restart only their internal video transport while preserving audio,
  /// input forwarding, and any attached recording tap.
  func setQualityMode(_ mode: MirrorQualityMode)
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
