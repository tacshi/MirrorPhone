import Foundation

/// Locates the bundled scrcpy-style input and clipboard helper launched on the
/// device with `app_process`.
enum AndroidInputServer {
  static let devicePath = "/data/local/tmp/mirrorphone-input-server.jar"
  static let mainClass = "com.rockyshi.mirrorphone.InputServer"
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

enum AndroidClipboardCapability: String, Equatable, Sendable {
  case none
  case manual
  case sync
}

enum AndroidClipboardServerResult: Equatable, Sendable {
  case ok
  case content(DeviceClipboardContent)
  case failure(String)
}

enum AndroidInputServerMessage: Equatable, Sendable {
  case ready(AndroidClipboardCapability)
  case clipboardState(AndroidClipboardCapability, String?)
  case clipboardResult(UInt64, AndroidClipboardServerResult)
  case clipboardEvent(UInt64, DeviceClipboardContent)
}

enum AndroidClipboardWire {
  static let maximumTextBytes = 256 * 1_024
  /// Base64 expands 256 KiB to just under 342 KiB. Leave room for framing.
  static let maximumLineBytes = 384 * 1_024

  static func readCommand(
    requestID: UInt64,
    operation: DeviceClipboardSelectionOperation
  ) -> String {
    "cb-read \(requestID) \(operation.rawValue)\n"
  }

  static func pasteCommand(requestID: UInt64, text: String) throws -> String {
    "cb-paste \(requestID) \(try encodedText(text))\n"
  }

  static func encodedText(_ text: String) throws -> String {
    let data = Data(text.utf8)
    guard data.count <= maximumTextBytes else {
      throw DeviceClipboardError.tooLarge(maximumBytes: maximumTextBytes)
    }
    return data.isEmpty ? "-" : data.base64EncodedString()
  }

  static func decodedText(_ token: Substring) -> String? {
    let data: Data
    if token == "-" {
      data = Data()
    } else {
      guard let decoded = Data(base64Encoded: String(token)), decoded.count <= maximumTextBytes else {
        return nil
      }
      data = decoded
    }
    return String(data: data, encoding: .utf8)
  }
}

struct AndroidInputServerOutputParser {
  private var buffer = Data()

  mutating func append(_ data: Data) -> [AndroidInputServerMessage] {
    buffer.append(data)
    var messages = [AndroidInputServerMessage]()

    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if line.last == 0x0D {
        line.removeLast()
      }
      guard line.count <= AndroidClipboardWire.maximumLineBytes,
        let text = String(data: line, encoding: .ascii),
        let message = Self.parse(text)
      else { continue }
      messages.append(message)
    }

    if buffer.count > AndroidClipboardWire.maximumLineBytes {
      buffer.removeAll(keepingCapacity: false)
    }
    return messages
  }

  mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
  }

  private static func parse(_ line: String) -> AndroidInputServerMessage? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let operation = parts.first else { return nil }

    switch operation {
    case "READY":
      let capability = parts.dropFirst().compactMap { token -> AndroidClipboardCapability? in
        guard token.hasPrefix("clipboard=") else { return nil }
        return AndroidClipboardCapability(rawValue: String(token.dropFirst("clipboard=".count)))
      }.first ?? .none
      return .ready(capability)

    case "cb-state":
      guard parts.count == 2 || parts.count == 3,
        let capability = AndroidClipboardCapability(rawValue: String(parts[1]))
      else { return nil }
      let reason: String?
      if parts.count == 3 {
        guard let decodedReason = AndroidClipboardWire.decodedText(parts[2]) else { return nil }
        reason = decodedReason
      } else {
        reason = nil
      }
      return .clipboardState(capability, reason)

    case "cb-result":
      guard parts.count >= 3, let requestID = UInt64(parts[1]) else { return nil }
      switch parts[2] {
      case "ok":
        guard parts.count == 3 else { return nil }
        return .clipboardResult(requestID, .ok)
      case "text":
        guard parts.count == 4, let text = AndroidClipboardWire.decodedText(parts[3]) else {
          return nil
        }
        return .clipboardResult(requestID, .content(.text(text)))
      case "empty":
        guard parts.count == 3 else { return nil }
        return .clipboardResult(requestID, .content(.empty))
      case "unsupported":
        guard parts.count == 3 else { return nil }
        return .clipboardResult(requestID, .content(.unsupported))
      case "error":
        guard parts.count == 4, let reason = AndroidClipboardWire.decodedText(parts[3]) else {
          return nil
        }
        return .clipboardResult(requestID, .failure(reason))
      default:
        return nil
      }

    case "cb-event":
      guard parts.count >= 3, let sequence = UInt64(parts[1]) else { return nil }
      switch parts[2] {
      case "text":
        guard parts.count == 4, let text = AndroidClipboardWire.decodedText(parts[3]) else {
          return nil
        }
        return .clipboardEvent(sequence, .text(text))
      case "empty":
        guard parts.count == 3 else { return nil }
        return .clipboardEvent(sequence, .empty)
      case "unsupported":
        guard parts.count == 3 else { return nil }
        return .clipboardEvent(sequence, .unsupported)
      default:
        return nil
      }

    default:
      return nil
    }
  }
}

