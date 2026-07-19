import CoreGraphics
import Foundation
import ImageIO

struct AndroidADBDevice: Equatable, Sendable {
  let serial: String
  let name: String
}

enum AndroidADB {
  static var executableURL: URL? {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    let home = fileManager.homeDirectoryForCurrentUser.path
    var candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb").path,
      "\(home)/Library/Android/sdk/platform-tools/adb",
      "/opt/homebrew/bin/adb",
      "/usr/local/bin/adb",
    ]

    for variable in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
      if let root = environment[variable], !root.isEmpty {
        candidates.insert("\(root)/platform-tools/adb", at: 1)
      }
    }
    if let path = environment["PATH"] {
      candidates.append(
        contentsOf: path.split(separator: ":").map { "\($0)/adb" }
      )
    }

    return candidates.lazy
      .map { URL(fileURLWithPath: $0) }
      .first { fileManager.isExecutableFile(atPath: $0.path) }
  }

  static func connectedDevices() async -> [AndroidADBDevice] {
    guard let executableURL else { return [] }
    return await Task.detached(priority: .utility) {
      let process = Process()
      let output = Pipe()
      process.executableURL = executableURL
      process.arguments = ["devices", "-l"]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice

      do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parseDeviceList(text)
      } catch {
        return []
      }
    }.value
  }

  static func parseDeviceList(_ output: String) -> [AndroidADBDevice] {
    output.split(whereSeparator: \Character.isNewline).compactMap { line in
      let fields = line.split(whereSeparator: \Character.isWhitespace)
      guard fields.count >= 2, fields[1] == "device" else { return nil }

      let serial = String(fields[0])
      let attributes = Dictionary(
        uniqueKeysWithValues: fields.dropFirst(2).compactMap { field -> (String, String)? in
          let pair = field.split(separator: ":", maxSplits: 1)
          guard pair.count == 2 else { return nil }
          return (String(pair[0]), String(pair[1]))
        }
      )
      let model = attributes["model"]?.replacingOccurrences(of: "_", with: " ")
      return AndroidADBDevice(serial: serial, name: model ?? "Android \(serial)")
    }
  }
}

struct ADBTrackDevicesParser {
  private var buffer = Data()

  mutating func append(_ data: Data) -> [[AndroidADBDevice]] {
    buffer.append(data)
    var snapshots = [[AndroidADBDevice]]()

    while buffer.count >= 4 {
      let lengthData = Data(buffer.prefix(4))
      guard let lengthText = String(data: lengthData, encoding: .utf8),
        let payloadLength = Int(lengthText, radix: 16)
      else {
        buffer.removeAll()
        return snapshots
      }
      guard buffer.count >= 4 + payloadLength else { break }

      let payload = Data(buffer.dropFirst(4).prefix(payloadLength))
      buffer.removeFirst(4 + payloadLength)
      let text = String(data: payload, encoding: .utf8) ?? ""
      snapshots.append(AndroidADB.parseDeviceList(text))
    }

    return snapshots
  }
}

struct AndroidRotationLogParser {
  private static let marker = "Display id=0 rotation changed to "
  private var buffer = Data()

  mutating func append(_ data: Data) -> [Int] {
    buffer.append(data)
    var rotations = [Int]()

    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
      buffer.removeSubrange(...newline)
      if let rotation = Self.rotation(in: line) {
        rotations.append(rotation)
      }
    }

    if buffer.count > 16_384 {
      buffer.removeFirst(buffer.count - 16_384)
    }
    return rotations
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
  }

  static func rotation(in line: String) -> Int? {
    guard let markerRange = line.range(of: marker),
      let value = line[markerRange.upperBound...].first?.wholeNumberValue,
      (0...3).contains(value)
    else { return nil }
    return value
  }
}

struct AndroidDisplaySize: Equatable, Sendable {
  let width: Int
  let height: Int

