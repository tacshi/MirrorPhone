@preconcurrency import AVFoundation
import AppKit
import CoreImage

@MainActor
final class AVCaptureMirrorSource: NSObject, MirrorSource,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?

  private let uniqueID: String
  private nonisolated let session = AVCaptureSession()
  private nonisolated let audioPreviewOutput = AVCaptureAudioPreviewOutput()
  private nonisolated let captureQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.av-capture",
    qos: .userInteractive
  )
  private nonisolated let imageContext = CIContext(options: [.cacheIntermediates: false])

  init(uniqueID: String) {
    self.uniqueID = uniqueID
    super.init()
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

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch let error as AVError where error.code == .applicationIsNotAuthorizedToUseDevice {
      throw MirrorPhoneError.cameraPermission
    }

    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    // iPhone and iPad screen devices expose a muxed native format that does
    // not permit callers to force a pixel format. Let AVFoundation choose its
    // default uncompressed output so the capture graph can perform conversion.
    output.videoSettings = nil
    output.setSampleBufferDelegate(self, queue: captureQueue)

    session.beginConfiguration()
    session.sessionPreset = .high
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
    session.commitConfiguration()

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
  }

  nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
    Task { @MainActor [weak self] in
      self?.onFrame?(frame)
    }
  }
}
