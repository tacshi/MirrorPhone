import AppKit

@MainActor
protocol MirrorDeviceDiscovering: AnyObject {
  var onDevicesChanged: (([MirrorDevice]) -> Void)? { get set }
  var onIOSCaptureDeviceReady: ((Set<String>) -> Void)? { get set }

  func start()
  func stop()
  func markIOSCaptureLive(deviceID: String)
}

@MainActor
protocol MirrorSourceCreating {
  func makeSource(for device: MirrorDevice) -> any MirrorSource
}

@MainActor
struct DefaultMirrorSourceFactory: MirrorSourceCreating {
  func makeSource(for device: MirrorDevice) -> any MirrorSource {
    switch device.kind {
    case .iosScreen(let uniqueID):
      AVCaptureMirrorSource(uniqueID: uniqueID)
    case .androidADB(let serial):
      AndroidADBMirrorSource(serial: serial, deviceName: device.name)
    }
  }
}

enum MirrorDeviceOptionState: Equatable, Sendable {
  case selected
  case available
  case inAnotherWindow
  case disconnected
  case switching
}

struct MirrorDeviceOption: Equatable, Sendable {
  let device: MirrorDevice
  let state: MirrorDeviceOptionState
}

struct MirrorWindowAssignment: Equatable, Sendable {
  let selectedDevice: MirrorDevice?
  let isSelectedDeviceConnected: Bool
  let pendingDeviceID: String?
  let options: [MirrorDeviceOption]
  var isTransitioning: Bool

  var selectedDeviceID: String? { selectedDevice?.id }

  static let empty = MirrorWindowAssignment(
    selectedDevice: nil,
    isSelectedDeviceConnected: false,
    pendingDeviceID: nil,
    options: [],
    isTransitioning: false
  )
}

/// Owns the device-claim invariants independently of AppKit and capture code.
/// A committed claim survives disconnects; a pending claim temporarily protects
/// a switch target while the old window finishes recording and stops its source.
struct MirrorDeviceClaimRegistry {
  private(set) var windowIDs = [UUID]()
  private(set) var connectedDevices = [MirrorDevice]()
  private var knownDevices = [String: MirrorDevice]()
  private var claimedDeviceIDs = [UUID: String]()
  private var pendingDeviceIDs = [UUID: String]()

  mutating func registerWindow(id: UUID) {
    guard !windowIDs.contains(id) else { return }
    windowIDs.append(id)
    assignAvailableDevicesToBlankWindows()
  }

  mutating func unregisterWindow(id: UUID) {
    windowIDs.removeAll { $0 == id }
    claimedDeviceIDs[id] = nil
    pendingDeviceIDs[id] = nil
    assignAvailableDevicesToBlankWindows()
  }

  mutating func updateDevices(_ devices: [MirrorDevice]) {
    var seen = Set<String>()
    connectedDevices = devices.filter { seen.insert($0.id).inserted }
    for device in connectedDevices {
      knownDevices[device.id] = device
    }
    assignAvailableDevicesToBlankWindows()
  }

  @discardableResult
  mutating func beginSwitch(windowID: UUID, to targetDeviceID: String) -> Bool {
    guard windowIDs.contains(windowID), pendingDeviceIDs[windowID] == nil,
      connectedDevices.contains(where: { $0.id == targetDeviceID }),
      claimedDeviceIDs[windowID] != targetDeviceID,
      owner(of: targetDeviceID) == nil
    else { return false }

    pendingDeviceIDs[windowID] = targetDeviceID
    return true
  }

  @discardableResult
  mutating func commitSwitch(windowID: UUID) -> Bool {
    guard let targetDeviceID = pendingDeviceIDs.removeValue(forKey: windowID) else {
      return false
    }
    claimedDeviceIDs[windowID] = targetDeviceID
    assignAvailableDevicesToBlankWindows()
    return true
  }

  mutating func cancelSwitch(windowID: UUID) {
    pendingDeviceIDs[windowID] = nil
    assignAvailableDevicesToBlankWindows()
  }

  func claimedDeviceID(for windowID: UUID) -> String? {
    claimedDeviceIDs[windowID]
  }

  func pendingDeviceID(for windowID: UUID) -> String? {
    pendingDeviceIDs[windowID]
  }

  func isConnected(deviceID: String) -> Bool {
    connectedDevices.contains { $0.id == deviceID }
  }

  func connectedDevice(id: String) -> MirrorDevice? {
    connectedDevices.first { $0.id == id }
  }