  static func parseWMSize(_ output: String) -> AndroidDisplaySize? {
    let sizes: [AndroidDisplaySize] = output.split(whereSeparator: \Character.isNewline).compactMap {
      line -> AndroidDisplaySize? in
      guard let colon = line.lastIndex(of: ":") else { return nil }
      let dimensions = String(line[line.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
        .split(separator: "x", maxSplits: 1)
      guard dimensions.count == 2,
        let width = Int(dimensions[0]), let height = Int(dimensions[1]),
        width > 0, height > 0
      else { return nil }
      return AndroidDisplaySize(width: width, height: height)
    }
    // `wm size` prints the physical size first and an override second. The
    // override is the size screenrecord actually sees, so prefer the last one.
    return sizes.last
  }

  /// A conservative AVC size for vendor encoders which reject the native
  /// display resolution. Preserve the display aspect ratio while keeping the
  /// short edge at 1080 and the long edge at 1920 or less.
  var screenrecordFallback: AndroidDisplaySize {
    let shortEdge = min(width, height)
    let longEdge = max(width, height)
    var scale = min(1, min(1080.0 / Double(shortEdge), 1920.0 / Double(longEdge)))
    if scale == 1 {
      scale = 0.75
    }

    func encoderAligned(_ value: Int) -> Int {
      max(2, Int((Double(value) * scale).rounded(.down)) / 2 * 2)
    }
    return AndroidDisplaySize(width: encoderAligned(width), height: encoderAligned(height))
  }
}

enum AndroidVideoCompatibility {
  /// iReader's Smart X3 Pro `screenrecord` encoder emits its initial frame but
  /// never sees later e-ink compositor refreshes. Direct framebuffer captures
  /// are the only ADB path that continues to reflect the live display.
  static func requiresFramebufferPolling(deviceName: String) -> Bool {
    deviceName.localizedCaseInsensitiveContains("Smart X3 Pro")
  }
}

final class AndroidADBDeviceMonitor: @unchecked Sendable {
  typealias DevicesHandler = @Sendable ([AndroidADBDevice]) -> Void

  private let queue = DispatchQueue(label: "com.rockyshi.mirrorphone.adb-device-events")
  private let onDevicesChanged: DevicesHandler
  private var process: Process?
  private var outputPipe: Pipe?
  private var activeLaunchID: UUID?
  private var reconnectWorkItem: DispatchWorkItem?
  private var parser = ADBTrackDevicesParser()
  private var stopped = true

  init(onDevicesChanged: @escaping DevicesHandler) {
    self.onDevicesChanged = onDevicesChanged
  }

  func start() {
    queue.async { [weak self] in
      guard let self, stopped else { return }
      stopped = false
      launch()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      stopped = true
      reconnectWorkItem?.cancel()
      reconnectWorkItem = nil
      activeLaunchID = nil
      outputPipe?.fileHandleForReading.readabilityHandler = nil
      if let process, process.isRunning {
        process.terminate()
      }
      process = nil
      outputPipe = nil
      parser = ADBTrackDevicesParser()
    }
  }

  private func launch() {
    guard !stopped, process == nil else { return }
    guard let executableURL = AndroidADB.executableURL else {
      onDevicesChanged([])
      scheduleReconnect()
      return
    }

    let launchID = UUID()
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = ["track-devices", "-l"]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    parser = ADBTrackDevicesParser()
    activeLaunchID = launchID

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeLaunchID == launchID, !stopped else { return }
        for devices in parser.append(data) {
          onDevicesChanged(devices)
        }
      }
    }
    process.terminationHandler = { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.processEnded(launchID: launchID)
      }
    }

    self.process = process
    self.outputPipe = outputPipe
    do {
      try process.run()
    } catch {
      processEnded(launchID: launchID)
    }
  }

  private func processEnded(launchID: UUID) {
    guard activeLaunchID == launchID else { return }
    activeLaunchID = nil
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    process = nil
    parser = ADBTrackDevicesParser()
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard !stopped, reconnectWorkItem == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      reconnectWorkItem = nil
      launch()
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 1, execute: workItem)
  }
}

@MainActor
final class AndroidADBMirrorSource: MirrorSource, DeviceInputSink {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  /// Fired when the input injector dies unexpectedly, so the UI can abandon any
  /// in-flight gesture instead of continuing it against a fresh server.
  var onInputInterrupted: (() -> Void)?

  private let serial: String
  private let deviceName: String
  private var runner: (any AndroidVideoRunner)?
  private var audioRunner: AndroidAudioRunner?
  private var inputRunner: AndroidInputRunner?

