import AppKit
import ImageIO
import Network

@MainActor
final class IOSWirelessMirrorSource: DeviceDetectingMirrorSource {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  var onDeviceDetected: ((String) -> Void)?

  private var wirelessReceiver: WirelessCompanionReceiver?
  private var wiredReceiver: USBMuxCompanionReceiver?
  private var wiredConnected = false

  func start() async throws {
    let wirelessReceiver = WirelessCompanionReceiver(
      configuration: .ios,
      onFrame: { [weak self] frame in
        Task { @MainActor [weak self] in
          guard let self, !wiredConnected else { return }
          onFrame?(frame)
        }
      },
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          guard let self, !wiredConnected else { return }
          onStatus?(status)
        }
      },
      onDeviceDetected: { [weak self] name in
        Task { @MainActor [weak self] in
          guard let self, !wiredConnected else { return }
          onDeviceDetected?(name)
        }
      }
    )
    let wiredReceiver = USBMuxCompanionReceiver(
      onFrame: { [weak self] frame in
        Task { @MainActor [weak self] in
          self?.onFrame?(frame)
        }
      },
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          self?.onStatus?(status)
        }
      },
      onDeviceDetected: { [weak self] name in
        Task { @MainActor [weak self] in
          self?.onDeviceDetected?(name)
        }
      },
      onConnectionChanged: { [weak self] connected in
        Task { @MainActor [weak self] in
          self?.wiredConnected = connected
        }
      }
    )
    self.wirelessReceiver = wirelessReceiver
    self.wiredReceiver = wiredReceiver
    try wirelessReceiver.start()
    wiredReceiver.start()
    onStatus?("Open MirrorPhone on your iPhone or iPad to begin mirroring.")
  }

  func stop() async {
    wirelessReceiver?.stop()
    wiredReceiver?.stop()
    wirelessReceiver = nil
    wiredReceiver = nil
    wiredConnected = false
  }
}

@MainActor
final class AndroidWirelessMirrorSource: DeviceDetectingMirrorSource {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  var onDeviceDetected: ((String) -> Void)?

  private var wirelessReceiver: WirelessCompanionReceiver?
  private var wiredReceiver: AndroidAccessoryMirrorReceiver?
  private var wiredConnected = false
  private var wirelessDeviceName: String?

  func start() async throws {
    let wirelessReceiver = WirelessCompanionReceiver(
      configuration: .android,
      onFrame: { [weak self] frame in
        Task { @MainActor [weak self] in
          guard let self, !wiredConnected else { return }
          onFrame?(frame)
        }
      },
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if status.localizedCaseInsensitiveContains("disconnected") {
            wirelessDeviceName = nil
          }
          guard !wiredConnected else { return }
          onStatus?(status)
        }
      },
      onDeviceDetected: { [weak self] name in
        Task { @MainActor [weak self] in
          guard let self else { return }
          wirelessDeviceName = name
          guard !wiredConnected else { return }
          onDeviceDetected?(name)
        }
      }
    )
    let wiredReceiver = AndroidAccessoryMirrorReceiver(
      onFrame: { [weak self] frame in
        Task { @MainActor [weak self] in
          self?.onFrame?(frame)
        }
      },
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          self?.onStatus?(status)
        }
      },
      onDeviceDetected: { [weak self] name in
        Task { @MainActor [weak self] in
          self?.onDeviceDetected?(name)
        }
      },
      onConnectionChanged: { [weak self] connected in
        Task { @MainActor [weak self] in
          guard let self else { return }
          wiredConnected = connected
          if !connected, let wirelessDeviceName {
            onDeviceDetected?(wirelessDeviceName)
            onStatus?("Connected to \(wirelessDeviceName) · wireless")
          }
        }
      }
    )
    self.wirelessReceiver = wirelessReceiver
    self.wiredReceiver = wiredReceiver
    try wirelessReceiver.start()
    wiredReceiver.start()
    onStatus?("Open MirrorPhone on Android to begin mirroring.")
  }

  func stop() async {
    wirelessReceiver?.stop()
    wiredReceiver?.stop()
    wirelessReceiver = nil
    wiredReceiver = nil
    wiredConnected = false
    wirelessDeviceName = nil
  }
}

@MainActor
final class AutomaticWirelessMirrorSource: CompanionSelectingMirrorSource {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  var onDeviceDetected: ((String) -> Void)?
  var onDevicesChanged: (([ConnectedCompanion], CompanionPlatform?) -> Void)?

  private let ios = IOSWirelessMirrorSource()
  private let android = AndroidWirelessMirrorSource()
  private var deviceNames = [CompanionPlatform: String]()
  private var selectedPlatform: CompanionPlatform?

  func start() async throws {
    configure(ios, platform: .ios)
    configure(android, platform: .android)

    try await ios.start()
    do {
      try await android.start()
    } catch {
      await ios.stop()
      throw error
    }
    onStatus?("Waiting for a MirrorPhone phone")
    reportDevices()
  }

  func stop() async {
    await ios.stop()
    await android.stop()
    deviceNames.removeAll()
    selectedPlatform = nil
    reportDevices()
  }

  func select(_ platform: CompanionPlatform) {
    guard let name = deviceNames[platform] else { return }
    selectedPlatform = platform
    onDeviceDetected?(name)
    onStatus?("Switching to \(name)")
    reportDevices()
  }