struct AndroidClipboardEventSequencer {
  private(set) var lastAcceptedSequence: UInt64?

  mutating func accept(_ sequence: UInt64) -> Bool {
    if let lastAcceptedSequence, sequence <= lastAcceptedSequence {
      return false
    }
    lastAcceptedSequence = sequence
    return true
  }

  mutating func reset() {
    lastAcceptedSequence = nil
  }
}

/// Forwards Mac input and clipboard requests over one long-lived Android helper
/// process. Failures remain non-fatal so video and audio mirroring continue.
final class AndroidInputRunner: @unchecked Sendable {
  typealias StatusHandler = @Sendable (String) -> Void
  typealias ClipboardStateHandler = @Sendable (DeviceClipboardState) -> Void
  typealias ClipboardContentHandler = @Sendable (DeviceClipboardContent) -> Void
  typealias ClipboardReadCompletion =
    @Sendable (Result<DeviceClipboardContent, DeviceClipboardError>) -> Void
  typealias ClipboardPasteCompletion = @Sendable (Result<Void, DeviceClipboardError>) -> Void

  private enum PendingClipboardRequest {
    case read(ClipboardReadCompletion)
    case paste(ClipboardPasteCompletion)

    func fail(_ error: DeviceClipboardError) {
      switch self {
      case .read(let completion): completion(.failure(error))
      case .paste(let completion): completion(.failure(error))
      }
    }

    func complete(with result: AndroidClipboardServerResult) {
      switch (self, result) {
      case (.read(let completion), .content(let content)):
        completion(.success(content))
      case (.paste(let completion), .ok):
        completion(.success(()))
      case (.read(let completion), .failure(let reason)):
        completion(.failure(.rejected(reason)))
      case (.paste(let completion), .failure(let reason)):
        completion(.failure(.rejected(reason)))
      case (.read(let completion), _):
        completion(.failure(.rejected("The Android helper returned an invalid clipboard response.")))
      case (.paste(let completion), _):
        completion(.failure(.rejected("The Android helper returned an invalid clipboard response.")))
      }
    }
  }

