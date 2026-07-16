import AppKit
import Darwin
import Foundation
import ImageIO

/// Receives the iOS companion stream over the USB tunnel already provided by macOS.
/// This speaks the usbmuxd plist protocol directly; no external executable or library is used.
final class USBMuxCompanionReceiver: @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void
  typealias DeviceHandler = @Sendable (String) -> Void
  typealias ConnectionHandler = @Sendable (Bool) -> Void

  static let companionPort: UInt16 = 52_777

  private let queue = DispatchQueue(label: "com.rockyshi.mirrorphone.ios-usb")
  private let onStatus: StatusHandler
  private let onDeviceDetected: DeviceHandler
  private let onConnectionChanged: ConnectionHandler
  private let decoder: H264Decoder
  private var parser = MirrorMessageParser()
  private var pollTimer: DispatchSourceTimer?
  private var readSource: DispatchSourceRead?
  private var tunnelDescriptor: Int32 = -1
  private var stopped = true
  private var nextTag: UInt32 = 1

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
    queue.async { [weak self] in
      guard let self, stopped else { return }
      stopped = false
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: 1)
      timer.setEventHandler { [weak self] in
        self?.connectIfPossible()
      }
      pollTimer = timer
      timer.resume()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      stopped = true
      pollTimer?.cancel()
      pollTimer = nil
      closeTunnel(reportDisconnection: false)
      parser.reset()
      decoder.reset()
    }
  }

  private func connectIfPossible() {
    guard !stopped, tunnelDescriptor == -1 else { return }
    do {
      let devices = try USBMuxClient.listUSBDevices(nextTag: &nextTag)
      guard let device = devices.first else { return }
      let tunnel = try USBMuxClient.connect(
        deviceID: device.deviceID,
        port: Self.companionPort,
        nextTag: &nextTag
      )
      tunnelDescriptor = tunnel.descriptor
      parser.reset()
      decoder.reset()
      onConnectionChanged(true)
      onStatus("iPhone connected by cable · waiting for video")
      if !tunnel.initialData.isEmpty {
        consume(tunnel.initialData)
      }
      beginReading(tunnel.descriptor)
    } catch USBMuxError.connectionRefused {
      // The phone is attached, but its broadcast extension is not listening yet.
    } catch USBMuxError.noDevice {
      // Poll quietly until a paired USB device appears.
    } catch {
      onStatus("iPhone cable unavailable: \(error.localizedDescription)")
    }
  }

  private func beginReading(_ descriptor: Int32) {
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source, tunnelDescriptor == descriptor else { return }
      let available = max(1, min(Int(source.data), 256 * 1_024))
      var bytes = [UInt8](repeating: 0, count: available)
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        consume(Data(bytes.prefix(count)))
      } else if count == 0 || errno != EAGAIN {
        closeTunnel(reportDisconnection: true)
      }
    }
    source.setCancelHandler {
      Darwin.close(descriptor)
    }
    readSource = source
    source.resume()
  }

  private func consume(_ data: Data) {
    do {
      for message in try parser.append(data) {
        try handle(message)
      }
    } catch {
      onStatus(error.localizedDescription)
      closeTunnel(reportDisconnection: true)
    }
  }

  private func handle(_ message: MirrorMessage) throws {
    switch message.type {
    case .hello:
      let name = String(data: message.payload, encoding: .utf8) ?? "iPhone"
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

  private func closeTunnel(reportDisconnection: Bool) {
    guard tunnelDescriptor != -1 else { return }
    tunnelDescriptor = -1
    let source = readSource
    readSource = nil
    source?.cancel()
    parser.reset()
    decoder.reset()
    onConnectionChanged(false)
    if reportDisconnection, !stopped {
      onStatus("iPhone cable disconnected · waiting to reconnect")
    }
  }
}

struct USBMuxDevice: Equatable, Sendable {
  let deviceID: UInt32
  let serialNumber: String
}

struct USBMuxTunnel: Sendable {
  let descriptor: Int32
  let initialData: Data
}

struct USBMuxDeviceEventState {
  private var devicesByID = [UInt32: USBMuxDevice]()

  var devices: [USBMuxDevice] {
    devicesByID.values.sorted { $0.deviceID < $1.deviceID }
  }

  mutating func apply(_ plist: [String: Any]) -> Bool {
    guard let messageType = plist["MessageType"] as? String else { return false }

    switch messageType {
    case "Attached":
      guard let properties = plist["Properties"] as? [String: Any],
        properties["ConnectionType"] as? String == "USB",
        let deviceID = Self.integer(plist["DeviceID"] ?? properties["DeviceID"]),
        let serialNumber = properties["SerialNumber"] as? String,
        !serialNumber.isEmpty
      else { return false }
      let device = USBMuxDevice(deviceID: UInt32(deviceID), serialNumber: serialNumber)
      guard devicesByID[device.deviceID] != device else { return false }
      devicesByID[device.deviceID] = device
      return true

    case "Detached":
      guard let deviceID = Self.integer(plist["DeviceID"]) else { return false }
      return devicesByID.removeValue(forKey: UInt32(deviceID)) != nil

    default:
      return false
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }
}

final class USBMuxDeviceMonitor: @unchecked Sendable {
  typealias DevicesHandler = @Sendable ([USBMuxDevice]) -> Void

  private let queue = DispatchQueue(label: "com.rockyshi.mirrorphone.usbmux-events")
  private let onDevicesChanged: DevicesHandler
  private var readSource: DispatchSourceRead?
  private var reconnectWorkItem: DispatchWorkItem?
  private var descriptor: Int32 = -1
  private var buffer = Data()
  private var state = USBMuxDeviceEventState()
  private var nextTag: UInt32 = 1
  private var stopped = true

  init(onDevicesChanged: @escaping DevicesHandler) {
    self.onDevicesChanged = onDevicesChanged
  }

  func start() {
    queue.async { [weak self] in
      guard let self, stopped else { return }
      stopped = false
      openEventStream()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      stopped = true
      reconnectWorkItem?.cancel()
      reconnectWorkItem = nil
      closeEventStream(reconnect: false)
    }
  }

  private func openEventStream() {
    guard !stopped, descriptor == -1 else { return }
    do {
      let stream = try USBMuxClient.listen(nextTag: &nextTag)
      descriptor = stream.descriptor
      buffer = stream.initialData
      consumePackets()
      beginReading(stream.descriptor)
    } catch {
      scheduleReconnect()
    }
  }

  private func beginReading(_ descriptor: Int32) {
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.readAvailableBytes(from: descriptor)
    }
    source.setCancelHandler {
      Darwin.close(descriptor)
    }
    readSource = source
    source.resume()
  }

  private func readAvailableBytes(from descriptor: Int32) {
    guard self.descriptor == descriptor else { return }
    var bytes = [UInt8](repeating: 0, count: 64 * 1_024)

    while true {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        buffer.append(contentsOf: bytes.prefix(count))
        consumePackets()
        continue
      }
      if count == 0 || errno != EAGAIN {
        closeEventStream(reconnect: true)
      }
      break
    }
  }

  private func consumePackets() {
    do {
      for plist in try USBMuxClient.takePackets(from: &buffer) {
        if state.apply(plist) {
          onDevicesChanged(state.devices)
        }
      }
    } catch {
      closeEventStream(reconnect: true)
    }
  }

  private func closeEventStream(reconnect: Bool) {
    descriptor = -1
    buffer.removeAll(keepingCapacity: true)
    let source = readSource
    readSource = nil
    source?.cancel()
    // A daemon stream interruption is not a physical detach. Preserve the
    // latest device state while reconnecting; a real removal arrives as a
    // usbmuxd Detached event and is handled by consumePackets().
    if reconnect, !stopped {
      scheduleReconnect()
    }
  }

  private func scheduleReconnect() {
    guard !stopped, reconnectWorkItem == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      reconnectWorkItem = nil
      openEventStream()
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 1, execute: workItem)
  }

  deinit {
    reconnectWorkItem?.cancel()
    if descriptor != -1 {
      Darwin.close(descriptor)
    }
  }
}