  init(serial: String, deviceName: String) {
    self.serial = serial
    self.deviceName = deviceName
  }

  var inputSink: DeviceInputSink? { self }

  func send(_ event: DeviceInputEvent) {
    switch event {
    case .touch(let touch):
      let point = touch.location.point(in: touch.referenceSize)
      inputRunner?.send(
        touch.phase,
        x: Int(point.x.rounded()),
        y: Int(point.y.rounded()),
        frameWidth: Int(touch.referenceSize.width.rounded()),
        frameHeight: Int(touch.referenceSize.height.rounded())
      )
    case .key(let key):
      guard let keycode = AndroidKeyMap.keycode(for: key.key) else { return }
      inputRunner?.sendKey(
        down: key.phase == .down,
        keycode: keycode,
        metaState: AndroidKeyMap.metaState(from: key.modifiers)
      )
    case .text(let text):
      inputRunner?.sendText(text)
    }
  }

  func start() async throws {
    guard let adbURL = AndroidADB.executableURL else {
      throw MirrorPhoneError.sourceUnavailable(
        "Android Platform Tools are unavailable. Rebuild MirrorPhone with adb installed."
      )
    }

    let frameHandler: @Sendable (CGImage) -> Void = { [weak self] frame in
      Task { @MainActor [weak self] in
        self?.onFrame?(frame)
      }
    }
    let statusHandler: @Sendable (String) -> Void = { [weak self] status in
      Task { @MainActor [weak self] in
        self?.onStatus?(status)
      }
    }
    let runner: any AndroidVideoRunner =
      if AndroidVideoCompatibility.requiresFramebufferPolling(deviceName: deviceName) {
        AndroidFramebufferRunner(
          adbURL: adbURL,
          serial: serial,
          onFrame: frameHandler,
          onStatus: statusHandler
        )
      } else {
        AndroidScreenrecordRunner(
          adbURL: adbURL,
          serial: serial,
          onFrame: frameHandler,
          onStatus: statusHandler
        )
      }
    try runner.start()
    self.runner = runner

    // `screenrecord` is video-only, so capture the device's output audio
    // separately (scrcpy-style) and play it on the Mac. This is best-effort:
    // the runner reports why sound is unavailable rather than failing the mirror.
    let audioRunner = AndroidAudioRunner(
      adbURL: adbURL,
      serial: serial,
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          self?.onStatus?(status)
        }
      }
    )
    audioRunner.start()
    self.audioRunner = audioRunner

    // Forward Mac mouse/scroll gestures to the device as touch events. Also
    // best-effort: touch is unavailable rather than failing the mirror.
    let inputRunner = AndroidInputRunner(
      adbURL: adbURL,
      serial: serial,
      onStatus: { [weak self] status in
        Task { @MainActor [weak self] in
          self?.onStatus?(status)
        }
      },
      onInterrupted: { [weak self] in
        Task { @MainActor [weak self] in
          self?.onInputInterrupted?()
        }
      }
    )
    inputRunner.start()
    self.inputRunner = inputRunner

    onStatus?("Connected to \(deviceName) by USB · waiting for video")
  }

  func stop() async {
    let runner = runner
    self.runner = nil
    audioRunner?.stop()
    audioRunner = nil
    inputRunner?.stop()
    inputRunner = nil
    await runner?.stop()
  }
}

private protocol AndroidVideoRunner: AnyObject, Sendable {
  func start() throws
  func stop() async
}

