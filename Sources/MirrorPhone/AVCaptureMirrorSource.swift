@preconcurrency import AVFoundation
import AppKit
import CoreImage

struct AVCaptureQualityPresetChoice: Equatable, Sendable {
  let level: MirrorQualityLevel
  let preset: AVCaptureSession.Preset
}

enum AVCaptureQualityPresetResolver {
  static let candidates: [MirrorQualityLevel: [AVCaptureSession.Preset]] = [
    .quality: [.high],
    .balanced: [.hd1920x1080, .medium],
    .performance: [.hd1280x720, .low],
  ]

  static func supportedLevels(
    in presets: Set<AVCaptureSession.Preset>
  ) -> Set<MirrorQualityLevel> {
    Set(candidates.compactMap { level, candidates in
      candidates.contains(where: presets.contains) ? level : nil
    })
  }

  static func resolve(
    _ requested: MirrorQualityLevel,
    supportedPresets: Set<AVCaptureSession.Preset>
  ) -> AVCaptureQualityPresetChoice? {
    let fallbackOrder: [MirrorQualityLevel]
    switch requested {
    case .quality:
      fallbackOrder = [.quality, .balanced, .performance]
    case .balanced:
      fallbackOrder = [.balanced, .performance, .quality]
    case .performance:
      fallbackOrder = [.performance, .balanced, .quality]
    }

    for level in fallbackOrder {
      for preset in candidates[level, default: []] where supportedPresets.contains(preset) {
        return AVCaptureQualityPresetChoice(level: level, preset: preset)
      }
    }
    return nil
  }

  static var allPresets: Set<AVCaptureSession.Preset> {
    Set(candidates.values.flatMap { $0 })
  }
}

