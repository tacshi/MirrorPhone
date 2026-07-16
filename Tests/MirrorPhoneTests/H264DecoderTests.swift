import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import MirrorPhone

@Suite("H.264 decoder")
struct H264DecoderTests {
  @Test("Decodes and orients a VideoToolbox frame")
  func decodesFrame() throws {
    let encoded = try encodeTestFrame()
    let formatPayload = try makeFormatPayload(from: encoded)
    let framePayload = try copyEncodedBytes(from: encoded)
    let semaphore = DispatchSemaphore(value: 0)
    let output = DecodedImageBox()
    let decoder = H264Decoder { image in
      output.set(image)
      semaphore.signal()
    }

    try decoder.configure(with: formatPayload)
    decoder.decode(framePayload, orientation: .right)

    #expect(semaphore.wait(timeout: .now() + 2) == .success)
    let image = try #require(output.image)
    #expect(image.width == 96)
    #expect(image.height == 64)
  }

  private func encodeTestFrame() throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    #expect(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        96,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
      ) == kCVReturnSuccess
    )
    let buffer = try #require(pixelBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let address = CVPixelBufferGetBaseAddress(buffer) {
      memset(address, 0x7F, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    var session: VTCompressionSession?
    #expect(
      VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: 64,
        height: 96,
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
      ) == noErr
    )
    let compressionSession = try #require(session)
    defer { VTCompressionSessionInvalidate(compressionSession) }
    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_AllowFrameReordering,
      value: kCFBooleanFalse
    )
    VTSessionSetProperty(
      compressionSession,
      key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: 1 as CFNumber
    )
    VTCompressionSessionPrepareToEncodeFrames(compressionSession)

    let output = EncodedSampleBox()
    let semaphore = DispatchSemaphore(value: 0)
    #expect(
      VTCompressionSessionEncodeFrame(
        compressionSession,
        imageBuffer: buffer,
        presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 30),
        frameProperties: nil,
        infoFlagsOut: nil
      ) { status, _, sampleBuffer in
        if status == noErr, let sampleBuffer {
          output.set(sampleBuffer)
        }
        semaphore.signal()
      } == noErr
    )
    VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
    #expect(semaphore.wait(timeout: .now() + 2) == .success)
    return try #require(output.sampleBuffer)
  }

  private func makeFormatPayload(from sampleBuffer: CMSampleBuffer) throws -> Data {
    let format = try #require(sampleBuffer.formatDescription)
    let sps = try parameterSet(at: 0, from: format)
    let pps = try parameterSet(at: 1, from: format)
    var payload = Data()
    payload.appendUInt16(UInt16(sps.count))
    payload.append(sps)
    payload.appendUInt16(UInt16(pps.count))
    payload.append(pps)
    return payload
  }

  private func parameterSet(at index: Int, from format: CMFormatDescription) throws -> Data {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    var count = 0
    var headerLength: Int32 = 0
    #expect(
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format,
        parameterSetIndex: index,
        parameterSetPointerOut: &pointer,
        parameterSetSizeOut: &size,
        parameterSetCountOut: &count,
        nalUnitHeaderLengthOut: &headerLength
      ) == noErr
    )
    return Data(bytes: try #require(pointer), count: size)
  }

  private func copyEncodedBytes(from sampleBuffer: CMSampleBuffer) throws -> Data {
    let block = try #require(sampleBuffer.dataBuffer)
    let length = CMBlockBufferGetDataLength(block)
    var result = Data(count: length)
    let status = result.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        block,
        atOffset: 0,
        dataLength: length,
        destination: bytes.baseAddress!
      )
    }
    #expect(status == noErr)
    return result
  }
}

private final class EncodedSampleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: CMSampleBuffer?

  var sampleBuffer: CMSampleBuffer? {
    lock.withLock { storage }
  }

  func set(_ sampleBuffer: CMSampleBuffer) {
    lock.withLock { storage = sampleBuffer }
  }
}

private final class DecodedImageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: CGImage?

  var image: CGImage? {
    lock.withLock { storage }
  }

  func set(_ image: CGImage) {
    lock.withLock { storage = image }
  }
}