private final class AndroidScreenrecordRunner: AndroidVideoRunner, @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void

  private let adbURL: URL
  private let serial: String
  private let onStatus: StatusHandler
  private let queue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.android-adb",
    qos: .userInteractive
  )
  private let streamDecoder: AndroidH264StreamDecoder
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var errorOutput = Data()
  private var activeLaunchID: UUID?
  private var rotationProcess: Process?
  private var rotationPipe: Pipe?
  private var activeRotationLaunchID: UUID?
  private var rotationParser = AndroidRotationLogParser()
  private var lastRotation: Int?
  private var rotationRestartLaunchID: UUID?
  private var fallbackSize: AndroidDisplaySize?
  private var activeSize: AndroidDisplaySize?
  private var receivedVideoStream = false
  private var streamOutput = Data()
  private var stopped = true

  init(
    adbURL: URL,
    serial: String,
    onFrame: @escaping FrameHandler,
    onStatus: @escaping StatusHandler
  ) {
    self.adbURL = adbURL
    self.serial = serial
    self.onStatus = onStatus
    streamDecoder = AndroidH264StreamDecoder(onFrame: onFrame, onStatus: onStatus)
  }

  func start() throws {
    try queue.sync {
      guard stopped else { return }
      stopped = false
      do {
        fallbackSize = queryDisplaySize()?.screenrecordFallback
        try launch()
        try launchRotationMonitor()
      } catch {
        stopped = true
        stopProcesses()
        throw error
      }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        stopped = true
        activeLaunchID = nil
        activeRotationLaunchID = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        rotationPipe?.fileHandleForReading.readabilityHandler = nil
        stopProcesses()
        process = nil
        outputPipe = nil
        errorPipe = nil
        rotationProcess = nil
        rotationPipe = nil
        errorOutput.removeAll(keepingCapacity: false)
        rotationParser.reset()
        lastRotation = nil
        rotationRestartLaunchID = nil
        fallbackSize = nil
        activeSize = nil
        receivedVideoStream = false
        streamOutput.removeAll(keepingCapacity: false)
        streamDecoder.reset()
        continuation.resume()
      }
    }
  }

  private func launch() throws {
    let launchID = UUID()
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    streamDecoder.reset()
    errorOutput.removeAll(keepingCapacity: true)
    streamOutput.removeAll(keepingCapacity: true)
    receivedVideoStream = false
    activeLaunchID = launchID
    process.executableURL = adbURL
    var arguments = [
      "-s", serial,
      "exec-out", "screenrecord",
      "--output-format=h264",
      "--bit-rate", "12000000",
    ]
    if let activeSize {
      arguments.append(contentsOf: ["--size", "\(activeSize.width)x\(activeSize.height)"])
    }
    arguments.append("-")
    process.arguments = arguments
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
        if !receivedVideoStream, streamOutput.count < 16_384 {
          streamOutput.append(data.prefix(16_384 - streamOutput.count))
        }
        receivedVideoStream = streamDecoder.consume(data) || receivedVideoStream
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
        if errorOutput.count > 16_384 {
          errorOutput.removeFirst(errorOutput.count - 16_384)
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
      throw MirrorPhoneError.processFailed(
        "Could not start Android USB mirroring: \(error.localizedDescription)"
      )
    }
  }

  private func launchRotationMonitor() throws {
    guard !stopped, rotationProcess == nil else { return }

    let launchID = UUID()
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = adbURL
    process.arguments = [
      "-s", serial,
      "logcat", "-b", "system", "-v", "brief", "-T", "1",
      "WindowManager:I", "*:S",
    ]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    rotationParser.reset()
    activeRotationLaunchID = launchID

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeRotationLaunchID == launchID, !stopped else { return }
        for rotation in rotationParser.append(data) {
          handleRotation(rotation)
        }
      }
    }
    process.terminationHandler = { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.rotationMonitorEnded(launchID: launchID)
      }
    }

    rotationProcess = process
    rotationPipe = outputPipe
    do {
      try process.run()
    } catch {
      activeRotationLaunchID = nil
      rotationProcess = nil
      rotationPipe = nil
      throw MirrorPhoneError.processFailed(
        "Could not monitor Android rotation: \(error.localizedDescription)"
      )
    }
  }

  private func handleRotation(_ rotation: Int) {
    guard lastRotation != rotation else { return }
    lastRotation = rotation
    guard let activeLaunchID, let process, process.isRunning else { return }

    rotationRestartLaunchID = activeLaunchID
    onStatus("Rotating the Android video")
    process.terminate()
  }

  private func rotationMonitorEnded(launchID: UUID) {
    guard activeRotationLaunchID == launchID else { return }
    activeRotationLaunchID = nil
    rotationPipe?.fileHandleForReading.readabilityHandler = nil
    rotationPipe = nil
    rotationProcess = nil
    rotationParser.reset()
    guard !stopped else { return }

    queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, !stopped, rotationProcess == nil else { return }
      do {
        try launchRotationMonitor()
      } catch {
        onStatus(error.localizedDescription)
      }
    }
  }

  private func stopProcesses() {
    if let process, process.isRunning {
      process.terminate()
    }
    if let rotationProcess, rotationProcess.isRunning {
      rotationProcess.terminate()
    }
  }

  private func processEnded(launchID: UUID, status: Int32) {
    guard activeLaunchID == launchID else { return }
    let wasRotationRestart = rotationRestartLaunchID == launchID
    if wasRotationRestart {
      rotationRestartLaunchID = nil
    }
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    streamDecoder.finish()
    process = nil
    outputPipe = nil
    errorPipe = nil
    activeLaunchID = nil
    guard !stopped else { return }

    if wasRotationRestart {
      queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, !stopped, process == nil else { return }
        do {
          try launch()
        } catch {
          onStatus(error.localizedDescription)
        }
      }
      return
    }

    if !receivedVideoStream, activeSize == nil, let fallbackSize {
      activeSize = fallbackSize
      onStatus(
        "The Android encoder rejected native resolution · retrying at "
          + "\(fallbackSize.width) × \(fallbackSize.height)"
      )
      queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, !stopped, process == nil else { return }
        do {
          try launch()
        } catch {
          onStatus(error.localizedDescription)
        }
      }
      return
    }

    let diagnosticOutput = errorOutput.isEmpty ? streamOutput : errorOutput
    let detail = String(data: diagnosticOutput, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if status != 0, let detail, !detail.isEmpty {
      onStatus("Android USB stream ended: \(detail) · retrying")
    } else {
      onStatus("Refreshing the Android USB stream")
    }

    queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, !stopped, process == nil else { return }
      do {
        try launch()
      } catch {
        onStatus(error.localizedDescription)
      }
    }
  }

  private func queryDisplaySize() -> AndroidDisplaySize? {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = adbURL
    process.arguments = ["-s", serial, "shell", "wm", "size"]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0,
        let output = String(data: data, encoding: .utf8)
      else { return nil }
      return AndroidDisplaySize.parseWMSize(output)
    } catch {
      return nil
    }
  }
}

