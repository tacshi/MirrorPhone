import AppKit
import Foundation

enum DeviceClipboardContent: Equatable, Sendable {
  case text(String)
  case empty
  case unsupported
}

enum DeviceClipboardAvailability: Equatable, Sendable {
  case unavailable
  case manual
  case synchronized
}

struct DeviceClipboardState: Equatable, Sendable {
  let availability: DeviceClipboardAvailability
  let limitation: String?

  var isAvailable: Bool {
    availability != .unavailable
  }

  static func unavailable(_ limitation: String? = nil) -> DeviceClipboardState {
    DeviceClipboardState(availability: .unavailable, limitation: limitation)
  }

  static func manual(_ limitation: String? = nil) -> DeviceClipboardState {
    DeviceClipboardState(availability: .manual, limitation: limitation)
  }

  static let synchronized = DeviceClipboardState(
    availability: .synchronized,
    limitation: nil
  )
}

enum DeviceClipboardSelectionOperation: String, Equatable, Sendable {
  case copy
  case cut
}

enum DeviceClipboardError: LocalizedError, Equatable, Sendable {
  case unavailable(String?)
  case tooLarge(maximumBytes: Int)
  case timedOut
  case disconnected
  case rejected(String)
  case pasteboardWriteFailed

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason):
      reason ?? "Android clipboard access is unavailable."
    case .tooLarge(let maximumBytes):
      "Clipboard text is larger than the supported \(maximumBytes / 1_024) KiB limit."
    case .timedOut:
      "The Android device did not respond to the clipboard request."
    case .disconnected:
      "The Android clipboard connection was interrupted."
    case .rejected(let reason):
      reason
    case .pasteboardWriteFailed:
      "macOS could not update the clipboard."
    }
  }
}

enum MirrorClipboardActivationPolicy {
  static func acceptsAutomaticUpdate(
    isApplicationActive: Bool,
    isWindowKey: Bool,
    isSourceCurrent: Bool,
    isDeviceConnected: Bool,
    isTransitioning: Bool,
    isClosing: Bool
  ) -> Bool {
    isApplicationActive && isWindowKey && isSourceCurrent && isDeviceConnected
      && !isTransitioning && !isClosing
  }
}

@MainActor
protocol DeviceClipboardBridge: AnyObject {
  var clipboardState: DeviceClipboardState { get }
  var onClipboardStateChanged: ((DeviceClipboardState) -> Void)? { get set }
  var onClipboardContentChanged: ((DeviceClipboardContent) -> Void)? { get set }

  func readSelection(
    _ operation: DeviceClipboardSelectionOperation
  ) async throws -> DeviceClipboardContent
  func paste(_ text: String) async throws
}

@MainActor
protocol MirrorPasteboard: AnyObject {
  var plainText: String? { get }

  @discardableResult
  func replacePlainText(with text: String?) -> Bool
}

@MainActor
final class GeneralMirrorPasteboard: MirrorPasteboard {
  static let shared = GeneralMirrorPasteboard()

  private init() {}

  var plainText: String? {
    NSPasteboard.general.string(forType: .string)
  }

  @discardableResult
  func replacePlainText(with text: String?) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard let text else { return true }
    return pasteboard.setString(text, forType: .string)
  }
}