  func assignment(for windowID: UUID) -> MirrorWindowAssignment {
    let selectedDeviceID = claimedDeviceIDs[windowID]
    let selectedDevice = selectedDeviceID.flatMap { knownDevices[$0] }
    let connectedIDs = Set(connectedDevices.map(\.id))
    let pendingDeviceID = pendingDeviceIDs[windowID]

    var options = connectedDevices.map { device in
      let state: MirrorDeviceOptionState
      if device.id == selectedDeviceID {
        state = .selected
      } else if device.id == pendingDeviceID {
        state = .switching
      } else if owner(of: device.id) != nil {
        state = .inAnotherWindow
      } else {
        state = .available
      }
      return MirrorDeviceOption(device: device, state: state)
    }

    if let selectedDevice, !connectedIDs.contains(selectedDevice.id) {
      options.insert(MirrorDeviceOption(device: selectedDevice, state: .disconnected), at: 0)
    }

    return MirrorWindowAssignment(
      selectedDevice: selectedDevice,
      isSelectedDeviceConnected: selectedDevice.map { connectedIDs.contains($0.id) } ?? false,
      pendingDeviceID: pendingDeviceID,
      options: options,
      isTransitioning: pendingDeviceID != nil
    )
  }

  private func owner(of deviceID: String) -> UUID? {
    for windowID in windowIDs where claimedDeviceIDs[windowID] == deviceID {
      return windowID
    }
    for windowID in windowIDs where pendingDeviceIDs[windowID] == deviceID {
      return windowID
    }
    return nil
  }

  private mutating func assignAvailableDevicesToBlankWindows() {
    let blankWindows = windowIDs.filter {
      claimedDeviceIDs[$0] == nil && pendingDeviceIDs[$0] == nil
    }
    var availableDeviceIDs = connectedDevices.map(\.id).filter { owner(of: $0) == nil }

    for windowID in blankWindows {
      guard !availableDeviceIDs.isEmpty else { return }
      claimedDeviceIDs[windowID] = availableDeviceIDs.removeFirst()
    }
  }
}

/// The sole owner of discovery, windows, and physical-device claims.
@MainActor
final class MirrorWindowCoordinator {
  typealias WindowFactory = @MainActor (any MirrorSourceCreating) -> MirrorWindowController
  typealias RecordingFinalizer = @MainActor (MirrorWindowController) async -> Bool

  private final class WindowEntry {
    let id: UUID
    let controller: MirrorWindowController
    var transitionID: UUID?
    var transitionTask: Task<Void, Never>?

    init(id: UUID, controller: MirrorWindowController) {
      self.id = id
      self.controller = controller
    }
  }

  private let discovery: any MirrorDeviceDiscovering
  private let sourceFactory: any MirrorSourceCreating
  private let windowFactory: WindowFactory
  private let recordingFinalizer: RecordingFinalizer
  private var registry = MirrorDeviceClaimRegistry()
  private var entries = [UUID: WindowEntry]()
  private var orderedWindowIDs = [UUID]()
  private var isStarted = false

  init(
    discovery: any MirrorDeviceDiscovering = DeviceDiscovery(),
    sourceFactory: any MirrorSourceCreating = DefaultMirrorSourceFactory(),
    windowFactory: @escaping WindowFactory = { MirrorWindowController(sourceFactory: $0) },
    recordingFinalizer: @escaping RecordingFinalizer = {
      await $0.finalizeRecordingForTermination()
    }
  ) {
    self.discovery = discovery
    self.sourceFactory = sourceFactory
    self.windowFactory = windowFactory
    self.recordingFinalizer = recordingFinalizer
  }

  var windowControllers: [MirrorWindowController] {
    orderedWindowIDs.compactMap { entries[$0]?.controller }
  }

  var hasRecordingsToFinalize: Bool {
    windowControllers.contains { $0.hasRecordingToFinalize }
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    discovery.onDevicesChanged = { [weak self] devices in
      self?.devicesChanged(devices)
    }
    discovery.onIOSCaptureDeviceReady = { [weak self] deviceIDs in
      self?.restartIOSCapture(deviceIDs: deviceIDs)
    }
    openWindow(nil)
    discovery.start()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    discovery.stop()
    discovery.onDevicesChanged = nil
    discovery.onIOSCaptureDeviceReady = nil
  }