  private func configure(
    _ source: any DeviceDetectingMirrorSource,
    platform: CompanionPlatform
  ) {
    source.onFrame = { [weak self] frame in
      guard let self else { return }
      if selectedPlatform == nil {
        selectedPlatform = platform
        reportDevices()
      }
      guard selectedPlatform == platform else { return }
      onFrame?(frame)
    }
    source.onStatus = { [weak self] status in
      guard let self else { return }
      if status.hasPrefix("Open MirrorPhone") {
        if deviceNames.isEmpty {
          onStatus?("Waiting for a MirrorPhone phone")
        }
        return
      }
      if status.localizedCaseInsensitiveContains("disconnected") {
        deviceNames.removeValue(forKey: platform)
        if selectedPlatform == platform {
          selectedPlatform = availableDevices.first?.platform
          if let selectedPlatform, let name = deviceNames[selectedPlatform] {
            onDeviceDetected?(name)
          }
        }
        reportDevices()
      }
      if selectedPlatform == nil || selectedPlatform == platform {
        onStatus?(status)
      }
    }
    source.onDeviceDetected = { [weak self] name in
      guard let self else { return }
      deviceNames[platform] = name
      if selectedPlatform == nil {
        selectedPlatform = platform
      }
      if selectedPlatform == platform {
        onDeviceDetected?(name)
      }
      reportDevices()
    }
  }

  private var availableDevices: [ConnectedCompanion] {
    [CompanionPlatform.ios, .android].compactMap { platform in
      deviceNames[platform].map { ConnectedCompanion(platform: platform, name: $0) }
    }
  }

  private func reportDevices() {
    onDevicesChanged?(availableDevices, selectedPlatform)
  }
}

private struct WirelessCompanionConfiguration: Sendable {
  let serviceType: String
  let platformName: String
  let waitingStatus: String

  static let ios = WirelessCompanionConfiguration(
    serviceType: "_mirrorphone._tcp",
    platformName: "iOS",
    waitingStatus: "Open MirrorPhone on your iPhone or iPad to begin mirroring."
  )
  static let android = WirelessCompanionConfiguration(
    serviceType: "_mirrorphone-a._tcp",
    platformName: "Android",
    waitingStatus: "Open MirrorPhone on Android to begin mirroring."
  )
}

private final class WirelessCompanionReceiver: @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void
  typealias DeviceHandler = @Sendable (String) -> Void

  private let configuration: WirelessCompanionConfiguration
  private let queue: DispatchQueue
  private let onStatus: StatusHandler
  private let onDeviceDetected: DeviceHandler
  private let decoder: H264Decoder
  private var listener: NWListener?
  private var connection: NWConnection?
  private var parser = MirrorMessageParser()

  init(
    configuration: WirelessCompanionConfiguration,
    onFrame: @escaping FrameHandler,
    onStatus: @escaping StatusHandler,
    onDeviceDetected: @escaping DeviceHandler
  ) {
    self.configuration = configuration
    self.queue = DispatchQueue(
      label: "com.rockyshi.mirrorphone.\(configuration.platformName.lowercased())-wireless"
    )
    self.onStatus = onStatus
    self.onDeviceDetected = onDeviceDetected
    self.decoder = H264Decoder(onFrame: onFrame)
  }

  func start() throws {
    let listener = try NWListener(using: .tcp)
    listener.service = NWListener.Service(
      name: Host.current().localizedName ?? "MirrorPhone",
      type: configuration.serviceType
    )
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        onStatus(configuration.waitingStatus)
      case .failed(let error):
        onStatus("\(configuration.platformName) listener failed: \(error.localizedDescription)")
      case .cancelled:
        break
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      connection?.cancel()
      connection = nil
      listener?.cancel()
      listener = nil
      parser.reset()
      decoder.reset()
    }
  }

  private func accept(_ connection: NWConnection) {
    self.connection?.cancel()
    self.connection = connection
    parser.reset()
    decoder.reset()
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.connection === connection else { return }
      switch state {
      case .ready:
        onStatus("\(configuration.platformName) connected · waiting for video")
      case .failed(let error):
        onStatus("\(configuration.platformName) disconnected: \(error.localizedDescription)")
      case .cancelled:
        break
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(from: connection)
  }

  private func receive(from connection: NWConnection) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: MirrorWireProtocol.maximumPayloadSize + 5
    ) { [weak self, weak connection] data, _, complete, error in
      guard let self, let connection, self.connection === connection else { return }
      if let data, !data.isEmpty {
        do {
          for message in try parser.append(data) {
            try handle(message)
          }
        } catch {
          onStatus(error.localizedDescription)
          connection.cancel()
          return
        }
      }
      if complete || error != nil {
        onStatus("\(configuration.platformName) disconnected · waiting to reconnect")
        self.connection = nil
        decoder.reset()
        return
      }
      receive(from: connection)
    }
  }

  private func handle(_ message: MirrorMessage) throws {
    switch message.type {
    case .hello:
      let name = String(data: message.payload, encoding: .utf8) ?? configuration.platformName
      onDeviceDetected(name)
      onStatus("Connected to \(name) · waiting for video")
    case .videoFormat:
      try decoder.configure(with: message.payload)
    case .videoFrame:
      let (rawOrientation, h264) = try MirrorWireProtocol.parseVideoFramePayload(message.payload)
      guard let orientation = ReplayKitOrientation.displayOrientation(rawValue: rawOrientation)
      else {
        throw MirrorProtocolError.invalidVideoFrame
      }
      decoder.decode(h264, orientation: orientation)
    }
  }
}

enum ReplayKitOrientation {
  static func displayOrientation(rawValue: UInt8) -> CGImagePropertyOrientation? {
    guard (1...8).contains(rawValue) else { return nil }
    guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawValue)) else {
      return nil
    }

    // ReplayKit describes the device-relative sample orientation. Core Image applies an
    // image-relative transform, so the two 90-degree rotations are inverse operations.
    switch orientation {
    case .right:
      return .left
    case .left:
      return .right
    default:
      return orientation
    }
  }
}
