import CoreGraphics

@MainActor
protocol MirrorSource: AnyObject {
  var onFrame: ((CGImage) -> Void)? { get set }
  var onStatus: ((String) -> Void)? { get set }

  func start() async throws
  func stop() async
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