@MainActor
final class AVCaptureMirrorSource: NSObject, RecordableMirrorSource, QualityAdjustableMirrorSource,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  nonisolated let recordingTap = MirrorRecordingTap()
  private let qualityController = MirrorQualityController()
  var qualityState: MirrorQualityState { qualityController.state }
  var onQualityStateChanged: ((MirrorQualityState) -> Void)? {
    get { qualityController.onStateChanged }
    set {
      qualityController.onStateChanged = newValue
      newValue?(qualityController.state)
    }
  }

  private let uniqueID: String
  private nonisolated let session = AVCaptureSession()
  private nonisolated let audioPreviewOutput = AVCaptureAudioPreviewOutput()
  private nonisolated let audioDataOutput = AVCaptureAudioDataOutput()
  private nonisolated let captureQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.av-capture",
    qos: .userInteractive
  )
  private nonisolated let displayQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.av-display",
    qos: .userInteractive
  )
  private nonisolated let imageContext = CIContext(options: [.cacheIntermediates: false])
  private nonisolated let displayLock = NSLock()
  private nonisolated let qualityApplyLock = NSLock()
  private nonisolated(unsafe) var pendingDisplayImage: CIImage?
  private nonisolated(unsafe) var displayScheduled = false
  private nonisolated(unsafe) var latestQualityGeneration = 0
  private nonisolated(unsafe) var pressureMeter: MirrorFramePressureMeter?
  private var supportedQualityPresets = Set<AVCaptureSession.Preset>()

  init(uniqueID: String) {
    self.uniqueID = uniqueID
    super.init()
    pressureMeter = MirrorFramePressureMeter { [weak self] window in
      Task { @MainActor [weak self] in
        guard let self, let level = qualityController.observe(window) else { return }
        applyQualityLevel(level)
      }
    }
  }

  func setQualityMode(_ mode: MirrorQualityMode) {
    guard let level = qualityController.setMode(mode) else { return }
    applyQualityLevel(level)
  }

  func start() async throws {
    guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
      throw MirrorPhoneError.sourceUnavailable("The wired video device disconnected.")
    }

    let authorized: Bool
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      authorized = true
    case .notDetermined:
      authorized = await AVCaptureDevice.requestAccess(for: .video)
    default:
      authorized = false
    }
    guard authorized else { throw MirrorPhoneError.cameraPermission }

    // The iPhone/iPad screen device delivers its system audio on a muxed audio
    // port. macOS gates that port behind microphone authorization, so request
    // it opportunistically; a denial only mutes playback, it must not stop the
    // video mirror from running.
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    let audioAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    if audioAuthorized {
      recordingTap.setAudioState(.pending)
    } else {
      recordingTap.setAudioState(
        .unavailable("Microphone access is off, so this recording has no device audio.")
      )
    }

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch let error as AVError where error.code == .applicationIsNotAuthorizedToUseDevice {
      throw MirrorPhoneError.cameraPermission
    }

    let output = AVCaptureVideoDataOutput()
    // The delegate itself only hands frames to the recorder tap and a bounded
    // latest-frame display stage, so it can accept native cadence without
    // AVFoundation dropping frames before recording sees them.
    output.alwaysDiscardsLateVideoFrames = false
    // iPhone and iPad screen devices expose a muxed native format that does
    // not permit callers to force a pixel format. Let AVFoundation choose its
    // default uncompressed output so the capture graph can perform conversion.
    output.videoSettings = nil
    output.setSampleBufferDelegate(self, queue: captureQueue)
    audioDataOutput.setSampleBufferDelegate(self, queue: captureQueue)

    session.beginConfiguration()
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      throw MirrorPhoneError.sourceUnavailable("The wired video source could not be configured.")
    }
    session.addInput(input)
    session.addOutput(output)
    // Route the muxed device's audio track to the default system output so the
    // phone's sound plays through the Mac's speakers, mirroring QuickTime's
    // behaviour. Adding it is best-effort: keep mirroring even if the audio
    // port is unavailable (e.g. microphone access was denied).
    audioPreviewOutput.volume = 1.0
    if session.canAddOutput(audioPreviewOutput) {
      session.addOutput(audioPreviewOutput)
    }
    if audioAuthorized, session.canAddOutput(audioDataOutput) {
      session.addOutput(audioDataOutput)
    } else if audioAuthorized {
      recordingTap.setAudioState(
        .unavailable("This wired source does not expose recordable device audio.")
      )
    }

    let supportedPresets = Set(
      AVCaptureQualityPresetResolver.allPresets.filter { session.canSetSessionPreset($0) }
    )
    let supportedLevels = AVCaptureQualityPresetResolver.supportedLevels(in: supportedPresets)
    guard !supportedLevels.isEmpty else {
      session.commitConfiguration()
      throw MirrorPhoneError.sourceUnavailable(
        "The wired video source does not support a usable capture quality."
      )
    }
    supportedQualityPresets = supportedPresets
    _ = qualityController.setSupportedLevels(
      supportedLevels,
      limitation: qualityLimitation(supportedLevels: supportedLevels)
    )
    guard let effectiveLevel = qualityController.state.effectiveLevel,
      let choice = AVCaptureQualityPresetResolver.resolve(
        effectiveLevel,
        supportedPresets: supportedPresets
      )
    else {
      session.commitConfiguration()
      throw MirrorPhoneError.sourceUnavailable(
        "The wired video source does not support the selected capture quality."
      )
    }
    session.sessionPreset = choice.preset
    session.commitConfiguration()
    qualityController.markApplied(
      limitation: qualityLimitation(supportedLevels: supportedLevels)
    )

    let captureSession = session
    captureQueue.async {
      captureSession.startRunning()
    }
    onStatus?("Mirroring \(device.localizedName)")
  }

  func stop() async {
    let captureSession = session
    await withCheckedContinuation { continuation in
      captureQueue.async {
        if captureSession.isRunning {
          captureSession.stopRunning()
        }
        continuation.resume()
      }
    }
    pressureMeter?.reset()
  }

  nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output === audioDataOutput {
      recordingTap.setAudioState(.available)
      recordingTap.emit(audio: MirrorAudioSample(sampleBuffer: sampleBuffer))
      return
    }
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
    pressureMeter?.recordSourceFrame()
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    recordingTap.emit(
      video: MirrorVideoSample(
        image: image,
        presentationTime: sampleBuffer.presentationTimeStamp
      )
    )
    scheduleDisplay(image)
  }

  private nonisolated func scheduleDisplay(_ image: CIImage) {
    displayLock.lock()
    pendingDisplayImage = image
    let alreadyScheduled = displayScheduled
    displayScheduled = true
    displayLock.unlock()
    if alreadyScheduled {
      pressureMeter?.recordDisplayReplacement()
    }
    guard !alreadyScheduled else { return }

    displayQueue.async { [weak self] in
      guard let self else { return }
      displayLock.lock()
      let image = pendingDisplayImage
      pendingDisplayImage = nil
      displayScheduled = false
      displayLock.unlock()
      guard let image else { return }
      let renderStartedAt = ProcessInfo.processInfo.systemUptime
      guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
      pressureMeter?.recordRender(
        duration: ProcessInfo.processInfo.systemUptime - renderStartedAt
      )
      Task { @MainActor [weak self] in
        self?.onFrame?(frame)
      }
    }
  }

  private func applyQualityLevel(_ level: MirrorQualityLevel) {
    guard !supportedQualityPresets.isEmpty,
      let choice = AVCaptureQualityPresetResolver.resolve(
        level,
        supportedPresets: supportedQualityPresets
      )
    else { return }

    qualityApplyLock.lock()
    latestQualityGeneration += 1
    let generation = latestQualityGeneration
    qualityApplyLock.unlock()

    let captureSession = session
    let qualityApplyLock = qualityApplyLock
    captureQueue.async { [weak self] in
      qualityApplyLock.lock()
      let isLatest = self?.latestQualityGeneration == generation
      qualityApplyLock.unlock()
      guard isLatest else { return }

      captureSession.beginConfiguration()
      guard captureSession.canSetSessionPreset(choice.preset) else {
        captureSession.commitConfiguration()
        Task { @MainActor [weak self] in
          guard let self else { return }
          supportedQualityPresets.remove(choice.preset)
          let levels = AVCaptureQualityPresetResolver.supportedLevels(
            in: supportedQualityPresets
          )
          guard !levels.isEmpty else {
            qualityController.markAdjustmentFailed(
              "This wired source stopped supporting \(level.title)."
            )
            return
          }
          _ = qualityController.setSupportedLevels(
            levels,
            limitation: qualityLimitation(supportedLevels: levels)
          )
          if let fallback = qualityController.state.effectiveLevel {
            applyQualityLevel(fallback)
          } else {
            qualityController.markApplied(
              limitation: qualityLimitation(supportedLevels: levels)
            )
          }
        }
        return
      }
      captureSession.sessionPreset = choice.preset
      captureSession.commitConfiguration()

      qualityApplyLock.lock()
      let remainedLatest = self?.latestQualityGeneration == generation
      qualityApplyLock.unlock()
      guard remainedLatest else { return }
      self?.pressureMeter?.reset()
      Task { @MainActor [weak self] in
        guard let self else { return }
        qualityController.markApplied(
          limitation: qualityLimitation(
            supportedLevels: AVCaptureQualityPresetResolver.supportedLevels(
              in: supportedQualityPresets
            )
          )
        )
        onStatus?("Capture quality · \(choice.level.title)")
      }
    }
  }

  private func qualityLimitation(
    supportedLevels: Set<MirrorQualityLevel>
  ) -> String? {
    guard supportedLevels.count < MirrorQualityLevel.allCases.count else { return nil }
    let available = MirrorQualityLevel.allCases
      .filter(supportedLevels.contains)
      .map(\.title)
    if available.count == 1, let profile = available.first {
      return "This wired source supports only the \(profile) profile."
    }
    return "This wired source supports only: \(available.joined(separator: ", "))."
  }
}
