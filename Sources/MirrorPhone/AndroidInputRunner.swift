import Foundation

/// Locates the bundled scrcpy-style touch injector that is launched on the
/// device with `app_process`.
enum AndroidInputServer {
  /// Path the injector is pushed to and executed from on the device.
  static let devicePath = "/data/local/tmp/mirrorphone-input-server.jar"
  /// Fully-qualified entry point inside the dex jar.
  static let mainClass = "com.rockyshi.mirrorphone.InputServer"
  /// The dex jar is compiled with `--min-api 30`.
  static let minimumSDKInt = 30

  static var jarURL: URL? {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["MIRRORPHONE_ANDROID_INPUT_JAR"],
      !override.isEmpty,
      fileManager.isReadableFile(atPath: override)
    {
      return URL(fileURLWithPath: override)
    }
    return Bundle.main.url(forResource: "mirrorphone-input-server", withExtension: "jar")
  }
}

/// Forwards Mac mouse gestures to the Android device as touch events
/// (scrcpy-style, over the injector's stdin). Failures are non-fatal: video
/// mirroring keeps running and the runner reports why touch is unavailable.
final class AndroidInputRunner: @unchecked Sendable {
  typealias StatusHandler = @Sendable (String) -> Void

  private let adbURL: URL
  private let serial: String
  private let onStatus: StatusHandler
  /// Fired when the injector dies unexpectedly, so the UI can abandon any
  /// in-flight gesture instead of continuing it against a fresh server.
  private let onInterrupted: @Sendable () -> Void
  private let queue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.android-input",
    qos: .userInteractive
  )
  private var process: Process?
  private var stdinPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var errorOutput = Data()
  private var activeLaunchID: UUID?
  private var attemptsRemaining = 3
  private var launchedAt: Date?
  private var ready = false
  private var pending = [String]()
  private var stopped = true

  /// A launch that survived this long counts as healthy and refills the retry
  /// budget, so a hiccup late in a long session does not permanently give up.
  private static let healthyLaunchDuration: TimeInterval = 30
  private static let pendingLimit = 64

  init(
    adbURL: URL,
    serial: String,
    onStatus: @escaping StatusHandler,
    onInterrupted: @escaping @Sendable () -> Void
  ) {
    self.adbURL = adbURL
    self.serial = serial
    self.onStatus = onStatus
    self.onInterrupted = onInterrupted
  }

  func start() {
    queue.async { [self] in
      guard stopped else { return }
      stopped = false

      guard let jarURL = AndroidInputServer.jarURL else {
        onStatus("Android touch forwarding is unavailable · rebuild MirrorPhone with the Android SDK present.")
        stopped = true
        return
      }
      guard deviceSupportsInjection() else {
        onStatus("Android touch forwarding needs Android 11 or newer · mirroring is view-only.")
        stopped = true
        return
      }
      guard pushServer(jarURL) else {
        onStatus("Android touch forwarding is unavailable · could not stage the injector on the device.")
        stopped = true
        return
      }
      launch()
    }
  }

  func stop() {
    queue.sync {
      stopped = true
      activeLaunchID = nil
      pending.removeAll(keepingCapacity: false)
      outputPipe?.fileHandleForReading.readabilityHandler = nil
      errorPipe?.fileHandleForReading.readabilityHandler = nil
      // Closing stdin first lets the injector see EOF, cancel any stuck
      // finger, and exit on its own before the terminate() below.
      try? stdinPipe?.fileHandleForWriting.close()
      if let process, process.isRunning {
        process.terminate()
      }
      process = nil
      stdinPipe = nil
      outputPipe = nil
      errorPipe = nil
      errorOutput.removeAll(keepingCapacity: false)
    }
  }

  /// Coordinates are in pixels of a `frameWidth`×`frameHeight` video frame;
  /// the device-side injector rescales them to the real display.
  func send(_ phase: TouchPhase, x: Int, y: Int, frameWidth: Int, frameHeight: Int) {
    let line: String
    switch phase {
    case .down: line = "d \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .move: line = "m \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .up: line = "u \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .cancel: line = "c\n"
    }
    write(line)
  }

  /// `keycode` is an android.view.KeyEvent code; `metaState` Android meta flags.
  func sendKey(down: Bool, keycode: Int, metaState: Int) {
    write("k \(down ? "d" : "u") \(keycode) \(metaState)\n")
  }

  /// Types text on the device via KeyCharacterMap (hardware-keyboard style).
  func sendText(_ text: String) {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard !text.isEmpty,
      let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed)
    else { return }
    write("t \(encoded)\n")
  }

  private func write(_ line: String) {
    queue.async { [self] in
      guard !stopped else { return }
      guard ready, let handle = stdinPipe?.fileHandleForWriting else {
        // Buffer briefly while the injector is still starting up.
        if pending.count < Self.pendingLimit {
          pending.append(line)
        }
        return
      }
      do {
        try handle.write(contentsOf: Data(line.utf8))
      } catch {
        // The process died mid-write; terminationHandler drives the relaunch.
      }
    }
  }

  private func deviceSupportsInjection() -> Bool {
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
    return sdkInt >= AndroidInputServer.minimumSDKInt
  }

  private func pushServer(_ jarURL: URL) -> Bool {
    let process = Process()
    process.executableURL = adbURL
    process.arguments = [
      "-s", serial, "push", jarURL.path, AndroidInputServer.devicePath,
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
    let stdinPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    errorOutput.removeAll(keepingCapacity: true)
    // A gesture cannot meaningfully span a server restart, so drop anything
    // queued against the previous launch.
    pending.removeAll(keepingCapacity: true)
    ready = false
    activeLaunchID = launchID
    launchedAt = Date()
    process.executableURL = adbURL
    // `adb shell` (not `exec-out`) because only the shell transport forwards
    // our stdin to the device; exec-out is stdout-only, like the audio path.
    process.arguments = [
      "-s", serial, "shell",
      "CLASSPATH=\(AndroidInputServer.devicePath)",
      "app_process", "/", AndroidInputServer.mainClass,
    ]
    process.standardInput = stdinPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeLaunchID == launchID, !stopped, !ready else { return }
        if String(data: data, encoding: .utf8)?.contains("READY") == true {
          ready = true
          let queued = pending
          pending.removeAll(keepingCapacity: false)
          guard let handle = self.stdinPipe?.fileHandleForWriting else { return }
          for line in queued {
            try? handle.write(contentsOf: Data(line.utf8))
          }
        }
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
    self.stdinPipe = stdinPipe
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    do {
      try process.run()
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      self.process = nil
      self.stdinPipe = nil
      self.outputPipe = nil
      self.errorPipe = nil
      activeLaunchID = nil
      onStatus("Android touch forwarding failed to start: \(error.localizedDescription)")
    }
  }

  private func processEnded(launchID: UUID, status: Int32) {
    guard activeLaunchID == launchID else { return }
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    stdinPipe = nil
    outputPipe = nil
    errorPipe = nil
    activeLaunchID = nil
    ready = false
    pending.removeAll(keepingCapacity: false)
    guard !stopped else { return }

    onInterrupted()

    if let launchedAt, Date().timeIntervalSince(launchedAt) >= Self.healthyLaunchDuration {
      attemptsRemaining = 3
    }
    attemptsRemaining -= 1
    guard attemptsRemaining > 0 else {
      let detail = String(data: errorOutput, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let detail, !detail.isEmpty {
        onStatus("Android touch forwarding stopped: \(detail)")
      } else {
        onStatus("Android touch forwarding stopped · mirroring is view-only.")
      }
      stopped = true
      return
    }

    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !stopped, process == nil else { return }
      launch()
    }
  }
}
