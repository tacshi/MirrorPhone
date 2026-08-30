@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreImage
import Foundation

struct MP4RecordingResult: Sendable {
  let outputURL: URL
  let droppedVideoFrameCount: Int
  let recordedAudio: Bool
}

enum MP4RecorderError: LocalizedError {
  case invalidCanvas
  case couldNotStart(String)
  case noVideo
  case audioSampleFailed
  case writingFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidCanvas:
      "The recording canvas has an invalid size."
    case .couldNotStart(let detail):
      "Could not start recording: \(detail)"
    case .noVideo:
      "No video frames were recorded."
    case .audioSampleFailed:
      "The Android audio stream could not be converted for recording."
    case .writingFailed(let detail):
      "Could not finish the MP4 recording: \(detail)"
    }
  }
}

enum MP4RecordingConfiguration {
  static func canvasSize(for sourceSize: CGSize) -> CGSize {
    CGSize(
      width: evenDimension(sourceSize.width),
      height: evenDimension(sourceSize.height)
    )
  }

  static func aspectFitRect(sourceSize: CGSize, canvasSize: CGSize) -> CGRect {
    guard sourceSize.width > 0, sourceSize.height > 0,
      canvasSize.width > 0, canvasSize.height > 0
    else { return .zero }

    let scale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
    let fittedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    return CGRect(
      x: (canvasSize.width - fittedSize.width) / 2,
      y: (canvasSize.height - fittedSize.height) / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }

  static func videoBitRate(for canvasSize: CGSize) -> Int {
    let adaptive = Int((canvasSize.width * canvasSize.height * 5).rounded())
    return min(max(adaptive, 6_000_000), 24_000_000)
  }

  private static func evenDimension(_ value: CGFloat) -> CGFloat {
    let integral = max(2, Int(ceil(value)))
    return CGFloat(integral.isMultiple(of: 2) ? integral : integral + 1)
  }
}

struct MP4VideoCadenceGate {
  static let maximumFramesPerSecond: CMTimeScale = 60
  private static let minimumFrameInterval = CMTime(
    value: 1,
    timescale: maximumFramesPerSecond
  )

  private var lastAcceptedTime: CMTime?
  private(set) var rejectedNonMonotonicFrameCount = 0

  mutating func shouldAccept(_ presentationTime: CMTime) -> Bool {
    guard presentationTime.isNumeric else {
      rejectedNonMonotonicFrameCount += 1
      return false
    }
    guard let lastAcceptedTime else {
      self.lastAcceptedTime = presentationTime
      return true
    }
    guard CMTimeCompare(presentationTime, lastAcceptedTime) > 0 else {
      rejectedNonMonotonicFrameCount += 1
      return false
    }
    guard
      CMTimeCompare(
        presentationTime - lastAcceptedTime,
        Self.minimumFrameInterval
      ) >= 0
    else { return false }

    self.lastAcceptedTime = presentationTime
    return true
  }
}

enum MP4RecordingQueue {
  static let maximumVideoFrames = 8

  /// Keeps the newest capture work. Returning `true` records that the oldest
  /// pending frame was evicted to protect real-time mirroring and A/V sync.
  @discardableResult
  static func append(_ sample: MirrorVideoSample, to queue: inout [MirrorVideoSample]) -> Bool {
    let evicted = queue.count >= maximumVideoFrames
    if evicted {
      queue.removeFirst()
    }
    queue.append(sample)
    return evicted
  }
}

final class MP4Recorder: MirrorRecordingSink, @unchecked Sendable {
  private enum State {
    case ready
    case writing
    case finishing
    case finished
    case failed
  }

  private let destinationURL: URL
  private let temporaryURL: URL
  private let canvasSize: CGSize
  private let canvasRect: CGRect
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
  private let audioInput: AVAssetWriterInput?
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private let writerQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.mp4-recorder",
    qos: .userInitiated
  )
  private let audioStateHandler: @Sendable (MirrorRecordingAudioState) -> Void
  private let ingressLock = NSLock()

  private var state = State.ready
  private var pendingVideo = [MirrorVideoSample]()
  private var pendingAudio = [MirrorAudioSample]()
  private var pendingAudioDuration = CMTime.zero
  private var acceptingSamples = false
  private var acceptingAudio = false
  private var ingressServiceScheduled = false
  private var ingressDroppedVideoFrameCount = 0
  private var ingressAudioOverrun = false
  private var cadenceGate = MP4VideoCadenceGate()
  private var retryScheduled = false
  private var sessionStarted = false
  private var sessionStartTime: CMTime?
  private var finalizationStarted = false
  private var lastVideoTime: CMTime?
  private var lastAudioTime: CMTime?
  private var audioHostTimelineID: UUID?
  private var audioHostTimelineOffset: CMTime?
  private var droppedVideoFrameCount = 0
  private var recordedAudio = false
  private var audioDisabled = false
  private var audioInputFinished = false
  private var finishContinuations = [CheckedContinuation<MP4RecordingResult, Error>]()

