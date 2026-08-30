import AppKit
import CoreGraphics
import Testing

@testable import MirrorPhone

private func testDevice(_ id: String, name: String? = nil) -> MirrorDevice {
  MirrorDevice(
    id: "adb:\(id)",
    name: name ?? id,
    detail: "Android · USB debugging",
    kind: .androidADB(serial: id)
  )
}

@Suite("Exclusive device claims")
struct MirrorDeviceClaimRegistryTests {
  @Test("Windows claim connected devices in creation and discovery order")
  func deterministicAutomaticAssignment() {
    let firstWindow = UUID()
    let secondWindow = UUID()
    let blankWindow = UUID()
    let firstDevice = testDevice("first")
    let secondDevice = testDevice("second")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: firstWindow)
    registry.registerWindow(id: secondWindow)
    registry.registerWindow(id: blankWindow)
    registry.updateDevices([firstDevice, secondDevice])

    #expect(registry.claimedDeviceID(for: firstWindow) == firstDevice.id)
    #expect(registry.claimedDeviceID(for: secondWindow) == secondDevice.id)
    #expect(registry.claimedDeviceID(for: blankWindow) == nil)
    #expect(
      registry.assignment(for: firstWindow).options.first(where: {
        $0.device.id == secondDevice.id
      })?.state == .inAnotherWindow
    )
  }

  @Test("The oldest blank window claims the next newly connected device")
  func oldestBlankWindowClaimsNewDevice() {
    let firstWindow = UUID()
    let oldestBlankWindow = UUID()
    let newestBlankWindow = UUID()
    let firstDevice = testDevice("first")
    let laterDevice = testDevice("later")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: firstWindow)
    registry.registerWindow(id: oldestBlankWindow)
    registry.registerWindow(id: newestBlankWindow)
    registry.updateDevices([firstDevice])
    registry.updateDevices([firstDevice, laterDevice])

    #expect(registry.claimedDeviceID(for: oldestBlankWindow) == laterDevice.id)
    #expect(registry.claimedDeviceID(for: newestBlankWindow) == nil)
  }

  @Test("Disconnect retains the claim and reconnect returns to the same window")
  func disconnectedReservationIsStable() {
    let firstWindow = UUID()
    let secondWindow = UUID()
    let firstDevice = testDevice("first", name: "Phone One")
    let secondDevice = testDevice("second")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: firstWindow)
    registry.registerWindow(id: secondWindow)
    registry.updateDevices([firstDevice, secondDevice])
    registry.updateDevices([secondDevice])

    let disconnected = registry.assignment(for: firstWindow)
    #expect(disconnected.selectedDevice == firstDevice)
    #expect(!disconnected.isSelectedDeviceConnected)
    #expect(disconnected.options.first?.state == .disconnected)
    #expect(registry.claimedDeviceID(for: secondWindow) == secondDevice.id)

    registry.updateDevices([secondDevice, firstDevice])
    #expect(registry.claimedDeviceID(for: firstWindow) == firstDevice.id)
    #expect(registry.assignment(for: firstWindow).isSelectedDeviceConnected)
  }

  @Test("A switch target is exclusive until commit or rollback")
  func switchReservationAndRollback() {
    let switchingWindow = UUID()
    let blankWindow = UUID()
    let currentDevice = testDevice("current")
    let targetDevice = testDevice("target")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: switchingWindow)
    registry.updateDevices([currentDevice, targetDevice])
    let beganSwitch = registry.beginSwitch(windowID: switchingWindow, to: targetDevice.id)
    #expect(beganSwitch)
    registry.registerWindow(id: blankWindow)

    let pending = registry.assignment(for: switchingWindow)
    #expect(pending.selectedDeviceID == currentDevice.id)
    #expect(pending.pendingDeviceID == targetDevice.id)
    #expect(pending.isTransitioning)
    #expect(registry.claimedDeviceID(for: blankWindow) == nil)

    registry.cancelSwitch(windowID: switchingWindow)
    #expect(registry.claimedDeviceID(for: switchingWindow) == currentDevice.id)
    #expect(registry.claimedDeviceID(for: blankWindow) == targetDevice.id)
  }

  @Test("Committing a switch releases the old device to the oldest blank window")
  func switchCommitReleasesOldDevice() {
    let switchingWindow = UUID()
    let blankWindow = UUID()
    let currentDevice = testDevice("current")
    let targetDevice = testDevice("target")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: switchingWindow)
    registry.updateDevices([currentDevice, targetDevice])
    let beganSwitch = registry.beginSwitch(windowID: switchingWindow, to: targetDevice.id)
    registry.registerWindow(id: blankWindow)
    let committedSwitch = registry.commitSwitch(windowID: switchingWindow)

    #expect(beganSwitch)
    #expect(committedSwitch)
    #expect(registry.claimedDeviceID(for: switchingWindow) == targetDevice.id)
    #expect(registry.claimedDeviceID(for: blankWindow) == currentDevice.id)
  }

  @Test("Closing a window releases its connected device")
  func closeReleasesClaim() {
    let owningWindow = UUID()
    let blankWindow = UUID()
    let device = testDevice("only")
    var registry = MirrorDeviceClaimRegistry()

    registry.registerWindow(id: owningWindow)
    registry.registerWindow(id: blankWindow)
    registry.updateDevices([device])
    registry.unregisterWindow(id: owningWindow)

    #expect(registry.claimedDeviceID(for: blankWindow) == device.id)
  }
}

@MainActor
private final class InMemoryMirrorDeviceDiscovery: MirrorDeviceDiscovering {
  var onDevicesChanged: (([MirrorDevice]) -> Void)?
  var onIOSCaptureDeviceReady: ((Set<String>) -> Void)?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var liveIOSDeviceIDs = Set<String>()