private final class AndroidFramebufferRunner: AndroidVideoRunner, @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void

  private let adbURL: URL
  private let serial: String
  private let onFrame: FrameHandler
  private let onStatus: StatusHandler
  private let queue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.android-framebuffer",
    qos: .userInteractive
  )
  private var process: Process?
  private var outputPipe: Pipe?
  private var activeLaunchID: UUID?
  private var reconnectWorkItem: DispatchWorkItem?
  private var parser = PNGStreamParser()
  private var stopped = true

  init(
    adbURL: URL,
    serial: String,
    onFrame: @escaping FrameHandler,
    onStatus: @escaping StatusHandler
  ) {
    self.adbURL = adbURL
    self.serial = serial
    self.onFrame = onFrame
    self.onStatus = onStatus
  }

  func start() throws {
    try queue.sync {
      guard stopped else { return }
      stopped = false
      do {
        try launch()
        onStatus("Using live framebuffer capture for this e-ink device")
      } catch {
        stopped = true
        throw error
      }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        stopped = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        activeLaunchID = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
          process.terminate()
        }
        process = nil
        outputPipe = nil
        parser.reset()
        continuation.resume()
      }
    }
  }

  private func launch() throws {
    guard !stopped, process == nil else { return }
    let launchID = UUID()
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = adbURL
    process.arguments = [
      "-s", serial, "exec-out", "sh", "-c",
      "while true; do screencap -p; done",
    ]
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    parser.reset()
    activeLaunchID = launchID

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async { [weak self] in
        guard let self, activeLaunchID == launchID, !stopped else { return }
        for png in parser.append(data) {
          guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
          else { continue }
          onFrame(frame)
        }
      }
    }
    process.terminationHandler = { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.processEnded(launchID: launchID)
      }
    }

    self.process = process
    self.outputPipe = outputPipe
    do {
      try process.run()
    } catch {
      self.process = nil
      self.outputPipe = nil
      activeLaunchID = nil
      throw MirrorPhoneError.processFailed(
        "Could not start Android framebuffer capture: \(error.localizedDescription)"
      )
    }
  }

  private func processEnded(launchID: UUID) {
    guard activeLaunchID == launchID else { return }
    activeLaunchID = nil
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    process = nil
    parser.reset()
    guard !stopped else { return }

    onStatus("Refreshing the Android framebuffer connection")
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, !stopped, process == nil else { return }
      reconnectWorkItem = nil
      do {
        try launch()
      } catch {
        onStatus(error.localizedDescription)
      }
    }
    reconnectWorkItem = workItem
    queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }
}