enum USBMuxError: LocalizedError, Equatable {
  case daemonUnavailable(Int32)
  case invalidResponse
  case noDevice
  case connectionRefused
  case result(Int)
  case transport(Int32)

  var errorDescription: String? {
    switch self {
    case .daemonUnavailable(let code):
      "The macOS USB device service is unavailable (\(code))."
    case .invalidResponse:
      "The macOS USB device service returned an invalid response."
    case .noDevice:
      "No USB iPhone is connected."
    case .connectionRefused:
      "The iPhone companion is not listening over USB yet."
    case .result(let code):
      "The macOS USB device service rejected the connection (\(code))."
    case .transport(let code):
      "The iPhone USB connection failed (\(code))."
    }
  }
}

enum USBMuxClient {
  private static let socketPath = "/var/run/usbmuxd"
  private static let protocolVersion: UInt32 = 1
  private static let plistMessage: UInt32 = 8
  private static let headerSize = 16
  private static let maximumPacketSize = 4 * 1_024 * 1_024

  static func listUSBDevices(nextTag: inout UInt32) throws -> [USBMuxDevice] {
    let descriptor = try openDaemon()
    defer { Darwin.close(descriptor) }
    let response = try request(
      [
        "MessageType": "ListDevices",
        "ClientVersionString": "MirrorPhone 1.0",
        "ProgName": "MirrorPhone",
      ],
      descriptor: descriptor,
      tag: takeTag(&nextTag)
    ).plist
    guard let entries = response["DeviceList"] as? [[String: Any]] else {
      throw USBMuxError.invalidResponse
    }
    return entries.compactMap { entry in
      guard let properties = entry["Properties"] as? [String: Any],
        properties["ConnectionType"] as? String == "USB",
        let identifier = integer(entry["DeviceID"]),
        let serial = properties["SerialNumber"] as? String
      else { return nil }
      return USBMuxDevice(deviceID: UInt32(identifier), serialNumber: serial)
    }
  }