  func start() {
    startCount += 1
  }

  func stop() {
    stopCount += 1
  }

  func markIOSCaptureLive(deviceID: String) {
    liveIOSDeviceIDs.insert(deviceID)
  }

  func publish(_ devices: [MirrorDevice]) {
    onDevicesChanged?(devices)
  }
}

@MainActor
private final class CountingMirrorSourceFactory: MirrorSourceCreating {
  private(set) var activeCounts = [String: Int]()
  private(set) var maximumActiveCounts = [String: Int]()
  private(set) var creationCounts = [String: Int]()

  func makeSource(for device: MirrorDevice) -> any MirrorSource {
    creationCounts[device.id, default: 0] += 1
    return CountingMirrorSource(deviceID: device.id, factory: self)
  }

  func didStart(deviceID: String) {
    activeCounts[deviceID, default: 0] += 1
    maximumActiveCounts[deviceID] = max(
      maximumActiveCounts[deviceID, default: 0],
      activeCounts[deviceID, default: 0]
    )
  }

  func didStop(deviceID: String) {
    activeCounts[deviceID, default: 0] = max(0, activeCounts[deviceID, default: 0] - 1)
  }
}

@MainActor
private final class CountingMirrorSource: MirrorSource {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?

  private let deviceID: String
  private weak var factory: CountingMirrorSourceFactory?
  private var isStarted = false

  init(deviceID: String, factory: CountingMirrorSourceFactory) {
    self.deviceID = deviceID
    self.factory = factory
  }

  func start() async throws {
    guard !isStarted else { return }
    isStarted = true
    factory?.didStart(deviceID: deviceID)
  }

  func stop() async {
    guard isStarted else { return }
    isStarted = false
    factory?.didStop(deviceID: deviceID)
  }
}

@MainActor
@Suite("Shared multi-window coordination")
struct MirrorWindowCoordinatorTests {
  @Test("Opening more windows keeps one discovery stack and one active source per device")
  func sharesDiscoveryAndSourcesRemainExclusive() async {
    let discovery = InMemoryMirrorDeviceDiscovery()
    let sourceFactory = CountingMirrorSourceFactory()
    let coordinator = MirrorWindowCoordinator(
      discovery: discovery,
      sourceFactory: sourceFactory
    )
    let firstDevice = testDevice("first")
    let secondDevice = testDevice("second")

    coordinator.start()
    discovery.publish([firstDevice, secondDevice])
    coordinator.openWindow(nil)
    coordinator.openWindow(nil)
    await settleCoordinatorTasks()

    #expect(discovery.startCount == 1)
    #expect(coordinator.windowControllers.count == 3)
    #expect(coordinator.assignment(for: coordinator.windowControllers[0])?.selectedDeviceID == firstDevice.id)
    #expect(coordinator.assignment(for: coordinator.windowControllers[1])?.selectedDeviceID == secondDevice.id)
    #expect(coordinator.assignment(for: coordinator.windowControllers[2])?.selectedDeviceID == nil)
    #expect(sourceFactory.maximumActiveCounts[firstDevice.id] == 1)
    #expect(sourceFactory.maximumActiveCounts[secondDevice.id] == 1)
    #expect(coordinator.windowControllers[0].window?.title == "MirrorPhone — \(firstDevice.name)")
    #expect(coordinator.windowControllers[1].window?.title == "MirrorPhone — \(secondDevice.name)")
    #expect(
      coordinator.windowControllers[0].window?.frame.origin
        != coordinator.windowControllers[1].window?.frame.origin
    )
    #expect(
      coordinator.windowControllers[1].window?.frame.origin
        != coordinator.windowControllers[2].window?.frame.origin
    )

    #expect(
      coordinator.windowControllers[0].window?.nextResponder === coordinator.windowControllers[0]
    )
    #expect(
      coordinator.windowControllers[1].window?.nextResponder === coordinator.windowControllers[1]
    )

    let controllers = coordinator.windowControllers
    for controller in controllers {
      _ = await controller.prepareForDeviceSwitch()
      controller.window?.close()
    }
    await settleCoordinatorTasks()
    coordinator.stop()
    #expect(discovery.stopCount == 1)
  }

  @Test("Application termination finalizes every window concurrently and reports any failure")
  func aggregatesTerminationAcrossWindows() async throws {
    let discovery = InMemoryMirrorDeviceDiscovery()
    let sourceFactory = CountingMirrorSourceFactory()
    var pendingFinalizations = [CheckedContinuation<Bool, Never>]()
    let coordinator = MirrorWindowCoordinator(
      discovery: discovery,
      sourceFactory: sourceFactory,
      recordingFinalizer: { _ in
        await withCheckedContinuation { continuation in
          pendingFinalizations.append(continuation)
        }
      }
    )
    coordinator.start()
    coordinator.openWindow(nil)

    let termination = Task { @MainActor in
      await coordinator.finalizeRecordingsForTermination()
    }
    for _ in 0..<20 where pendingFinalizations.count < 2 {
      await Task.yield()
    }
    try #require(pendingFinalizations.count == 2)
    pendingFinalizations[0].resume(returning: true)
    pendingFinalizations[1].resume(returning: false)

    #expect(await termination.value == false)

    let controllers = coordinator.windowControllers
    for controller in controllers {
      controller.window?.close()
    }
    coordinator.stop()
  }

  private func settleCoordinatorTasks() async {
    for _ in 0..<12 {
      await Task.yield()
    }
  }
}