struct PNGStreamParser: Sendable {
  private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  private static let iend = Data("IEND".utf8)
  private static let maximumChunkSize = 64 * 1_024 * 1_024
  private var buffer = Data()

  mutating func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var images = [Data]()

    while true {
      guard alignToSignature() else { break }
      var offset = Self.signature.count
      var completeLength: Int?

      while buffer.count >= offset + 12 {
        let chunkLength = Int(readUInt32(at: offset))
        guard chunkLength <= Self.maximumChunkSize else {
          buffer = Data(buffer.dropFirst())
          break
        }
        let totalLength = 12 + chunkLength
        guard buffer.count >= offset + totalLength else { break }
        let type = buffer[(offset + 4)..<(offset + 8)]
        offset += totalLength
        if type.elementsEqual(Self.iend) {
          completeLength = offset
          break
        }
      }

      guard let completeLength else { break }
      images.append(Data(buffer.prefix(completeLength)))
      buffer = Data(buffer.dropFirst(completeLength))
    }
    return images
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
  }

  private mutating func alignToSignature() -> Bool {
    if buffer.starts(with: Self.signature) { return true }
    if let range = buffer.range(of: Self.signature) {
      buffer = Data(buffer[range.lowerBound...])
      return true
    }
    if buffer.count > Self.signature.count - 1 {
      buffer = Data(buffer.suffix(Self.signature.count - 1))
    }
    return false
  }

  private func readUInt32(at offset: Int) -> UInt32 {
    buffer[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
  }
}

private final class AndroidH264StreamDecoder: @unchecked Sendable {
  typealias FrameHandler = @Sendable (CGImage) -> Void
  typealias StatusHandler = @Sendable (String) -> Void

  private let decoder: H264Decoder
  private let onStatus: StatusHandler
  private var parser = AnnexBParser()
  private var sequenceParameterSet: Data?
  private var pictureParameterSet: Data?
  private var accessUnit = [Data]()
  private var accessUnitHasVideo = false
  private var needsConfiguration = true
  private var configured = false

  init(onFrame: @escaping FrameHandler, onStatus: @escaping StatusHandler) {
    decoder = H264Decoder(onFrame: onFrame)
    self.onStatus = onStatus
  }

  @discardableResult
  func consume(_ data: Data) -> Bool {
    let nalUnits = parser.append(data)
    for nalUnit in nalUnits {
      consumeNALUnit(nalUnit)
    }
    return !nalUnits.isEmpty
  }

  func finish() {
    if let nalUnit = parser.finish() {
      consumeNALUnit(nalUnit)
    }
    flushAccessUnit()
  }

  func reset() {
    parser.reset()
    sequenceParameterSet = nil
    pictureParameterSet = nil
    accessUnit.removeAll(keepingCapacity: true)
    accessUnitHasVideo = false
    needsConfiguration = true
    configured = false
    decoder.reset()
  }

  private func consumeNALUnit(_ nalUnit: Data) {
    guard let header = nalUnit.first else { return }
    let type = header & 0x1F

    switch type {
    case 7:
      flushAccessUnit()
      sequenceParameterSet = nalUnit
      needsConfiguration = true
    case 8:
      flushAccessUnit()
      pictureParameterSet = nalUnit
      needsConfiguration = true
    case 9:
      flushAccessUnit()
    case 1, 5:
      if accessUnitHasVideo, Self.isFirstSlice(nalUnit) {
        flushAccessUnit()
      }
      configureIfNeeded()
      accessUnit.append(nalUnit)
      accessUnitHasVideo = true
    case 6:
      if accessUnitHasVideo {
        flushAccessUnit()
      }
      accessUnit.append(nalUnit)
    default:
      accessUnit.append(nalUnit)
    }
  }