  private let adbURL: URL
  private let serial: String
  private let onStatus: StatusHandler
  private let onInterrupted: @Sendable () -> Void
  private let onClipboardState: ClipboardStateHandler
  private let onClipboardContent: ClipboardContentHandler
  private let queue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.android-input",
    qos: .userInteractive
  )
  private var process: Process?
  private var stdinPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var errorOutput = Data()
  private var outputParser = AndroidInputServerOutputParser()
  private var activeLaunchID: UUID?
  private var attemptsRemaining = 3
  private var launchedAt: Date?
  private var ready = false
  private var clipboardCapability = AndroidClipboardCapability.none
  private var clipboardEventSequencer = AndroidClipboardEventSequencer()
  private var nextClipboardRequestID: UInt64 = 1
  private var clipboardRequests = [UInt64: PendingClipboardRequest]()
  private var pendingInputCommands = [String]()
  private var stopped = true

  private static let healthyLaunchDuration: TimeInterval = 30
  private static let pendingInputLimit = 64
  private static let clipboardRequestTimeout: TimeInterval = 3

  init(
    adbURL: URL,
    serial: String,
    onStatus: @escaping StatusHandler,
    onInterrupted: @escaping @Sendable () -> Void,
    onClipboardState: @escaping ClipboardStateHandler,
    onClipboardContent: @escaping ClipboardContentHandler
  ) {
    self.adbURL = adbURL
    self.serial = serial
    self.onStatus = onStatus
    self.onInterrupted = onInterrupted
    self.onClipboardState = onClipboardState
    self.onClipboardContent = onClipboardContent
  }

  func start() {
    queue.async { [self] in
      guard stopped else { return }
      stopped = false
      reportClipboardState(.unavailable("Android clipboard bridge is starting."))

      guard let jarURL = AndroidInputServer.jarURL else {
        let message =
          "Android input is unavailable · rebuild MirrorPhone with the Android SDK present."
        onStatus(message)
        reportClipboardState(.unavailable(message))
        stopped = true
        return
      }
      guard deviceSupportsInjection() else {
        let message = "Android input and clipboard access need Android 11 or newer."
        onStatus("\(message) · mirroring is view-only.")
        reportClipboardState(.unavailable(message))
        stopped = true
        return
      }
      guard pushServer(jarURL) else {
        let message = "Could not stage the Android input and clipboard helper on the device."
        onStatus("Android input is unavailable · \(message)")
        reportClipboardState(.unavailable(message))
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
      pendingInputCommands.removeAll(keepingCapacity: false)
      failClipboardRequests(with: .disconnected)
      reportClipboardState(.unavailable("The Android device is disconnected."))
      outputPipe?.fileHandleForReading.readabilityHandler = nil
      errorPipe?.fileHandleForReading.readabilityHandler = nil
      try? stdinPipe?.fileHandleForWriting.close()
      if let process, process.isRunning {
        process.terminate()
      }
      process = nil
      stdinPipe = nil
      outputPipe = nil
      errorPipe = nil
      errorOutput.removeAll(keepingCapacity: false)
      outputParser.reset()
    }
  }

  func send(_ phase: TouchPhase, x: Int, y: Int, frameWidth: Int, frameHeight: Int) {
    let line: String
    switch phase {
    case .down: line = "d \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .move: line = "m \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .up: line = "u \(x) \(y) \(frameWidth) \(frameHeight)\n"
    case .cancel: line = "c\n"
    }
    writeInput(line)
  }

  func sendKey(down: Bool, keycode: Int, metaState: Int) {
    writeInput("k \(down ? "d" : "u") \(keycode) \(metaState)\n")
  }

  func sendText(_ text: String) {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard !text.isEmpty,
      let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed)
    else { return }
    writeInput("t \(encoded)\n")
  }

  func readClipboard(
    _ operation: DeviceClipboardSelectionOperation,
    completion: @escaping ClipboardReadCompletion
  ) {
    queue.async { [self] in
      guard canRequestClipboard else {
        completion(.failure(.unavailable(currentClipboardLimitation)))
        return
      }
      let requestID = allocateClipboardRequestID()
      beginClipboardRequest(
        id: requestID,
        line: AndroidClipboardWire.readCommand(requestID: requestID, operation: operation),
        request: .read(completion)
      )
    }
  }

  func pasteClipboard(_ text: String, completion: @escaping ClipboardPasteCompletion) {
    let encodedText: String
    do {
      encodedText = try AndroidClipboardWire.encodedText(text)
    } catch let error as DeviceClipboardError {
      completion(.failure(error))
      return
    } catch {
      completion(.failure(.rejected(error.localizedDescription)))
      return
    }

    queue.async { [self] in
      guard canRequestClipboard else {
        completion(.failure(.unavailable(currentClipboardLimitation)))
        return
      }
      let requestID = allocateClipboardRequestID()
      beginClipboardRequest(
        id: requestID,
        line: "cb-paste \(requestID) \(encodedText)\n",
        request: .paste(completion)
      )
    }
  }

  private var canRequestClipboard: Bool {
    ready && clipboardCapability != .none && stdinPipe != nil && !stopped
  }

  private var currentClipboardLimitation: String? {
    switch clipboardCapability {
    case .none: "Android clipboard access is unavailable on this device."
    case .manual, .sync: nil
    }
  }

  private func writeInput(_ line: String) {
    queue.async { [self] in
      guard !stopped else { return }
      guard ready, let handle = stdinPipe?.fileHandleForWriting else {
        if pendingInputCommands.count < Self.pendingInputLimit {
          pendingInputCommands.append(line)
        }
        return
      }
      try? handle.write(contentsOf: Data(line.utf8))
    }
  }

  private func beginClipboardRequest(
    id: UInt64,
    line: String,
    request: PendingClipboardRequest
  ) {
    guard let handle = stdinPipe?.fileHandleForWriting else {
      request.fail(.disconnected)
      return
    }
    clipboardRequests[id] = request
    do {
      try handle.write(contentsOf: Data(line.utf8))
    } catch {
      clipboardRequests.removeValue(forKey: id)?.fail(.disconnected)
      return
    }

    queue.asyncAfter(deadline: .now() + Self.clipboardRequestTimeout) { [weak self] in
      guard let self, let request = clipboardRequests.removeValue(forKey: id) else { return }
      request.fail(.timedOut)
    }
  }

  private func allocateClipboardRequestID() -> UInt64 {
    let requestID = nextClipboardRequestID
    nextClipboardRequestID =
      nextClipboardRequestID == UInt64(Int64.max) ? 1 : nextClipboardRequestID + 1
    return requestID
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
    process.arguments = ["-s", serial, "push", jarURL.path, AndroidInputServer.devicePath]
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
    failClipboardRequests(with: .disconnected)
    pendingInputCommands.removeAll(keepingCapacity: true)
    outputParser.reset()
    ready = false
    clipboardCapability = .none
    clipboardEventSequencer.reset()
    activeLaunchID = launchID
    launchedAt = Date()
    reportClipboardState(.unavailable("Android clipboard bridge is connecting."))
    process.executableURL = adbURL
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
        guard let self, activeLaunchID == launchID, !stopped else { return }
        for message in outputParser.append(data) {
          handleServerMessage(message)
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
      stopped = true
      let message = "Android input helper failed to start: \(error.localizedDescription)"
      onStatus(message)
      reportClipboardState(.unavailable(message))
    }
  }

  private func handleServerMessage(_ message: AndroidInputServerMessage) {
    switch message {
    case .ready(let capability):
      guard !ready else { return }
      ready = true
      applyClipboardCapability(capability, limitation: nil)
      let queued = pendingInputCommands
      pendingInputCommands.removeAll(keepingCapacity: false)
      guard let handle = stdinPipe?.fileHandleForWriting else { return }
      for line in queued {
        try? handle.write(contentsOf: Data(line.utf8))
      }

    case .clipboardState(let capability, let limitation):
      applyClipboardCapability(capability, limitation: limitation)

    case .clipboardResult(let requestID, let result):
      clipboardRequests.removeValue(forKey: requestID)?.complete(with: result)

    case .clipboardEvent(let sequence, let content):
      guard clipboardEventSequencer.accept(sequence) else { return }
      guard clipboardCapability == .sync else { return }
      onClipboardContent(content)
    }
  }

  private func applyClipboardCapability(
    _ capability: AndroidClipboardCapability,
    limitation: String?
  ) {
    clipboardCapability = capability
    switch capability {
    case .none:
      failClipboardRequests(with: .unavailable(limitation))
      reportClipboardState(
        .unavailable(limitation ?? "Android clipboard access is unavailable on this device.")
      )
    case .manual:
      reportClipboardState(
        .manual(
          limitation ?? "Automatic clipboard updates are unavailable; copy and paste remain available."
        )
      )
    case .sync:
      reportClipboardState(.synchronized)
    }
  }

  private func failClipboardRequests(with error: DeviceClipboardError) {
    let requests = Array(clipboardRequests.values)
    clipboardRequests.removeAll(keepingCapacity: false)
    for request in requests {
      request.fail(error)
    }
  }

  private func reportClipboardState(_ state: DeviceClipboardState) {
    onClipboardState(state)
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
    clipboardCapability = .none
    pendingInputCommands.removeAll(keepingCapacity: false)
    failClipboardRequests(with: .disconnected)
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
        onStatus("Android input forwarding stopped: \(detail)")
      } else {
        onStatus("Android input forwarding stopped · mirroring is view-only.")
      }
      reportClipboardState(.unavailable("The Android input helper stopped."))
      stopped = true
      return
    }

    reportClipboardState(.unavailable("Android clipboard bridge is reconnecting."))
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, !stopped, process == nil else { return }
      launch()
    }
  }
}
