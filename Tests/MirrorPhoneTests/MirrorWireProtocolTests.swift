import Foundation
import Testing

@testable import MirrorPhone

@Suite("Mirror wire protocol")
struct MirrorWireProtocolTests {
  @Test("Parses fragmented and combined messages")
  func parsesStream() throws {
    let hello = MirrorWireProtocol.packet(type: .hello, payload: Data("aPhone".utf8))
    let frame = MirrorWireProtocol.packet(type: .videoFrame, payload: Data([1, 2, 3, 4]))
    let stream = hello + frame
    var parser = MirrorMessageParser()

    let first = try parser.append(Data(stream.prefix(3)))
    let second = try parser.append(Data(stream.dropFirst(3)))

    #expect(first.isEmpty)
    #expect(
      second == [
        MirrorMessage(type: .hello, payload: Data("aPhone".utf8)),
        MirrorMessage(type: .videoFrame, payload: Data([1, 2, 3, 4])),
      ])
  }

  @Test("Rejects unknown message types")
  func rejectsUnknownType() {
    var parser = MirrorMessageParser()
    #expect(throws: MirrorProtocolError.self) {
      try parser.append(Data([255, 0, 0, 0, 0]))
    }
  }

  @Test("Carries device orientation with each video frame")
  func parsesVideoFrameOrientation() throws {
    let h264 = Data([0, 0, 0, 1, 0x65])
    let payload = MirrorWireProtocol.videoFramePayload(h264: h264, orientation: 6)
    let (orientation, parsedH264) = try MirrorWireProtocol.parseVideoFramePayload(payload)

    #expect(orientation == 6)
    #expect(parsedH264 == h264)
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWireProtocol.parseVideoFramePayload(Data([0, 1]))
    }
  }
}
