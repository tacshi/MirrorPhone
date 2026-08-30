@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

@MainActor
final class DeviceDiscovery: MirrorDeviceDiscovering {
  var onDevicesChanged: (([MirrorDevice]) -> Void)?
  var onIOSCaptureDeviceReady: ((Set<String>) -> Void)?

  private var iosDevices = [MirrorDevice]()
  private var androidDevices = [MirrorDevice]()
  private var captureObservers = [NSObjectProtocol]()
  private let cmioNotificationQueue = DispatchQueue(
    label: "com.rockyshi.mirrorphone.cmio-device-events"
  )
  private var cmioDevicesListener: CMIOObjectPropertyListenerBlock?
  private var iosUSBMonitor: USBMuxDeviceMonitor?
  private var androidADBMonitor: AndroidADBDeviceMonitor?
  private var connectedIOSUSBDevices = [USBMuxDevice]()
  private var isIOSUSBPhysicallyAttached = false
  private var iosDetachTask: Task<Void, Never>?
  private var needsIOSCaptureRestart = false
  private var liveIOSCaptureDeviceIDs = Set<String>()
  private var isStarted = false

  func start() {
    guard !isStarted else { return }
    isStarted = true

    for name in [
      AVCaptureDevice.wasConnectedNotification,
      AVCaptureDevice.wasDisconnectedNotification,
    ] {
      captureObservers.append(
        NotificationCenter.default.addObserver(
          forName: name,
          object: nil,
          queue: .main
        ) { [weak self] notification in
          let captureDeviceRepublished =
            notification.name == AVCaptureDevice.wasConnectedNotification
          let deviceID = (notification.object as? AVCaptureDevice).map {
            "avfoundation:\($0.uniqueID)"
          }
          Task { @MainActor [weak self] in
            if !captureDeviceRepublished {
              self?.needsIOSCaptureRestart = true
              if let deviceID {
                self?.liveIOSCaptureDeviceIDs.remove(deviceID)
              }
            }
            self?.refreshIOSDevices(
              captureDeviceRepublished: captureDeviceRepublished,
              republishedDeviceID: captureDeviceRepublished ? deviceID : nil
            )
          }
        }
      )
    }

    observeCMIODeviceChanges()
    enableIOSScreenCaptureDevices()

    let iosUSBMonitor = USBMuxDeviceMonitor { [weak self] devices in
      Task { @MainActor [weak self] in
        self?.handleIOSUSBDevicesChanged(devices)
      }
    }
    self.iosUSBMonitor = iosUSBMonitor
    iosUSBMonitor.start()

    let androidADBMonitor = AndroidADBDeviceMonitor { [weak self] devices in
      Task { @MainActor [weak self] in
        self?.handleAndroidADBDevicesChanged(devices)
      }
    }
    self.androidADBMonitor = androidADBMonitor
    androidADBMonitor.start()

    refreshIOSDevices()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    iosDetachTask?.cancel()
    iosDetachTask = nil
    captureObservers.forEach(NotificationCenter.default.removeObserver)
    captureObservers.removeAll()
    stopObservingCMIODeviceChanges()
    iosUSBMonitor?.stop()
    iosUSBMonitor = nil
    connectedIOSUSBDevices.removeAll()
    isIOSUSBPhysicallyAttached = false
    liveIOSCaptureDeviceIDs.removeAll()
    androidADBMonitor?.stop()
    androidADBMonitor = nil
  }

  private func refreshIOSDevices(
    captureDeviceRepublished: Bool = false,
    republishedDeviceID: String? = nil
  ) {
    guard isStarted else { return }
    guard !connectedIOSUSBDevices.isEmpty else {
      iosDevices = []
      publishDevices()
      return
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external],
      mediaType: .muxed,
      position: .unspecified
    )
    let discoveredDevices = discovery.devices.map { device in
      MirrorDevice(
        id: "avfoundation:\(device.uniqueID)",
        name: device.localizedName,
        detail: "iPhone/iPad · USB",
        kind: .iosScreen(uniqueID: device.uniqueID)
      )
    }
    // AVFoundation briefly removes and republishes the screen device while a
    // newly attached iPhone finishes configuring. Physical detach is reported
    // by usbmuxd above, so do not publish that transient empty state.
    guard !discoveredDevices.isEmpty else { return }
    iosDevices = discoveredDevices
    publishDevices()
    if captureDeviceRepublished, needsIOSCaptureRestart, isIOSUSBPhysicallyAttached {
      needsIOSCaptureRestart = false
      let discoveredIDs = Set(discoveredDevices.map(\.id))
      if let republishedDeviceID, discoveredIDs.contains(republishedDeviceID) {
        onIOSCaptureDeviceReady?([republishedDeviceID])
      } else {
        onIOSCaptureDeviceReady?(discoveredIDs)
      }
    }
  }

  private func handleIOSUSBDevicesChanged(_ devices: [USBMuxDevice]) {
    iosDetachTask?.cancel()
    iosDetachTask = nil

    if !devices.isEmpty {
      if !isIOSUSBPhysicallyAttached {
        needsIOSCaptureRestart = true
        liveIOSCaptureDeviceIDs.removeAll()
      }
      isIOSUSBPhysicallyAttached = true
      connectedIOSUSBDevices = devices
      refreshIOSDevices()
      return
    }

    let wasLive = !liveIOSCaptureDeviceIDs.isEmpty
    isIOSUSBPhysicallyAttached = false
    liveIOSCaptureDeviceIDs.removeAll()
    needsIOSCaptureRestart = true

    if wasLive {
      connectedIOSUSBDevices.removeAll()
      refreshIOSDevices()
      return
    }

    // iOS can briefly detach and reattach while its USB screen service is
    // configuring. Coalesce that event burst without polling. A genuine
    // removal still clears the UI after this one-shot grace period.
    iosDetachTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard let self, isStarted else { return }
      connectedIOSUSBDevices.removeAll()
      refreshIOSDevices()
      iosDetachTask = nil
    }
  }

  func markIOSCaptureLive(deviceID: String) {
    guard isStarted, isIOSUSBPhysicallyAttached else { return }
    iosDetachTask?.cancel()
    iosDetachTask = nil
    liveIOSCaptureDeviceIDs.insert(deviceID)
  }

  private func handleAndroidADBDevicesChanged(_ devices: [AndroidADBDevice]) {
    guard isStarted else { return }
    androidDevices = devices.map { device in
      MirrorDevice(
        id: "adb:\(device.serial)",
        name: device.name,
        detail: "Android · USB debugging",
        kind: .androidADB(serial: device.serial)
      )
    }
    publishDevices()
  }

  private func publishDevices() {
    onDevicesChanged?(iosDevices + androidDevices)
  }

  private func observeCMIODeviceChanges() {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.refreshIOSDevices(captureDeviceRepublished: true)
      }
    }
    let status = CMIOObjectAddPropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject),
      &address,
      cmioNotificationQueue,
      listener
    )
    if status == noErr {
      cmioDevicesListener = listener
    }
  }

  private func stopObservingCMIODeviceChanges() {
    guard let cmioDevicesListener else { return }
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    CMIOObjectRemovePropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject),
      &address,
      cmioNotificationQueue,
      cmioDevicesListener
    )
    self.cmioDevicesListener = nil
  }

  private func enableIOSScreenCaptureDevices() {
    _ = Self.screenCaptureDevicesEnabled
  }

  private static let screenCaptureDevicesEnabled: Void = {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allowed: UInt32 = 1
    CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject),
      &address,
      0,
      nil,
      UInt32(MemoryLayout<UInt32>.size),
      &allowed
    )
  }()
}
