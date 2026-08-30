import CoreImage
import ImageIO
@preconcurrency import VideoToolbox

final class H264Decoder: @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias VideoSampleHandler = @Sendable (MirrorVideoSample) -> Void

  private let onFrame: FrameHandler
  private let onVideoSample: VideoSampleHandler?
  private let pressureMeter: MirrorFramePressureMeter?
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?

  /// Converting a decoded frame to a CGImage is a full-resolution readback
  /// that can be slower than the incoming frame rate. Frames are handed to a
  /// render queue that always converts the newest one and drops any frame
  /// superseded while a conversion was in flight, so a live mirror stays
  /// current instead of accumulating delay.
  private let renderQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.h264-render",
    qos: .userInteractive
  )
  private let pendingLock = NSLock()
  private var pendingBuffer: CVImageBuffer?
  private var pendingOrientation = CGImagePropertyOrientation.up
  private var renderScheduled = false

  init(
    onVideoSample: VideoSampleHandler? = nil,
    onPerformanceWindow: MirrorFramePressureMeter.WindowHandler? = nil,
    onFrame: @escaping FrameHandler
  ) {
    self.onVideoSample = onVideoSample
    pressureMeter = onPerformanceWindow.map(MirrorFramePressureMeter.init(onWindow:))
    self.onFrame = onFrame
  }

  deinit {
    reset()
  }

  func configure(with payload: Data) throws {
    guard payload.count >= 4 else { throw MirrorProtocolError.invalidVideoFormat }
    let spsLength = Int(payload.readUInt16(at: 0))
    let ppsLengthOffset = 2 + spsLength
    guard spsLength > 0, payload.count >= ppsLengthOffset + 2 else {
      throw MirrorProtocolError.invalidVideoFormat
    }
    let ppsLength = Int(payload.readUInt16(at: ppsLengthOffset))
    let ppsOffset = ppsLengthOffset + 2
    guard ppsLength > 0, payload.count == ppsOffset + ppsLength else {
      throw MirrorProtocolError.invalidVideoFormat
    }

    let sps = Data(payload[2..<ppsLengthOffset])
    let pps = Data(payload[ppsOffset..<(ppsOffset + ppsLength)])
    var newFormat: CMFormatDescription?
    let formatStatus = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        guard
          let spsAddress = spsBytes.bindMemory(to: UInt8.self).baseAddress,
          let ppsAddress = ppsBytes.bindMemory(to: UInt8.self).baseAddress
        else { return kCMFormatDescriptionError_InvalidParameter }

        let parameterSets = [spsAddress, ppsAddress]
        let parameterSetSizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: parameterSets.count,
          parameterSetPointers: parameterSets,
          parameterSetSizes: parameterSetSizes,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &newFormat
        )
      }
    }
    guard formatStatus == noErr, let newFormat else {
      throw MirrorProtocolError.invalidVideoFormat
    }

    reset()
    formatDescription = newFormat
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: Self.outputCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    // Let the decoder emit its native 4:2:0 format. Requesting BGRA here would
    // add a full-resolution color conversion to every decoded frame inside the
    // synchronous decode call — ahead of the frame-dropping render stage — and
    // that mandatory per-frame cost is what let a 120 Hz stream outrun the
    // pipeline. RGB conversion happens in the render stage, only for frames
    // that are actually displayed.
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    let sessionStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: newFormat,
      decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary,
      outputCallback: &callback,
      decompressionSessionOut: &session
    )
    guard sessionStatus == noErr, let session else {
      reset()
      throw MirrorProtocolError.invalidVideoFormat
    }
    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
  }

  func decode(_ data: Data, orientation: CGImagePropertyOrientation = .up) {
    guard !data.isEmpty, let session, let formatDescription else { return }

    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      ) == kCMBlockBufferNoErr,
      let blockBuffer
    else { return }

    let copyStatus = data.withUnsafeBytes { bytes in
      guard let address = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      return CMBlockBufferReplaceDataBytes(
        with: address,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else { return }

    var sampleBuffer: CMSampleBuffer?
    var sampleSize = data.count
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      ) == noErr,
      let sampleBuffer
    else { return }

    var outputFlags = VTDecodeInfoFlags()
    let frameContext = Unmanaged.passRetained(
      DecodedFrameContext(
        orientation: orientation,
        presentationTime: CMClockGetTime(CMClockGetHostTimeClock())
      )
    )
    // Decode synchronously: the stream carries no timestamps, so realtime-paced
    // asynchronous decompression queues frames and the mirror falls ever further
    // behind the live screen. Each frame is displayed the moment it arrives.
    let decodeStartedAt = ProcessInfo.processInfo.systemUptime
    let decodeStatus = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [],
      frameRefcon: frameContext.toOpaque(),
      infoFlagsOut: &outputFlags
    )
    pressureMeter?.recordDecode(
      duration: ProcessInfo.processInfo.systemUptime - decodeStartedAt
    )
    if decodeStatus != noErr {
      frameContext.release()
    }
  }

  func reset() {
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    formatDescription = nil
    pendingLock.lock()
    pendingBuffer = nil
    pendingLock.unlock()
    pressureMeter?.reset()
  }

  private func scheduleRender(of imageBuffer: CVImageBuffer, orientation: CGImagePropertyOrientation) {
    pendingLock.lock()
    pendingBuffer = imageBuffer
    pendingOrientation = orientation
    let alreadyScheduled = renderScheduled
    renderScheduled = true
    pendingLock.unlock()
    if alreadyScheduled {
      pressureMeter?.recordDisplayReplacement()
    }
    guard !alreadyScheduled else { return }

    renderQueue.async { [weak self] in
      guard let self else { return }
      pendingLock.lock()
      let buffer = pendingBuffer
      let orientation = pendingOrientation
      pendingBuffer = nil
      renderScheduled = false
      pendingLock.unlock()
      guard let buffer else { return }

      let renderStartedAt = ProcessInfo.processInfo.systemUptime
      let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
      guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
      pressureMeter?.recordRender(
        duration: ProcessInfo.processInfo.systemUptime - renderStartedAt
      )
      onFrame(frame)
    }
  }

  private func offerRecordingSample(
    from imageBuffer: CVImageBuffer,
    orientation: CGImagePropertyOrientation,
    presentationTime: CMTime
  ) {
    guard let onVideoSample else { return }
    onVideoSample(
      MirrorVideoSample(
        image: CIImage(cvPixelBuffer: imageBuffer).oriented(orientation),
        presentationTime: presentationTime
      )
    )
  }

  private static let outputCallback: VTDecompressionOutputCallback = {
    refcon,
    frameRefcon,
    status,
    _,
    imageBuffer,
    _,
    _ in
    let frameContext =
      frameRefcon.map {
        Unmanaged<DecodedFrameContext>.fromOpaque($0).takeRetainedValue()
      }
    guard status == noErr, let refcon, let imageBuffer else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
    decoder.pressureMeter?.recordSourceFrame()
    decoder.offerRecordingSample(
      from: imageBuffer,
      orientation: frameContext?.orientation ?? .up,
      presentationTime: frameContext?.presentationTime
        ?? CMClockGetTime(CMClockGetHostTimeClock())
    )
    decoder.scheduleRender(of: imageBuffer, orientation: frameContext?.orientation ?? .up)
  }
}

private final class DecodedFrameContext {
  let orientation: CGImagePropertyOrientation
  let presentationTime: CMTime

  init(orientation: CGImagePropertyOrientation, presentationTime: CMTime) {
    self.orientation = orientation
    self.presentationTime = presentationTime
  }
}
