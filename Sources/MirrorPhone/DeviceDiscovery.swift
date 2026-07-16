@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

@MainActor
final class DeviceDiscovery {
  var onDevicesChanged: (([MirrorDevice]) -> Void)?
  var onIOSCaptureDeviceReady: (() -> Void)?

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
  private var isIOSCaptureLive = false
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
          Task { @MainActor [weak self] in
            self?.refreshIOSDevices(
              captureDeviceRepublished: captureDeviceRepublished
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
    isIOSCaptureLive = false
    androidADBMonitor?.stop()
    androidADBMonitor = nil
  }

  private func refreshIOSDevices(captureDeviceRepublished: Bool = false) {
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
      onIOSCaptureDeviceReady?()
    }
  }

  private func handleIOSUSBDevicesChanged(_ devices: [USBMuxDevice]) {
    iosDetachTask?.cancel()
    iosDetachTask = nil

    if !devices.isEmpty {
      if !isIOSUSBPhysicallyAttached {
        needsIOSCaptureRestart = true
        isIOSCaptureLive = false
      }
      isIOSUSBPhysicallyAttached = true
      connectedIOSUSBDevices = devices
      refreshIOSDevices()
      return
    }

    let wasLive = isIOSCaptureLive
    isIOSUSBPhysicallyAttached = false
    isIOSCaptureLive = false
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

  func markIOSCaptureLive() {
    guard isStarted, isIOSUSBPhysicallyAttached else { return }
    iosDetachTask?.cancel()
    iosDetachTask = nil
    isIOSCaptureLive = true
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

extension MirrorDevice {
  @MainActor
  func makeSource() -> any MirrorSource {
    switch kind {
    case .iosScreen(let uniqueID):
      AVCaptureMirrorSource(uniqueID: uniqueID)
    case .androidADB(let serial):
      AndroidADBMirrorSource(serial: serial, deviceName: name)
    }
  }
}
