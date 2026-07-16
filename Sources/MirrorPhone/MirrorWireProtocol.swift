import Foundation

enum MirrorMessageType: UInt8, Sendable {
  case hello = 1
  case videoFormat = 2
  case videoFrame = 3
}

struct MirrorMessage: Equatable, Sendable {
  let type: MirrorMessageType
  let payload: Data
}

enum MirrorWireProtocol {
  static let maximumPayloadSize = 16 * 1_024 * 1_024

  static func packet(type: MirrorMessageType, payload: Data) -> Data {
    var result = Data(capacity: 5 + payload.count)
    result.append(type.rawValue)
    result.appendUInt32(UInt32(payload.count))
    result.append(payload)
    return result
  }

  static func videoFramePayload(h264: Data, orientation: UInt8) -> Data {
    var result = Data(capacity: h264.count + 1)
    result.append(orientation)
    result.append(h264)
    return result
  }

  static func parseVideoFramePayload(_ payload: Data) throws -> (UInt8, Data) {
    guard payload.count > 1 else { throw MirrorProtocolError.invalidVideoFrame }
    let orientation = payload[payload.startIndex]
    guard (1...8).contains(orientation) else {
      throw MirrorProtocolError.invalidVideoFrame
    }
    return (orientation, Data(payload.dropFirst()))
  }
}

struct MirrorMessageParser: Sendable {
  private(set) var buffer = Data()

  mutating func append(_ data: Data) throws -> [MirrorMessage] {
    buffer.append(data)
    var messages = [MirrorMessage]()

    while buffer.count >= 5 {
      guard let type = MirrorMessageType(rawValue: buffer[buffer.startIndex]) else {
        throw MirrorProtocolError.invalidMessageType
      }
      let length = Int(buffer.readUInt32(at: 1))
      guard length <= MirrorWireProtocol.maximumPayloadSize else {
        throw MirrorProtocolError.payloadTooLarge
      }
      guard buffer.count >= 5 + length else { break }

      let payloadStart = buffer.index(buffer.startIndex, offsetBy: 5)
      let payloadEnd = buffer.index(payloadStart, offsetBy: length)
      let payload = Data(buffer[payloadStart..<payloadEnd])
      messages.append(MirrorMessage(type: type, payload: payload))
      buffer.removeFirst(5 + length)
    }

    return messages
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
  }
}

enum MirrorProtocolError: LocalizedError {
  case invalidMessageType
  case payloadTooLarge
  case invalidVideoFormat
  case invalidVideoFrame

  var errorDescription: String? {
    switch self {
    case .invalidMessageType:
      "The mobile companion sent an unknown message."
    case .payloadTooLarge:
      "The mobile companion sent an invalid oversized message."
    case .invalidVideoFormat:
      "The mobile companion sent an invalid H.264 format description."
    case .invalidVideoFrame:
      "The mobile companion sent a video frame with invalid orientation metadata."
    }
  }
}

extension Data {
  mutating func appendUInt16(_ value: UInt16) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }

  mutating func appendUInt32(_ value: UInt32) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }

  func readUInt16(at offset: Int) -> UInt16 {
    let start = index(startIndex, offsetBy: offset)
    let end = index(start, offsetBy: 2)
    return self[start..<end].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
  }

  func readUInt32(at offset: Int) -> UInt32 {
    let start = index(startIndex, offsetBy: offset)
    let end = index(start, offsetBy: 4)
    return self[start..<end].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}
