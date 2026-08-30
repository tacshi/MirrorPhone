import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import MirrorPhone

@Suite("MP4 recording")
struct MP4RecorderTests {
  @Test("Recording keeps an even native canvas and aspect-fits rotations")
  func fixedCanvasAcrossRotation() {
    let canvas = MP4RecordingConfiguration.canvasSize(
      for: CGSize(width: 1_179, height: 2_557)
    )
    let landscape = MP4RecordingConfiguration.aspectFitRect(
      sourceSize: CGSize(width: 2_557, height: 1_179),
      canvasSize: canvas
    )

    #expect(canvas == CGSize(width: 1_180, height: 2_558))
    #expect(abs(landscape.width - 1_180) < 0.001)
    #expect(landscape.height < canvas.height)
    #expect(abs(landscape.midX - canvas.width / 2) < 0.001)
    #expect(abs(landscape.midY - canvas.height / 2) < 0.001)
  }

  @Test("Recording bitrate follows the agreed adaptive bounds")
  func adaptiveBitrate() {
    #expect(
      MP4RecordingConfiguration.videoBitRate(
        for: CGSize(width: 640, height: 480)
      ) == 6_000_000
    )
    #expect(
      MP4RecordingConfiguration.videoBitRate(
        for: CGSize(width: 1_920, height: 1_080)
      ) == 10_368_000
    )
    #expect(
      MP4RecordingConfiguration.videoBitRate(
        for: CGSize(width: 4_000, height: 3_000)
      ) == 24_000_000
    )
  }

  @Test("Recording cadence is capped at 60 fps without rewriting timestamps")
  func capsRecordingCadenceAt60FPS() {
    var gate = MP4VideoCadenceGate()
    let times = (0..<7).map { CMTime(value: CMTimeValue($0), timescale: 120) }
    let accepted = times.filter { gate.shouldAccept($0) }

    #expect(MP4VideoCadenceGate.maximumFramesPerSecond == 60)
    #expect(accepted == [times[0], times[2], times[4], times[6]])
  }

  @Test("Cadence limiting preserves native rates below 60 fps")
  func preservesLowerNativeCadence() {
    var gate = MP4VideoCadenceGate()
    let times = (0..<4).map { CMTime(value: CMTimeValue($0), timescale: 30) }

    #expect(times.allSatisfy { gate.shouldAccept($0) })
  }

  @Test("A 120 Hz source writes at most 60 video samples per second")
  func recorderApplies60FPSCap() async throws {
    let outputURL = temporaryMP4URL(prefix: "60-fps-cap")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let canvas = CGSize(width: 64, height: 64)
    let image = CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas))
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()

    for frame in 0..<13 {
      recorder.receive(
        video: MirrorVideoSample(
          image: image,
          presentationTime: CMTime(
            value: 1_200 + CMTimeValue(frame),
            timescale: 120
          )
        )
      )
      try await Task.sleep(for: .milliseconds(2))
    }

    let result = try await recorder.finish()
    let asset = AVURLAsset(url: result.outputURL)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var sampleCount = 0
    while let sample = output.copyNextSampleBuffer() {
      sampleCount += CMSampleBufferGetNumSamples(sample)
    }

    #expect(sampleCount == 7)
    #expect(result.droppedVideoFrameCount == 0)
  }

  @Test("Cadence limiting rejects non-monotonic source time")
  func cadenceRequiresMonotonicTime() {
    var gate = MP4VideoCadenceGate()
    let firstAccepted = gate.shouldAccept(CMTime(seconds: 10, preferredTimescale: 600))
    let olderAccepted = gate.shouldAccept(CMTime(seconds: 9, preferredTimescale: 600))

    #expect(firstAccepted)
    #expect(!olderAccepted)
    #expect(gate.rejectedNonMonotonicFrameCount == 1)
  }

  @Test("Video overload evicts the oldest pending frame")
  func evictsOldestVideoFrame() {
    let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
    var queue = [MirrorVideoSample]()
    for value in 0...MP4RecordingQueue.maximumVideoFrames {
      MP4RecordingQueue.append(
        MirrorVideoSample(
          image: image,
          presentationTime: CMTime(value: CMTimeValue(value), timescale: 60)
        ),
        to: &queue
      )
    }

    #expect(queue.count == MP4RecordingQueue.maximumVideoFrames)
    #expect(queue.first?.presentationTime.value == 1)
    #expect(queue.last?.presentationTime.value == 8)
  }

  @Test("A video-only recording produces a playable MP4")
  func writesVideoOnlyMP4() async throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MirrorPhone-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let canvas = CGSize(width: 96, height: 160)
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10, preferredTimescale: 600)
      )
    )
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10.1, preferredTimescale: 600)
      )
    )

    let result = try await recorder.finish()
    let asset = AVURLAsset(url: result.outputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let videoTrack = try #require(tracks.first)
    let naturalSize = try await videoTrack.load(.naturalSize)
    let videoFormats = try await videoTrack.load(.formatDescriptions)
    let duration = try await asset.load(.duration)

    #expect(result.outputURL == outputURL)
    #expect(tracks.count == 1)
    #expect(naturalSize == canvas)
    #expect(videoFormats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
    #expect(duration.seconds >= 0.09)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
  }

  @Test("Fragmented Android PCM becomes timed stereo sample buffers")
  func buildsAndroidAudioSamples() throws {
    let builder = AndroidPCMSampleBuilder()
    let arrival = CMTime(seconds: 100, preferredTimescale: 48_000)

    #expect(try builder.append(Data([0, 0, 0]), arrivalTime: arrival).isEmpty)
    let samples = try builder.append(
      Data([0, 0, 0, 0, 0]),
      arrivalTime: arrival
    )
    let sample = try #require(samples.first?.sampleBuffer)
    let firstAnchor = try #require(samples.first?.hostClockAnchor)

    #expect(samples.count == 1)
    #expect(CMSampleBufferGetNumSamples(sample) == 2)
    #expect(firstAnchor.bufferEndTime == arrival)
    #expect(CMTimeCompare(sample.duration, CMTime(value: 2, timescale: 48_000)) == 0)
    #expect(
      CMTimeCompare(
        sample.presentationTimeStamp,
        arrival - CMTime(value: 2, timescale: 48_000)
      ) == 0
    )

    builder.resetTimeline()
    let restartedAt = CMTime(seconds: 102, preferredTimescale: 48_000)
    let restarted = try #require(
      builder.append(Data(repeating: 0, count: 4), arrivalTime: restartedAt).first
    )
    #expect(restarted.hostClockAnchor?.bufferEndTime == restartedAt)
    #expect(restarted.hostClockAnchor?.timelineID != firstAnchor.timelineID)
    #expect(
      CMTimeCompare(
        restarted.sampleBuffer.presentationTimeStamp,
        restartedAt - CMTime(value: 1, timescale: 48_000)
      ) == 0
    )
  }

  @Test("A recording with PCM input produces synchronized AAC audio")
  func writesMP4WithAudio() async throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MirrorPhone-audio-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let canvas = CGSize(width: 96, height: 160)
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10, preferredTimescale: 48_000)
      )
    )
    let audio = try #require(
      AndroidPCMSampleBuilder().append(
        Data(repeating: 0, count: 48_000 * 3 / 10 * 4),
        arrivalTime: CMTime(seconds: 10.3, preferredTimescale: 48_000)
      ).first
    )
    recorder.receive(audio: audio)
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .green).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10.1, preferredTimescale: 48_000)
      )
    )
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10.2, preferredTimescale: 48_000)
      )
    )

    let result = try await recorder.finish()
    let asset = AVURLAsset(url: result.outputURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

    #expect(result.recordedAudio)
    #expect(audioTracks.count == 1)
    let audioFormats = try await audioTracks[0].load(.formatDescriptions)
    #expect(audioFormats.first.map(CMFormatDescriptionGetMediaSubType) == kAudioFormatMPEG4AAC)
    let audioDuration = try await audioTracks[0].load(.timeRange).duration.seconds
    let videoDuration = try await #require(
      asset.loadTracks(withMediaType: .video).first
    ).load(.timeRange).duration.seconds
    #expect(audioDuration >= 0.09)
    #expect(abs(videoDuration - audioDuration) <= 0.11)
  }

  @Test("Audio overlapping the first video frame starts in sync")
  func preservesAudioOverlappingSessionStart() async throws {
    let outputURL = temporaryMP4URL(prefix: "overlapping-audio-start")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let canvas = CGSize(width: 64, height: 64)
    let image = CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas))
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()

    // One coarse capture chunk spans 9.8...10.2. Recording starts at 10.0,
    // so its trailing 200 ms belongs in the file even though its PTS is earlier.
    let overlappingBuffer = try #require(
      AndroidPCMSampleBuilder().append(
        Data(repeating: 0, count: 48_000 * 4 / 10 * 4),
        arrivalTime: CMTime(seconds: 10.2, preferredTimescale: 48_000)
      ).first?.sampleBuffer
    )
    recorder.receive(audio: MirrorAudioSample(sampleBuffer: overlappingBuffer))
    for seconds in [10.0, 10.1, 10.2] {
      recorder.receive(
        video: MirrorVideoSample(
          image: image,
          presentationTime: CMTime(seconds: seconds, preferredTimescale: 48_000)
        )
      )
    }

    let result = try await recorder.finish()
    let asset = AVURLAsset(url: result.outputURL)
    let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let audioRange = try await audioTrack.load(.timeRange)

    #expect(result.recordedAudio)
    #expect(abs(audioRange.start.seconds) <= 1.0 / 48_000)
    #expect(audioRange.duration.seconds >= 0.19)
  }

  @Test("Android audio is rebased to the host clock when recording starts")
  func rebasesAndroidAudioAtRecordingStart() async throws {
    let outputURL = temporaryMP4URL(prefix: "android-audio-rebase")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let builder = AndroidPCMSampleBuilder()
    let pcm = Data(repeating: 0, count: 48_000 / 10 * 4)
    var latestAudio: MirrorAudioSample?
    // Deliberately amplify a 1% device/host rate difference accumulated while
    // the user mirrors for ten seconds before pressing Record. Audio sample
    // count alone is now 99 ms behind Android video's host-clock timeline.
    for chunk in 1...100 {
      latestAudio = try builder.append(
        pcm,
        arrivalTime: CMTime(
          seconds: 100 + Double(chunk) * 0.101,
          preferredTimescale: 48_000
        )
      ).first
    }

    let canvas = CGSize(width: 64, height: 64)
    let image = CIImage(color: .green).cropped(to: CGRect(origin: .zero, size: canvas))
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    recorder.receive(audio: try #require(latestAudio))
    for seconds in [110.0, 110.05, 110.1] {
      recorder.receive(
        video: MirrorVideoSample(
          image: image,
          presentationTime: CMTime(seconds: seconds, preferredTimescale: 48_000)
        )
      )
    }

    let result = try await recorder.finish()
    let audioTrack = try #require(
      try await AVURLAsset(url: result.outputURL).loadTracks(withMediaType: .audio).first
    )
    let audioRange = try await audioTrack.load(.timeRange)

    #expect(result.recordedAudio)
    #expect(abs(audioRange.start.seconds) <= 1.0 / 48_000)
    #expect(audioRange.duration.seconds >= 0.09)
  }

  @Test("Rotation is rendered into one fixed canvas with black bars")
  func rendersRotationWithLetterboxing() async throws {
    let outputURL = temporaryMP4URL(prefix: "rotation")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let canvas = CGSize(width: 96, height: 160)
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: canvas)),
        presentationTime: CMTime(seconds: 10, preferredTimescale: 600)
      )
    )
    recorder.receive(
      video: MirrorVideoSample(
        image: CIImage(color: .green).cropped(
          to: CGRect(x: 0, y: 0, width: 160, height: 96)
        ),
        presentationTime: CMTime(seconds: 10.1, preferredTimescale: 600)
      )
    )
    _ = try await recorder.finish()

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let rendered = try generator.copyCGImage(
      at: CMTime(seconds: 0.1, preferredTimescale: 600),
      actualTime: nil
    )
    let bar = try pixel(in: rendered, x: 48, y: 6)
    let center = try pixel(in: rendered, x: 48, y: 80)

    #expect(rendered.width == 96)
    #expect(rendered.height == 160)
    #expect(max(bar.red, bar.green, bar.blue) < 35)
    #expect(center.green > 80)
    #expect(center.green > center.red * 2)
  }

  @Test("Non-monotonic video is dropped and repeated finish calls agree")
  func dropsNonMonotonicVideoAndFinishesOnce() async throws {
    let outputURL = temporaryMP4URL(prefix: "monotonic")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let canvas = CGSize(width: 64, height: 64)
    let image = CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas))
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    for seconds in [10.0, 9.0, 10.1] {
      recorder.receive(
        video: MirrorVideoSample(
          image: image,
          presentationTime: CMTime(seconds: seconds, preferredTimescale: 600)
        )
      )
    }

    async let first = recorder.finish()
    async let second = recorder.finish()
    let (firstResult, secondResult) = try await (first, second)
    #expect(firstResult.outputURL == secondResult.outputURL)
    #expect(firstResult.droppedVideoFrameCount == 1)
    #expect(secondResult.droppedVideoFrameCount == 1)
  }

  @Test("Publishing replaces an existing destination only after success")
  func atomicallyPublishesOrPreservesDestination() async throws {
    let outputURL = temporaryMP4URL(prefix: "replace")
    let original = Data("existing destination".utf8)
    try original.write(to: outputURL)
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let canvas = CGSize(width: 64, height: 64)
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    let image = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: canvas))
    recorder.receive(
      video: MirrorVideoSample(image: image, presentationTime: CMTime(seconds: 1, preferredTimescale: 600))
    )
    recorder.receive(
      video: MirrorVideoSample(image: image, presentationTime: CMTime(seconds: 1.1, preferredTimescale: 600))
    )
    _ = try await recorder.finish()
    #expect(try Data(contentsOf: outputURL) != original)

    let preserved = Data("must survive failure".utf8)
    try preserved.write(to: outputURL)
    let failingRecorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try failingRecorder.start()
    do {
      _ = try await failingRecorder.finish()
      Issue.record("Finishing without a video frame should fail")
    } catch {
      #expect(error is MP4RecorderError)
    }
    #expect(try Data(contentsOf: outputURL) == preserved)
  }

  @Test("Audio overrun ends audio while video remains playable")
  func audioOverrunFallsBackToVideoOnly() async throws {
    let outputURL = temporaryMP4URL(prefix: "audio-overrun")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let canvas = CGSize(width: 64, height: 64)
    let image = CIImage(color: .blue).cropped(to: CGRect(origin: .zero, size: canvas))
    let recorder = try MP4Recorder(destinationURL: outputURL, canvasSize: canvas)
    try recorder.start()
    recorder.receive(
      video: MirrorVideoSample(image: image, presentationTime: CMTime(seconds: 10, preferredTimescale: 48_000))
    )
    let oversizedAudio = try #require(
      AndroidPCMSampleBuilder().append(
        Data(repeating: 0, count: 48_000 * 21 / 10 * 4),
        arrivalTime: CMTime(seconds: 12.1, preferredTimescale: 48_000)
      ).first
    )
    recorder.receive(audio: oversizedAudio)
    recorder.receive(
      video: MirrorVideoSample(image: image, presentationTime: CMTime(seconds: 10.1, preferredTimescale: 48_000))
    )

    let result = try await recorder.finish()
    let asset = AVURLAsset(url: result.outputURL)
    #expect(!result.recordedAudio)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
  }

  @Test("Stopping before the first video fails promptly even with queued audio")
  func queuedAudioWithoutVideoDoesNotHang() async throws {
    let outputURL = temporaryMP4URL(prefix: "audio-only-start")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let recorder = try MP4Recorder(
      destinationURL: outputURL,
      canvasSize: CGSize(width: 64, height: 64)
    )
    try recorder.start()
    let audio = try #require(
      AndroidPCMSampleBuilder().append(
        Data(repeating: 0, count: 4),
        arrivalTime: CMTime(seconds: 10, preferredTimescale: 48_000)
      ).first
    )
    recorder.receive(audio: audio)

    do {
      _ = try await recorder.finish()
      Issue.record("A recording without video should fail")
    } catch {
      #expect(error is MP4RecorderError)
    }
    #expect(!FileManager.default.fileExists(atPath: outputURL.path))
  }

  @Test("The recording tap forwards without retaining its sink")
  func recordingTapIsWeak() {
    let tap = MirrorRecordingTap()
    var sink: RecordingSinkProbe? = RecordingSinkProbe()
    weak let weakSink = sink
    tap.attach(sink!)
    tap.emit(
      video: MirrorVideoSample(
        image: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
        presentationTime: .zero
      )
    )
    #expect(sink?.videoCount == 1)
    #expect(sink?.audioStates == [.pending])

    sink = nil
    #expect(weakSink == nil)
    tap.setAudioState(.available)
  }

  private func temporaryMP4URL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("MirrorPhone-\(prefix)-\(UUID().uuidString).mp4")
  }

  private func pixel(in image: CGImage, x: Int, y: Int) throws -> RGBPixel {
    var bytes = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return RGBPixel(red: bytes[0], green: bytes[1], blue: bytes[2])
  }
}

private struct RGBPixel {
  let red: UInt8
  let green: UInt8
  let blue: UInt8
}

private final class RecordingSinkProbe: MirrorRecordingSink, @unchecked Sendable {
  private let lock = NSLock()
  private var storedVideoCount = 0
  private var storedAudioStates = [MirrorRecordingAudioState]()

  var videoCount: Int { lock.withLock { storedVideoCount } }
  var audioStates: [MirrorRecordingAudioState] { lock.withLock { storedAudioStates } }

  func receive(video sample: MirrorVideoSample) {
    lock.withLock { storedVideoCount += 1 }
  }

  func receive(audio sample: MirrorAudioSample) {}

  func audioStateChanged(_ state: MirrorRecordingAudioState) {
    lock.withLock { storedAudioStates.append(state) }
  }
}