  private func configureIfNeeded() {
    guard needsConfiguration,
      let sequenceParameterSet,
      let pictureParameterSet,
      sequenceParameterSet.count <= Int(UInt16.max),
      pictureParameterSet.count <= Int(UInt16.max)
    else { return }

    var payload = Data()
    payload.appendUInt16(UInt16(sequenceParameterSet.count))
    payload.append(sequenceParameterSet)
    payload.appendUInt16(UInt16(pictureParameterSet.count))
    payload.append(pictureParameterSet)
    do {
      try decoder.configure(with: payload)
      configured = true
      needsConfiguration = false
    } catch {
      configured = false
      onStatus("Android video format is unsupported: \(error.localizedDescription)")
    }
  }

  private func flushAccessUnit() {
    defer {
      accessUnit.removeAll(keepingCapacity: true)
      accessUnitHasVideo = false
    }
    guard configured, accessUnitHasVideo else { return }

    var sample = Data()
    for nalUnit in accessUnit {
      guard nalUnit.count <= Int(UInt32.max) else { continue }
      sample.appendUInt32(UInt32(nalUnit.count))
      sample.append(nalUnit)
    }
    decoder.decode(sample)
  }

  private static func isFirstSlice(_ nalUnit: Data) -> Bool {
    guard nalUnit.count > 1 else { return true }
    var rbsp = [UInt8]()
    rbsp.reserveCapacity(nalUnit.count - 1)
    var zeroCount = 0
    for byte in nalUnit.dropFirst() {
      if zeroCount >= 2, byte == 0x03 {
        zeroCount = 0
        continue
      }
      rbsp.append(byte)
      zeroCount = byte == 0 ? zeroCount + 1 : 0
    }
    var reader = H264BitReader(bytes: rbsp)
    return reader.readUnsignedExpGolomb() == 0
  }
}

struct AnnexBParser: Sendable {
  private var buffer = [UInt8]()

  mutating func append(_ data: Data) -> [Data] {
    buffer.append(contentsOf: data)
    var nalUnits = [Data]()

    while true {
      guard let first = startCode(atOrAfter: 0) else {
        if buffer.count > 3 {
          buffer.removeFirst(buffer.count - 3)
        }
        break
      }
      if first.index > 0 {
        buffer.removeFirst(first.index)
      }
      guard let second = startCode(atOrAfter: first.length) else { break }

      let payload = buffer[first.length..<second.index]
      if !payload.isEmpty {
        nalUnits.append(Data(payload))
      }
      buffer.removeFirst(second.index)
    }
    return nalUnits
  }

  mutating func finish() -> Data? {
    defer { buffer.removeAll(keepingCapacity: true) }
    guard let start = startCode(atOrAfter: 0) else { return nil }
    var payload = Array(buffer.dropFirst(start.index + start.length))
    while payload.last == 0 {
      payload.removeLast()
    }
    return payload.isEmpty ? nil : Data(payload)
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
  }

  private func startCode(atOrAfter start: Int) -> (index: Int, length: Int)? {
    guard buffer.count >= 3, start <= buffer.count - 3 else { return nil }
    for index in start...(buffer.count - 3) where buffer[index] == 0 && buffer[index + 1] == 0 {
      if buffer[index + 2] == 1 {
        return (index, 3)
      }
      if index + 3 < buffer.count, buffer[index + 2] == 0, buffer[index + 3] == 1 {
        return (index, 4)
      }
    }
    return nil
  }
}

private struct H264BitReader {
  let bytes: [UInt8]
  private var bitOffset = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func readUnsignedExpGolomb() -> UInt32? {
    var leadingZeros = 0
    while let bit = readBit(), bit == 0 {
      leadingZeros += 1
      if leadingZeros > 31 { return nil }
    }
    guard leadingZeros <= 31 else { return nil }

    var suffix: UInt32 = 0
    for _ in 0..<leadingZeros {
      guard let bit = readBit() else { return nil }
      suffix = (suffix << 1) | UInt32(bit)
    }
    return (UInt32(1) << UInt32(leadingZeros)) - 1 + suffix
  }

  private mutating func readBit() -> UInt8? {
    guard bitOffset < bytes.count * 8 else { return nil }
    let byte = bytes[bitOffset / 8]
    let bit = (byte >> UInt8(7 - bitOffset % 8)) & 1
    bitOffset += 1
    return bit
  }
}
