import AppKit
import Foundation
import ImageIO
import MirrorPhoneUSB

final class AndroidAccessoryMirrorReceiver: @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void
  typealias DeviceHandler = @Sendable (String) -> Void
  typealias ConnectionHandler = @Sendable (Bool) -> Void

  private let onStatus: StatusHandler
  private let onDeviceDetected: DeviceHandler
  private let onConnectionChanged: ConnectionHandler
  private let decoder: H264Decoder
  private var parser = MirrorMessageParser()
  private var host: MMAndroidAccessoryHostRef?

  init(
    onFrame: @escaping FrameHandler,
    onStatus: @escaping StatusHandler,
    onDeviceDetected: @escaping DeviceHandler,
    onConnectionChanged: @escaping ConnectionHandler
  ) {
    self.onStatus = onStatus
    self.onDeviceDetected = onDeviceDetected
    self.onConnectionChanged = onConnectionChanged
    decoder = H264Decoder(onFrame: onFrame)
  }

  func start() {
    guard host == nil else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    let host = mm_android_accessory_host_create(
      context,
      androidAccessoryDataCallback,
      androidAccessoryStatusCallback
    )
    self.host = host
    mm_android_accessory_host_start(host)
  }

  func stop() {
    guard let host else { return }
    mm_android_accessory_host_stop(host)
    mm_android_accessory_host_destroy(host)
    self.host = nil
    parser.reset()
    decoder.reset()
  }

  fileprivate func receive(_ bytes: UnsafePointer<UInt8>, count: Int) {
    do {
      for message in try parser.append(Data(bytes: bytes, count: count)) {
        try handle(message)
      }
    } catch {
      onStatus(error.localizedDescription)
    }
  }

  fileprivate func updateStatus(_ status: String, connected: Bool) {
    if connected {
      parser.reset()
      decoder.reset()
    } else {
      parser.reset()
      decoder.reset()
    }
    onConnectionChanged(connected)
    onStatus(status)
  }

  private func handle(_ message: MirrorMessage) throws {
    switch message.type {
    case .hello:
      let name = String(data: message.payload, encoding: .utf8) ?? "Android"
      onDeviceDetected(name)
      onStatus("Live from \(name) · cable")
    case .videoFormat:
      try decoder.configure(with: message.payload)
    case .videoFrame:
      let (rawOrientation, h264) = try MirrorWireProtocol.parseVideoFramePayload(message.payload)
      guard let orientation = ReplayKitOrientation.displayOrientation(rawValue: rawOrientation)
      else { throw MirrorProtocolError.invalidVideoFrame }
      decoder.decode(h264, orientation: orientation)
    }
  }
}

private let androidAccessoryDataCallback:
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void =
    { context, bytes, count in
      guard let context, let bytes, count > 0 else { return }
      let receiver = Unmanaged<AndroidAccessoryMirrorReceiver>
        .fromOpaque(context).takeUnretainedValue()
      receiver.receive(bytes, count: count)
    }

private let androidAccessoryStatusCallback:
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Bool) -> Void =
    { context, status, connected in
      guard let context, let status else { return }
      let receiver = Unmanaged<AndroidAccessoryMirrorReceiver>
        .fromOpaque(context).takeUnretainedValue()
      receiver.updateStatus(String(cString: status), connected: connected)
    }