  static func connect(
    deviceID: UInt32,
    port: UInt16,
    nextTag: inout UInt32
  ) throws -> USBMuxTunnel {
    let descriptor = try openDaemon()
    do {
      let response = try request(
        [
          "MessageType": "Connect",
          "ClientVersionString": "MirrorPhone 1.0",
          "ProgName": "MirrorPhone",
          "DeviceID": Int(deviceID),
          "PortNumber": Int(port.bigEndian),
        ],
        descriptor: descriptor,
        tag: takeTag(&nextTag)
      )
      guard let number = integer(response.plist["Number"]) else {
        throw USBMuxError.invalidResponse
      }
      guard number == 0 else {
        if number == 3 { throw USBMuxError.connectionRefused }
        throw USBMuxError.result(number)
      }
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw USBMuxError.transport(errno)
      }
      return USBMuxTunnel(descriptor: descriptor, initialData: response.remainingData)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func listen(nextTag: inout UInt32) throws -> USBMuxTunnel {
    let descriptor = try openDaemon()
    do {
      let response = try request(
        [
          "MessageType": "Listen",
          "ClientVersionString": "MirrorPhone 1.0",
          "ProgName": "MirrorPhone",
        ],
        descriptor: descriptor,
        tag: takeTag(&nextTag)
      )
      guard integer(response.plist["Number"]) == 0 else {
        throw USBMuxError.invalidResponse
      }
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw USBMuxError.transport(errno)
      }
      return USBMuxTunnel(descriptor: descriptor, initialData: response.remainingData)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func encodedPacket(plist: [String: Any], tag: UInt32) throws -> Data {
    let payload = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    var packet = Data(capacity: headerSize + payload.count)
    packet.appendLittleEndian(UInt32(headerSize + payload.count))
    packet.appendLittleEndian(protocolVersion)
    packet.appendLittleEndian(plistMessage)
    packet.appendLittleEndian(tag)
    packet.append(payload)
    return packet
  }

  static func decodePacket(_ data: Data) throws -> (plist: [String: Any], consumed: Int) {
    guard data.count >= headerSize else { throw USBMuxError.invalidResponse }
    let length = Int(data.readLittleEndianUInt32(at: 0))
    guard length >= headerSize, length <= maximumPacketSize, data.count >= length,
      data.readLittleEndianUInt32(at: 4) == protocolVersion,
      data.readLittleEndianUInt32(at: 8) == plistMessage
    else { throw USBMuxError.invalidResponse }
    let payloadStart = data.index(data.startIndex, offsetBy: headerSize)
    let payloadEnd = data.index(data.startIndex, offsetBy: length)
    let payload = data.subdata(in: payloadStart..<payloadEnd)
    let decoded = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
    guard let plist = decoded as? [String: Any] else { throw USBMuxError.invalidResponse }
    return (plist, length)
  }

  static func takePackets(from data: inout Data) throws -> [[String: Any]] {
    var packets = [[String: Any]]()
    while data.count >= headerSize {
      let length = Int(data.readLittleEndianUInt32(at: 0))
      guard length >= headerSize, length <= maximumPacketSize else {
        throw USBMuxError.invalidResponse
      }
      guard data.count >= length else { break }
      let decoded = try decodePacket(data)
      packets.append(decoded.plist)
      data.removeFirst(decoded.consumed)
    }
    return packets
  }

  private static func request(
    _ plist: [String: Any],
    descriptor: Int32,
    tag: UInt32
  ) throws -> (plist: [String: Any], remainingData: Data) {
    let packet = try encodedPacket(plist: plist, tag: tag)
    try writeAll(packet, to: descriptor)
    var response = Data()
    while response.count < headerSize {
      try readMore(into: &response, from: descriptor)
    }
    let length = Int(response.readLittleEndianUInt32(at: 0))
    guard length >= headerSize, length <= maximumPacketSize else {
      throw USBMuxError.invalidResponse
    }
    while response.count < length {
      try readMore(into: &response, from: descriptor)
    }
    let decoded = try decodePacket(response)
    return (decoded.plist, Data(response.dropFirst(decoded.consumed)))
  }

  private static func openDaemon() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw USBMuxError.daemonUnavailable(errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let copied = socketPath.withCString { path in
      withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
          strlcpy($0, path, pathCapacity)
        }
      }
    }
    guard copied < pathCapacity else {
      Darwin.close(descriptor)
      throw USBMuxError.daemonUnavailable(ENAMETOOLONG)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw USBMuxError.daemonUnavailable(code)
    }
    return descriptor
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw USBMuxError.transport(errno) }
        offset += count
      }
    }
  }

  private static func readMore(into data: inout Data, from descriptor: Int32) throws {
    var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    guard count > 0 else { throw USBMuxError.transport(count == 0 ? ECONNRESET : errno) }
    data.append(contentsOf: bytes.prefix(count))
  }

  private static func takeTag(_ tag: inout UInt32) -> UInt32 {
    let result = tag
    tag &+= 1
    return result
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }
}

private extension Data {
  mutating func appendLittleEndian(_ value: UInt32) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }

  func readLittleEndianUInt32(at offset: Int) -> UInt32 {
    let start = index(startIndex, offsetBy: offset)
    let end = index(start, offsetBy: 4)
    return self[start..<end].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}
