import AVFoundation
import Foundation

/// Locates the bundled scrcpy-style audio capturer that is launched on the
/// device with `app_process`.
enum AndroidAudioServer {
  /// Path the capturer is pushed to and executed from on the device.
  static let devicePath = "/data/local/tmp/mirrorphone-audio-server.jar"
  /// Fully-qualified entry point inside the dex jar.
  static let mainClass = "com.rockyshi.mirrorphone.AudioServer"
  /// The lowest Android release whose shell user may capture `REMOTE_SUBMIX`.
  static let minimumSDKInt = 30

  static var jarURL: URL? {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["MIRRORPHONE_ANDROID_AUDIO_JAR"],
      !override.isEmpty,
      fileManager.isReadableFile(atPath: override)
    {
      return URL(fileURLWithPath: override)
    }
    return Bundle.main.url(forResource: "mirrorphone-audio-server", withExtension: "jar")
  }
}

/// Plays 48 kHz / stereo / 16-bit little-endian PCM delivered as raw byte
/// chunks through `AVAudioEngine`, resampling to the Mac's output device.
final class AndroidPCMAudioPlayer: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private let queue = DispatchQueue(label: "com.rockyshi.mirrorphone.android-audio-player")
  private var remainder = Data()
  private var running = false

  init?() {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
      return nil
    }
    self.format = format
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: format)
  }

  func start() -> Bool {
    queue.sync {
      guard !running else { return true }
      engine.prepare()
      do {
        try engine.start()
      } catch {
        return false
      }
      playerNode.play()
      running = true
      return true
    }
  }

  func stop() {
    queue.sync {
      guard running else { return }
      playerNode.stop()
      engine.stop()
      remainder.removeAll(keepingCapacity: false)
      running = false
    }
  }

  func enqueue(_ data: Data) {
    queue.async { [self] in
      guard running else { return }
      var bytes = remainder
      bytes.append(data)
      let frameBytes = 4 // stereo * 16-bit
      let usable = bytes.count - (bytes.count % frameBytes)
      guard usable > 0 else {
        remainder = bytes
        return
      }
      let frameCount = usable / frameBytes
      remainder = Data(bytes.suffix(bytes.count - usable))

      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let left = buffer.floatChannelData?[0],
        let right = buffer.floatChannelData?[1]
      else { return }
      buffer.frameLength = AVAudioFrameCount(frameCount)

      bytes.prefix(usable).withUnsafeBytes { raw in
        let scale = Float(1) / 32_768
        for frame in 0..<frameCount {
          let base = frame * frameBytes
          let l = Int16(bitPattern: UInt16(raw[base]) | (UInt16(raw[base + 1]) << 8))
          let r = Int16(bitPattern: UInt16(raw[base + 2]) | (UInt16(raw[base + 3]) << 8))
          left[frame] = Float(l) * scale
          right[frame] = Float(r) * scale
        }
      }
      playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
  }
}

/// Captures the Android device's output audio over ADB (scrcpy-style) and plays
/// it on the Mac. Failures are non-fatal: video mirroring keeps running and the
/// runner reports why audio is unavailable instead of throwing.
final class AndroidAudioRunner: @unchecked Sendable {
  typealias StatusHandler = @Sendable (String) -> Void

  private let adbURL: URL
  private let serial: String
  private let onStatus: StatusHandler
  private let queue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.android-audio",
    qos: .userInitiated
  )
  private let player = AndroidPCMAudioPlayer()
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var errorOutput = Data()
  private var activeLaunchID: UUID?
  private var attemptsRemaining = 3
  private var receivedByteCount = 0
  private var stopped = true

  /// A launch that streamed at least this much PCM (~10 s) counts as healthy
  /// and refills the retry budget, so a hiccup late in a long session does not
  /// permanently give up on audio.
  private static let healthyLaunchByteCount = 2_000_000

  init(adbURL: URL, serial: String, onStatus: @escaping StatusHandler) {
    self.adbURL = adbURL
    self.serial = serial
    self.onStatus = onStatus
  }

  func start() {
    queue.async { [self] in
      guard stopped else { return }
      stopped = false

      guard let player, player.start() else {
        onStatus("Android audio is unavailable · this Mac has no usable audio output.")
        stopped = true
        return
      }
      guard let jarURL = AndroidAudioServer.jarURL else {
        onStatus("Android audio is unavailable · rebuild MirrorPhone with the Android SDK present.")
        stopped = true
        return
      }
      guard deviceSupportsAudioCapture() else {
        onStatus("Android audio needs Android 11 or newer · mirroring video only.")
        stopped = true
        return
      }
      guard pushServer(jarURL) else {
        onStatus("Android audio is unavailable · could not stage the capturer on the device.")
        stopped = true
        return
      }
      _ = player // retained for the lifetime of streaming
      launch()
    }
  }

  func stop() {
    queue.sync {
      stopped = true
      activeLaunchID = nil
      outputPipe?.fileHandleForReading.readabilityHandler = nil
      errorPipe?.fileHandleForReading.readabilityHandler = nil
      if let process, process.isRunning {
        process.terminate()
      }
      process = nil
      outputPipe = nil
      errorPipe = nil
      errorOutput.removeAll(keepingCapacity: false)
      player?.stop()
    }
  }

  private func deviceSupportsAudioCapture() -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = adbURL
    process.arguments = ["-s", serial, "exec-out", "getprop", "ro.build.version.sdk"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard
      let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let sdkInt = Int(text)
    else { return false }
    return sdkInt >= AndroidAudioServer.minimumSDKInt
  }

  private func pushServer(_ jarURL: URL) -> Bool {
    let process = Process()
    process.executableURL = adbURL
    process.arguments = [
      "-s", serial, "push", jarURL.path, AndroidAudioServer.devicePath,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  private func launch() {
    guard !stopped, process == nil else { return }

    let launchID = UUID()
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    errorOutput.removeAll(keepingCapacity: true)
    receivedByteCount = 0
    activeLaunchID = launchID
    process.executableURL = adbURL
    process.arguments = [
      "-s", serial, "exec-out",
      "CLASSPATH=\(AndroidAudioServer.devicePath)",
      "app_process", "/", AndroidAudioServer.mainClass,
    ]
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeLaunchID == launchID, !stopped else { return }
        receivedByteCount += data.count
        player?.enqueue(data)
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeLaunchID == launchID else { return }
        errorOutput.append(data)
        if errorOutput.count > 8_192 {
          errorOutput.removeFirst(errorOutput.count - 8_192)
        }
      }
    }
    process.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      self?.queue.async { [weak self] in
        self?.processEnded(launchID: launchID, status: status)
      }
    }

    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    do {
      try process.run()
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      self.process = nil
      self.outputPipe = nil
      self.errorPipe = nil
      activeLaunchID = nil
      onStatus("Android audio failed to start: \(error.localizedDescription)")
    }
  }

  private func processEnded(launchID: UUID, status: Int32) {
    guard activeLaunchID == launchID else { return }
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    outputPipe = nil
    errorPipe = nil
    activeLaunchID = nil
    guard !stopped else { return }

    if receivedByteCount >= Self.healthyLaunchByteCount {
      attemptsRemaining = 3
    }
    attemptsRemaining -= 1
    guard attemptsRemaining > 0 else {
      let detail = String(data: errorOutput, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let detail, !detail.isEmpty {
        onStatus("Android audio stopped: \(detail)")
      } else {
        onStatus("Android audio stopped · mirroring video only.")
      }
      stopped = true
      player?.stop()
      return
    }

    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !stopped, process == nil else { return }
      launch()
    }
  }
}