  func openWindow(_ sender: Any?) {
    let id = UUID()
    let controller = windowFactory(sourceFactory)
    let entry = WindowEntry(id: id, controller: controller)
    entries[id] = entry
    orderedWindowIDs.append(id)
    registry.registerWindow(id: id)

    controller.onDeviceSelectionRequested = { [weak self] deviceID in
      self?.requestSwitch(windowID: id, to: deviceID)
    }
    controller.onWindowCloseRequested = { [weak self] in
      self?.cancelSwitch(windowID: id)
    }
    controller.onWindowClosed = { [weak self] in
      self?.windowClosed(id: id)
    }
    controller.onIOSCaptureLive = { [weak self] deviceID in
      self?.discovery.markIOSCaptureLive(deviceID: deviceID)
    }

    publishAssignments()
    cascade(controller.window)
    controller.showWindow(sender)
    controller.window?.makeKeyAndOrderFront(sender)
  }

  func finalizeRecordingsForTermination() async -> Bool {
    let tasks = windowControllers.map { controller in
      Task { @MainActor [recordingFinalizer] in
        await recordingFinalizer(controller)
      }
    }
    var succeeded = true
    for task in tasks where await !task.value {
      succeeded = false
    }
    return succeeded
  }

  func assignment(for controller: MirrorWindowController) -> MirrorWindowAssignment? {
    guard let id = entries.first(where: { $0.value.controller === controller })?.key else {
      return nil
    }
    return registry.assignment(for: id)
  }

  private func devicesChanged(_ devices: [MirrorDevice]) {
    registry.updateDevices(devices)
    for id in orderedWindowIDs {
      guard let entry = entries[id], let targetID = registry.pendingDeviceID(for: id),
        !registry.isConnected(deviceID: targetID)
      else { continue }
      entry.transitionTask?.cancel()
      registry.cancelSwitch(windowID: id)
    }
    publishAssignments()
  }

  private func requestSwitch(windowID: UUID, to targetDeviceID: String) {
    guard let entry = entries[windowID], entry.transitionTask == nil,
      let targetDevice = registry.connectedDevice(id: targetDeviceID),
      registry.beginSwitch(windowID: windowID, to: targetDeviceID)
    else {
      publishAssignments()
      return
    }

    let transitionID = UUID()
    entry.transitionID = transitionID
    publishAssignments()
    entry.transitionTask = Task { @MainActor [weak self, weak controller = entry.controller] in
      guard let self, let controller else { return }
      let prepared = await controller.prepareForDeviceSwitch(to: targetDevice)
      guard let currentEntry = entries[windowID], currentEntry.transitionID == transitionID else {
        return
      }

      if prepared, !Task.isCancelled,
        registry.pendingDeviceID(for: windowID) == targetDeviceID
      {
        registry.commitSwitch(windowID: windowID)
      } else {
        registry.cancelSwitch(windowID: windowID)
      }
      currentEntry.transitionID = nil
      currentEntry.transitionTask = nil
      publishAssignments()
    }
  }

  private func cancelSwitch(windowID: UUID) {
    guard let entry = entries[windowID] else { return }
    entry.transitionTask?.cancel()
    registry.cancelSwitch(windowID: windowID)
    publishAssignments()
  }

  private func windowClosed(id: UUID) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.transitionTask?.cancel()
    orderedWindowIDs.removeAll { $0 == id }
    registry.unregisterWindow(id: id)
    publishAssignments()
  }

  private func restartIOSCapture(deviceIDs: Set<String>) {
    for id in orderedWindowIDs {
      guard let entry = entries[id],
        let selectedDeviceID = registry.claimedDeviceID(for: id),
        deviceIDs.contains(selectedDeviceID)
      else { continue }
      entry.controller.restartIOSCapture(deviceID: selectedDeviceID)
    }
  }

  private func publishAssignments() {
    for id in orderedWindowIDs {
      guard let entry = entries[id] else { continue }
      var assignment = registry.assignment(for: id)
      if entry.transitionTask != nil {
        assignment.isTransitioning = true
      }
      entry.controller.apply(assignment: assignment)
    }
  }

  private func cascade(_ window: NSWindow?) {
    guard let window, orderedWindowIDs.count > 1 else { return }
    let previousID = orderedWindowIDs[orderedWindowIDs.count - 2]
    guard let previousWindow = entries[previousID]?.controller.window else { return }
    let previousTopLeft = NSPoint(x: previousWindow.frame.minX, y: previousWindow.frame.maxY)
    let nextTopLeft = previousWindow.cascadeTopLeft(from: previousTopLeft)
    window.cascadeTopLeft(from: nextTopLeft)
  }
}