  var outputURL: URL { destinationURL }

  init(
    destinationURL: URL,
    canvasSize requestedSize: CGSize,
    audioStateHandler: @escaping @Sendable (MirrorRecordingAudioState) -> Void = { _ in }
  ) throws {
    guard requestedSize.width.isFinite, requestedSize.height.isFinite,
      requestedSize.width > 0, requestedSize.height > 0
    else { throw MP4RecorderError.invalidCanvas }
    let canvasSize = MP4RecordingConfiguration.canvasSize(for: requestedSize)
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      throw MP4RecorderError.invalidCanvas
    }
    self.destinationURL = destinationURL
    self.audioStateHandler = audioStateHandler
    self.canvasSize = canvasSize
    canvasRect = CGRect(origin: .zero, size: canvasSize)
    temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".MirrorPhone-\(UUID().uuidString).partial.mp4"
    )

    writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
    let width = Int(canvasSize.width)
    let height = Int(canvasSize.height)
    let compression: [String: Any] = [
      AVVideoAverageBitRateKey: MP4RecordingConfiguration.videoBitRate(for: canvasSize),
      AVVideoExpectedSourceFrameRateKey: MP4VideoCadenceGate.maximumFramesPerSecond,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalDurationKey: 2,
    ]
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]
    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    videoInput.expectsMediaDataInRealTime = true
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: attributes
    )
    guard writer.canAdd(videoInput) else {
      throw MP4RecorderError.couldNotStart("The H.264 video input is unsupported.")
    }
    writer.add(videoInput)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 192_000,
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = true
    if writer.canAdd(audioInput) {
      writer.add(audioInput)
      self.audioInput = audioInput
    } else {
      self.audioInput = nil
      audioDisabled = true
    }
  }

  deinit {
    if state != .finished {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }

  func start() throws {
    try writerQueue.sync {
      guard state == .ready else { return }
      guard writer.startWriting() else {
        state = .failed
        throw MP4RecorderError.couldNotStart(
          writer.error?.localizedDescription ?? "AVFoundation rejected the output file."
        )
      }
      state = .writing
      ingressLock.withLock {
        acceptingSamples = true
        acceptingAudio = !audioDisabled
      }
    }
  }

  func receive(video sample: MirrorVideoSample) {
    var shouldSchedule = false
    ingressLock.lock()
    if acceptingSamples {
      let priorTimestampRejections = cadenceGate.rejectedNonMonotonicFrameCount
      if cadenceGate.shouldAccept(sample.presentationTime) {
        if MP4RecordingQueue.append(sample, to: &pendingVideo) {
          ingressDroppedVideoFrameCount += 1
        }
        if !ingressServiceScheduled {
          ingressServiceScheduled = true
          shouldSchedule = true
        }
      } else if cadenceGate.rejectedNonMonotonicFrameCount > priorTimestampRejections {
        ingressDroppedVideoFrameCount += 1
      }
    }
    ingressLock.unlock()
    guard shouldSchedule else { return }
    writerQueue.async { [weak self] in
      self?.serviceIngress()
    }
  }

  func finish() async throws -> MP4RecordingResult {
    ingressLock.withLock {
      acceptingSamples = false
      acceptingAudio = false
    }
    return try await withCheckedThrowingContinuation { continuation in
      writerQueue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: CancellationError())
          return
        }
        switch state {
        case .writing:
          state = .finishing
          finishContinuations.append(continuation)
          drainVideo()
          finishIfDrained()
        case .finishing:
          finishContinuations.append(continuation)
        case .finished:
          continuation.resume(
            returning: MP4RecordingResult(
              outputURL: destinationURL,
              droppedVideoFrameCount: droppedVideoFrameCount,
              recordedAudio: recordedAudio
            )
          )
        case .ready:
          continuation.resume(throwing: MP4RecorderError.couldNotStart("Recording was not started."))
        case .failed:
          continuation.resume(
            throwing: MP4RecorderError.writingFailed(
              writer.error?.localizedDescription ?? "The writer failed."
            )
          )
        }
      }
    }
  }

  func receive(audio sample: MirrorAudioSample) {
    var shouldSchedule = false
    ingressLock.lock()
    if acceptingSamples, acceptingAudio {
      let newDuration = pendingAudioDuration + sample.sampleBuffer.duration
      if CMTimeCompare(newDuration, CMTime(seconds: 2, preferredTimescale: 48_000)) > 0 {
        pendingAudio.removeAll(keepingCapacity: false)
        pendingAudioDuration = .zero
        acceptingAudio = false
        ingressAudioOverrun = true
      } else {
        pendingAudio.append(sample)
        pendingAudioDuration = newDuration
      }
      if !ingressServiceScheduled {
        ingressServiceScheduled = true
        shouldSchedule = true
      }
    }
    ingressLock.unlock()
    guard shouldSchedule else { return }
    writerQueue.async { [weak self] in
      self?.serviceIngress()
    }
  }

  func audioStateChanged(_ state: MirrorRecordingAudioState) {
    writerQueue.async { [weak self] in
      guard let self else { return }
      if audioDisabled {
        audioStateHandler(
          .unavailable("Device audio is unavailable; recording is continuing with video only.")
        )
      } else {
        audioStateHandler(state)
      }
    }
  }

  private func serviceIngress() {
    ingressLock.withLock {
      ingressServiceScheduled = false
    }
    drainVideo()
  }

  private func consumeIngressSignals() {
    let signals = ingressLock.withLock { () -> (droppedFrames: Int, audioOverrun: Bool) in
      let signals = (ingressDroppedVideoFrameCount, ingressAudioOverrun)
      ingressDroppedVideoFrameCount = 0
      ingressAudioOverrun = false
      return signals
    }
    droppedVideoFrameCount += signals.droppedFrames
    if signals.audioOverrun {
      disableAudio()
    }
  }

  private func popVideoSample() -> MirrorVideoSample? {
    ingressLock.withLock {
      pendingVideo.isEmpty ? nil : pendingVideo.removeFirst()
    }
  }

  private func popAudioSample() -> MirrorAudioSample? {
    ingressLock.withLock {
      guard !pendingAudio.isEmpty else { return nil }
      let sample = pendingAudio.removeFirst()
      pendingAudioDuration = CMTimeMaximum(.zero, pendingAudioDuration - sample.sampleBuffer.duration)
      return sample
    }
  }

  private var hasPendingVideo: Bool {
    ingressLock.withLock { !pendingVideo.isEmpty }
  }

  private var hasPendingAudio: Bool {
    ingressLock.withLock { !pendingAudio.isEmpty }
  }

  private func drainVideo() {
    guard state == .writing || state == .finishing else { return }
    consumeIngressSignals()
    guard state == .writing || state == .finishing else { return }
    guard writer.status != .failed else {
      failWriter(
        MP4RecorderError.writingFailed(
          writer.error?.localizedDescription ?? "AVFoundation stopped writing the MP4."
        )
      )
      return
    }
    while videoInput.isReadyForMoreMediaData, let sample = popVideoSample() {
      guard lastVideoTime.map({ CMTimeCompare(sample.presentationTime, $0) > 0 }) ?? true else {
        droppedVideoFrameCount += 1
        continue
      }
      if !sessionStarted {
        writer.startSession(atSourceTime: sample.presentationTime)
        sessionStarted = true
        sessionStartTime = sample.presentationTime
      }
      guard let pixelBuffer = makePixelBuffer(for: sample.image),
        videoAdaptor.append(pixelBuffer, withPresentationTime: sample.presentationTime)
      else {
        failWriter(
          MP4RecorderError.writingFailed(
            writer.error?.localizedDescription ?? "The video encoder rejected a frame."
          )
        )
        return
      }
      lastVideoTime = sample.presentationTime
    }

    drainAudio()
    if hasPendingVideo || (hasPendingAudio && !audioDisabled) {
      scheduleDrainRetry()
    }
    finishIfDrained()
  }

  private func drainAudio() {
    guard state == .writing || state == .finishing,
      sessionStarted,
      !audioDisabled,
      let audioInput,
      let sessionStartTime
    else { return }

    while audioInput.isReadyForMoreMediaData, let sample = popAudioSample() {
      guard let sampleBuffer = audioSampleBufferOnWriterTimeline(sample) else {
        disableAudio()
        return
      }
      let presentationTime = sampleBuffer.presentationTimeStamp
      // AVAssetWriter clips audio buffers at the session boundary. Preserve a
      // buffer that overlaps the first video frame; dropping it wholesale
      // creates a start gap as large as the capture chunk itself.
      let duration = sampleBuffer.duration
      let reachesSession =
        if duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
          CMTimeCompare(presentationTime + duration, sessionStartTime) > 0
        } else {
          CMTimeCompare(presentationTime, sessionStartTime) >= 0
        }
      guard reachesSession else { continue }
      guard lastAudioTime.map({ CMTimeCompare(presentationTime, $0) > 0 }) ?? true else { continue }
      guard audioInput.append(sampleBuffer) else {
        disableAudio()
        return
      }
      recordedAudio = true
      lastAudioTime = presentationTime
    }
  }

  private func audioSampleBufferOnWriterTimeline(
    _ sample: MirrorAudioSample
  ) -> CMSampleBuffer? {
    guard let anchor = sample.hostClockAnchor else { return sample.sampleBuffer }

    if audioHostTimelineID != anchor.timelineID {
      let presentationTime = sample.sampleBuffer.presentationTimeStamp
      let duration = sample.sampleBuffer.duration
      guard presentationTime.isNumeric, duration.isNumeric,
        anchor.bufferEndTime.isNumeric
      else { return nil }
      audioHostTimelineID = anchor.timelineID
      audioHostTimelineOffset = anchor.bufferEndTime - (presentationTime + duration)
    }
    guard let offset = audioHostTimelineOffset, offset.isNumeric else { return nil }
    guard CMTimeCompare(offset, .zero) != 0 else { return sample.sampleBuffer }

    var timing = CMSampleTimingInfo()
    guard
      CMSampleBufferGetSampleTimingInfo(
        sample.sampleBuffer,
        at: 0,
        timingInfoOut: &timing
      ) == noErr
    else { return nil }
    timing.presentationTimeStamp = timing.presentationTimeStamp + offset
    if timing.decodeTimeStamp.isNumeric {
      timing.decodeTimeStamp = timing.decodeTimeStamp + offset
    }
    var retimed: CMSampleBuffer?
    guard
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: sample.sampleBuffer,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleBufferOut: &retimed
      ) == noErr
    else { return nil }
    return retimed
  }

  private func scheduleDrainRetry() {
    guard !retryScheduled else { return }
    retryScheduled = true
    writerQueue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
      guard let self else { return }
      retryScheduled = false
      drainVideo()
    }
  }

  private func finishIfDrained() {
    guard state == .finishing,
      !hasPendingVideo,
      !finalizationStarted
    else { return }
    guard sessionStarted else {
      failWriter(MP4RecorderError.noVideo)
      return
    }
    guard !hasPendingAudio || audioDisabled else { return }
    finalizationStarted = true
    videoInput.markAsFinished()
    finishAudioInputIfNeeded()
    writer.finishWriting { [weak self] in
      guard let self else { return }
      writerQueue.async { [self] in
        guard self.writer.status == .completed else {
          self.failWriter(
            MP4RecorderError.writingFailed(
              self.writer.error?.localizedDescription ?? "AVFoundation did not complete the file."
            )
          )
          return
        }
        do {
          try self.publishTemporaryFile()
          self.state = .finished
          let result = MP4RecordingResult(
            outputURL: self.destinationURL,
            droppedVideoFrameCount: self.droppedVideoFrameCount,
            recordedAudio: self.recordedAudio
          )
          let continuations = self.finishContinuations
          self.finishContinuations.removeAll()
          continuations.forEach { $0.resume(returning: result) }
        } catch {
          self.failWriter(error)
        }
      }
    }
  }

  private func disableAudio() {
    guard !audioDisabled else { return }
    audioDisabled = true
    audioStateHandler(
      .unavailable("Device audio could not keep up; recording is continuing with video only.")
    )
    ingressLock.withLock {
      acceptingAudio = false
      pendingAudio.removeAll(keepingCapacity: false)
      pendingAudioDuration = .zero
    }
    finishAudioInputIfNeeded()
    finishIfDrained()
  }

  private func finishAudioInputIfNeeded() {
    guard !audioInputFinished, let audioInput else { return }
    audioInputFinished = true
    audioInput.markAsFinished()
  }

  private func makePixelBuffer(for image: CIImage) -> CVPixelBuffer? {
    guard let pool = videoAdaptor.pixelBufferPool else { return nil }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
      let output
    else { return nil }

    let extent = image.extent.integral
    guard extent.width > 0, extent.height > 0 else { return nil }
    let normalized = image.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    let fitted = MP4RecordingConfiguration.aspectFitRect(
      sourceSize: extent.size,
      canvasSize: canvasSize
    )
    let scale = fitted.width / extent.width
    let transformed = normalized.transformed(
      by: CGAffineTransform(scaleX: scale, y: scale)
        .translatedBy(x: fitted.minX / scale, y: fitted.minY / scale)
    )
    let background = CIImage(color: .black).cropped(to: canvasRect)
    imageContext.render(
      transformed.composited(over: background),
      to: output,
      bounds: canvasRect,
      colorSpace: colorSpace
    )
    return output
  }

  private func publishTemporaryFile() throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: temporaryURL,
        backupItemName: nil,
        options: []
      )
    } else {
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
  }

  private func failWriter(_ error: Error) {
    guard state != .failed, state != .finished else { return }
    state = .failed
    ingressLock.withLock {
      acceptingSamples = false
      acceptingAudio = false
      pendingVideo.removeAll(keepingCapacity: false)
      pendingAudio.removeAll(keepingCapacity: false)
      pendingAudioDuration = .zero
    }
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: temporaryURL)
    let continuations = finishContinuations
    finishContinuations.removeAll()
    continuations.forEach { $0.resume(throwing: error) }
  }
}
