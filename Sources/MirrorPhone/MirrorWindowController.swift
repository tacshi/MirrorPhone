import AppKit

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
  private static let defaultContentSize = NSSize(width: 560, height: 820)
  // Reveal/hide are decided from the pointer's position relative to the mirror's
  // top edge, which never moves (the window grows *above* it). Reveal only right
  // at the edge; keep shown across a much wider band so the growing/collapsing
  // window can never feed back into the decision and oscillate.
  private static let titlebarRevealBelow: CGFloat = 8
  private static let titlebarRevealAbove: CGFloat = 6
  private static let titlebarKeepBelow: CGFloat = 46
  private static let titlebarKeepAbove: CGFloat = 16
  // How long the pointer must stay outside the keep band before the bar hides.
  private static let titlebarHideDelay = Duration.milliseconds(240)
  private static let titlebarPollInterval = Duration.milliseconds(55)
  private static let fallbackTitlebarHeight: CGFloat = 28

  private let mirrorView = MirrorView()
  private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let actualSizeButton = NSButton()
  private let captureButton = NSButton()
  private var devices = [MirrorDevice]()
  private var selectedDeviceID: String?
  private var source: (any MirrorSource)?
  private var deviceDiscovery: DeviceDiscovery?
  private var connectionTask: Task<Void, Never>?
  private var connectionGeneration = 0
  private var retryCaptureWhenActive = false
  private var activeDeviceName: String?
  private var receivedFirstFrame = false
  private var reportedFrameSize: CGSize?
  private var mirrorAspectRatio: CGFloat?
  private var rememberedWindowSizes = MirrorWindowSizeMemory()
  private var isApplyingAspectResize = false
  private var isTitlebarVisible = false
  private var mirrorTopConstraint: NSLayoutConstraint?
  private var titlebarMonitorTask: Task<Void, Never>?
  private var titlebarHidePendingSince: ContinuousClock.Instant?

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    self.init(window: window)
    configureWindow()
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    startAutomaticDetection()
    startTitlebarPointerMonitor()
  }

  private func configureWindow() {
    guard let window else { return }
    window.title = "MirrorPhone"
    window.tabbingMode = .disallowed
    // The content view spans the whole frame (`.fullSizeContentView`). When the
    // titlebar is hidden the mirror fills the window edge-to-edge; when it is
    // revealed the window grows upward by the titlebar height and the mirror is
    // inset by the same amount, so the titlebar sits *above* the mirror without
    // ever moving it (see `setTitlebarVisible`).
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = false
    window.titlebarSeparatorStyle = .none
    window.minSize = NSSize(width: 440, height: 480)
    window.center()
    window.delegate = self
    // The strip that opens above the mirror when the titlebar reveals is backed
    // by the standard titlebar colour, not black, so growing the window never
    // flashes a black bar behind the fading-in chrome.
    window.backgroundColor = .windowBackgroundColor

    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = root

    devicePopup.target = self
    devicePopup.action = #selector(deviceSelectionChanged(_:))
    devicePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    devicePopup.translatesAutoresizingMaskIntoConstraints = false
    devicePopup.addItem(withTitle: "No device")
    devicePopup.isEnabled = false

    configureTitlebarButton(
      actualSizeButton,
      symbol: "1.magnifyingglass",
      help: "Actual size",
      action: #selector(actualSize(_:))
    )
    configureTitlebarButton(
      captureButton,
      symbol: "camera",
      help: "Capture image",
      action: #selector(captureImage(_:))
    )

    installTitlebarAccessories(in: window)

    mirrorView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(mirrorView)

    // The mirror is pinned to the bottom; its top inset grows to the titlebar
    // height while the bar is shown so the titlebar occupies fresh space above.
    let topInset = mirrorView.topAnchor.constraint(equalTo: root.topAnchor)
    mirrorTopConstraint = topInset
    NSLayoutConstraint.activate([
      topInset,
      mirrorView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      mirrorView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      mirrorView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  /// Places the device picker after the traffic lights and the action buttons on
  /// the trailing edge, all inside the native titlebar so they fade with it.
  private func installTitlebarAccessories(in window: NSWindow) {
    let deviceContainer = NSView(frame: NSRect(x: 0, y: 0, width: 123, height: 28))
    deviceContainer.addSubview(devicePopup)
    NSLayoutConstraint.activate([
      devicePopup.leadingAnchor.constraint(equalTo: deviceContainer.leadingAnchor, constant: 8),
      devicePopup.trailingAnchor.constraint(equalTo: deviceContainer.trailingAnchor, constant: -8),
      devicePopup.centerYAnchor.constraint(equalTo: deviceContainer.centerYAnchor),
    ])
    let leadingAccessory = NSTitlebarAccessoryViewController()
    leadingAccessory.layoutAttribute = .leading
    leadingAccessory.view = deviceContainer
    window.addTitlebarAccessoryViewController(leadingAccessory)

    let actionsContainer = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 28))
    actionsContainer.addSubview(actualSizeButton)
    actionsContainer.addSubview(captureButton)
    NSLayoutConstraint.activate([
      actualSizeButton.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor, constant: 6),
      actualSizeButton.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      captureButton.leadingAnchor.constraint(equalTo: actualSizeButton.trailingAnchor, constant: 8),
      captureButton.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      actualSizeButton.widthAnchor.constraint(equalToConstant: 22),
      actualSizeButton.heightAnchor.constraint(equalToConstant: 20),
      captureButton.widthAnchor.constraint(equalToConstant: 22),
      captureButton.heightAnchor.constraint(equalToConstant: 20),
    ])
    let trailingAccessory = NSTitlebarAccessoryViewController()
    trailingAccessory.layoutAttribute = .trailing
    trailingAccessory.view = actionsContainer
    window.addTitlebarAccessoryViewController(trailingAccessory)
  }

  private func configureTitlebarButton(
    _ button: NSButton,
    symbol: String,
    help: String,
    action: Selector
  ) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.bezelStyle = .accessoryBarAction
    button.target = self
    button.action = action
    button.toolTip = help
    button.setAccessibilityLabel(help)
    button.translatesAutoresizingMaskIntoConstraints = false
  }

  private func startAutomaticDetection() {
    deviceDiscovery?.stop()
    setStatus(Self.waitingStatus)
    let deviceDiscovery = DeviceDiscovery()
    deviceDiscovery.onDevicesChanged = { [weak self] devices in
      self?.updateDevices(devices)
    }
    deviceDiscovery.onIOSCaptureDeviceReady = { [weak self] in
      self?.restartSelectedIOSCapture()
    }
    self.deviceDiscovery = deviceDiscovery
    setTitlebarVisible(true)
    deviceDiscovery.start()
  }

  @objc private func deviceSelectionChanged(_ sender: Any?) {
    let index = devicePopup.indexOfSelectedItem
    guard devices.indices.contains(index) else { return }
    let device = devices[index]
    selectedDeviceID = device.id
    connect(to: device)
  }

  private func updateDevices(_ discoveredDevices: [MirrorDevice]) {
    let previousDevices = devices
    let previousSelection = selectedDeviceID
    devices = discoveredDevices

    let selectedDevice = previousSelection.flatMap { id in
      devices.first { $0.id == id }
    } ?? devices.first
    selectedDeviceID = selectedDevice?.id

    if previousDevices != devices || previousSelection != selectedDeviceID {
      updateDeviceMenu()
    }

    guard let selectedDevice else {
      if previousSelection != nil || source != nil || connectionTask != nil {
        stopConnection()
      }
      activeDeviceName = nil
      receivedFirstFrame = false
      reportedFrameSize = nil
      showDefaultScreen()
      setStatus(Self.waitingStatus)
      setTitlebarVisible(true)
      return
    }

    if previousSelection != selectedDevice.id {
      connect(to: selectedDevice)
    }
  }

  private func updateDeviceMenu() {
    devicePopup.removeAllItems()
    guard !devices.isEmpty else {
      devicePopup.addItem(withTitle: "No device")
      devicePopup.isEnabled = false
      return
    }

    for device in devices {
      devicePopup.addItem(withTitle: device.name)
    }
    devicePopup.isEnabled = devices.count > 1
    if let selectedDeviceID,
      let index = devices.firstIndex(where: { $0.id == selectedDeviceID })
    {
      devicePopup.selectItem(at: index)
    } else {
      devicePopup.selectItem(at: 0)
    }
  }

  private func connect(to device: MirrorDevice, preserveFrame: Bool = false) {
    connectionGeneration += 1
    let generation = connectionGeneration
    connectionTask?.cancel()
    let previousSource = source
    source = nil
    mirrorView.resetInputState()
    mirrorView.onInput = nil
    activeDeviceName = device.name
    receivedFirstFrame = false
    reportedFrameSize = nil
    if !preserveFrame {
      mirrorView.showLoading(deviceName: device.name)
    }
    setStatus("Connecting to \(device.name) by USB")

    connectionTask = Task { [weak self] in
      await previousSource?.stop()
      guard let self, !Task.isCancelled,
        connectionGeneration == generation,
        selectedDeviceID == device.id
      else { return }

      let newSource = device.makeSource()
      newSource.onFrame = { [weak self] frame in
        guard let self, selectedDeviceID == device.id else { return }
        mirrorView.show(frame: frame)
        fitWindowToDisplayedFrameIfNeeded()
        let frameSize = CGSize(width: frame.width, height: frame.height)
        if !receivedFirstFrame || reportedFrameSize != frameSize {
          if !receivedFirstFrame, case .iosScreen = device.kind {
            deviceDiscovery?.markIOSCaptureLive()
          }
          receivedFirstFrame = true
          reportedFrameSize = frameSize
          setStatus("Live · \(device.name) · \(frame.width) × \(frame.height)")
        }
      }
      newSource.onStatus = { [weak self] message in
        guard let self, selectedDeviceID == device.id else { return }
        setStatus(message)
      }
      // Forward semantic input to sources that accept it; view-only sources
      // return a nil sink and normal responder handling remains active.
      if let sink = newSource.inputSink {
        mirrorView.onInput = { [weak sink] event in
          sink?.send(event)
        }
        window?.makeFirstResponder(mirrorView)
      } else {
        mirrorView.onInput = nil
      }
      if let android = newSource as? AndroidADBMirrorSource {
        android.onInputInterrupted = { [weak self] in
          self?.mirrorView.resetInputState()
        }
      }
      source = newSource

      do {
        try await newSource.start()
        guard !Task.isCancelled,
          connectionGeneration == generation,
          selectedDeviceID == device.id
        else {
          await newSource.stop()
          return
        }
      } catch {
        await newSource.stop()
        if connectionGeneration == generation {
          source = nil
          setStatus(error.localizedDescription)
          present(error: error)
        }
      }
      if connectionGeneration == generation {
        connectionTask = nil
      }
    }
  }

  private func stopConnection() {
    connectionGeneration += 1
    let generation = connectionGeneration
    connectionTask?.cancel()
    mirrorView.resetInputState()
    mirrorView.onInput = nil
    let previousSource = source
    source = nil
    connectionTask = Task { [weak self] in
      await previousSource?.stop()
      guard let self, connectionGeneration == generation else { return }
      connectionTask = nil
    }
  }

  private func showDefaultScreen() {
    rememberCurrentViewerSize()
    activeDeviceName = nil
    receivedFirstFrame = false
    reportedFrameSize = nil
    mirrorAspectRatio = nil
    mirrorView.clear()
    restorePortraitWindow()
  }

  private func restorePortraitWindow() {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }

    let defaultFrameSize = window.frameRect(
      forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
    ).size
    let targetFrame = MirrorLayout.restoredWindowFrame(
      currentFrame: window.frame,
      portraitSize: defaultFrameSize,
      visibleFrame: screen.visibleFrame
    )
    guard targetFrame != window.frame else { return }

    isApplyingAspectResize = true
    window.setFrame(targetFrame, display: true, animate: false)
    isApplyingAspectResize = false
  }

  @objc func actualSize(_ sender: Any?) {
    guard let frame = mirrorView.displayedFrame,
      let window,
      let screen = window.screen ?? NSScreen.main
    else { return }

    let topBarHeight = windowChromeHeight
    let maxSize = CGSize(
      width: screen.visibleFrame.width * 0.9,
      height: screen.visibleFrame.height * 0.9 - topBarHeight
    )
    let scale = min(1, maxSize.width / CGFloat(frame.width), maxSize.height / CGFloat(frame.height))
    resizeWindow(viewerHeight: CGFloat(frame.height) * scale, aspectRatio: frame.aspectRatio)
    window.center()
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard !isApplyingAspectResize, let mirrorAspectRatio else { return frameSize }

    let chromeHeight = windowChromeHeight
    let maximumWindowHeight =
      ((sender.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude) * 0.95
    let maximumViewerHeight = max(1, maximumWindowHeight - chromeHeight)
    var width = max(frameSize.width, sender.minSize.width)
    var viewerHeight = width / mirrorAspectRatio
    if viewerHeight > maximumViewerHeight {
      viewerHeight = maximumViewerHeight
      width = max(sender.minSize.width, viewerHeight * mirrorAspectRatio)
    }
    return NSSize(width: width, height: viewerHeight + chromeHeight)
  }

  func windowDidResize(_ notification: Notification) {
    reassertTitlebarAlphaIfHidden()
    correctWindowHeightForViewerWidth()
  }

  func windowDidMove(_ notification: Notification) {
    reassertTitlebarAlphaIfHidden()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    startTitlebarPointerMonitor()
    if retryCaptureWhenActive {
      retryCaptureWhenActive = false
      retrySelectedDevice()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    titlebarMonitorTask?.cancel()
    titlebarMonitorTask = nil
    setTitlebarVisible(false)
  }

  @objc func captureImage(_ sender: Any?) {
    guard let frame = mirrorView.displayedFrame else {
      present(error: MirrorPhoneError.noFrame)
      return
    }
    guard let window else { return }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue =
      "MirrorPhone \(Self.filenameDateFormatter.string(from: Date())).png"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try ImageUtilities.writePNG(frame, to: url)
        self?.setStatus("Saved \(url.lastPathComponent)")
      } catch {
        self?.present(error: error)
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    titlebarMonitorTask?.cancel()
    titlebarMonitorTask = nil
    deviceDiscovery?.stop()
    deviceDiscovery = nil
    connectionTask?.cancel()
    Task { [source] in
      await source?.stop()
    }
  }

  private func setStatus(_ status: String) {
    // Connection state is intentionally not displayed in the title bar.
  }

  // MARK: - Titlebar auto-hide

  /// Reveal/hide from a pointer position measured against the mirror's fixed top
  /// edge. `rel` is how far the pointer sits above (positive) or below (negative)
  /// that edge; the titlebar, when shown, occupies `[0, titlebarHeight]` above it.
  ///
  /// Because the reference edge never moves — the window grows *above* it — the
  /// decision cannot feed back on itself, so the bar never oscillates near the
  /// boundary. Reveal only right at the edge; keep shown across a wide band.
  func handlePointerMoved(to location: CGPoint) {
    updateTitlebar(pointerAboveMirrorTop: location.y - mirrorView.bounds.maxY, pointerInX: true)
  }

  private func updateTitlebar(pointerAboveMirrorTop rel: CGFloat, pointerInX inX: Bool) {
    if isTitlebarVisible {
      let inKeepBand =
        inX && rel >= -Self.titlebarKeepBelow
        && rel <= resolvedTitlebarHeight + Self.titlebarKeepAbove
      if !inKeepBand, devicePopup.cell?.isHighlighted != true {
        setTitlebarVisible(false)
      }
    } else if inX, rel >= -Self.titlebarRevealBelow, rel <= Self.titlebarRevealAbove {
      setTitlebarVisible(true)
    }
  }

  /// A single poll drives reveal *and* hide while the window is key. Polling the
  /// real pointer (rather than tracking-area events) is what lets the bar react
  /// to the pointer moving up off the top edge into the desktop — where a window
  /// tracking area never sees it.
  private func startTitlebarPointerMonitor() {
    titlebarMonitorTask?.cancel()
    titlebarHidePendingSince = nil
    titlebarMonitorTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, let window, window.isVisible else { return }
        if !window.styleMask.contains(.fullScreen) {
          pollTitlebarPointer(in: window)
        }
        try? await Task.sleep(for: Self.titlebarPollInterval)
      }
    }
  }

  private func pollTitlebarPointer(in window: NSWindow) {
    let frame = window.frame
    // The mirror's top edge is fixed on screen: the window's top minus whatever
    // it is currently grown by. Measuring against it keeps the decision stable
    // as the window grows and collapses.
    let mirrorTop = frame.maxY - (mirrorTopConstraint?.constant ?? 0)
    let pointer = NSEvent.mouseLocation
    let inX = pointer.x >= frame.minX && pointer.x <= frame.maxX
    let rel = pointer.y - mirrorTop

    guard isTitlebarVisible else {
      titlebarHidePendingSince = nil
      updateTitlebar(pointerAboveMirrorTop: rel, pointerInX: inX)
      return
    }

    let inKeepBand =
      inX && rel >= -Self.titlebarKeepBelow && rel <= resolvedTitlebarHeight + Self.titlebarKeepAbove
    if inKeepBand || devicePopup.cell?.isHighlighted == true {
      titlebarHidePendingSince = nil
      return
    }
    // Debounce so a brief excursion past the band does not flicker the bar.
    let since = titlebarHidePendingSince ?? .now
    titlebarHidePendingSince = since
    if ContinuousClock.now - since >= Self.titlebarHideDelay {
      titlebarHidePendingSince = nil
      setTitlebarVisible(false)
    }
  }

  func setTitlebarVisible(_ visible: Bool) {
    let effectiveVisibility = visible || shouldKeepTitlebarVisible
    guard isTitlebarVisible != effectiveVisibility else { return }
    isTitlebarVisible = effectiveVisibility
    applyTitlebarState(visible: effectiveVisibility)
  }

  private var shouldKeepTitlebarVisible: Bool {
    deviceDiscovery != nil && devices.isEmpty
  }

  /// Grows the window upward (or collapses it back) by the titlebar height while
  /// insetting the mirror by the same amount, so the mirror keeps its exact
  /// on-screen position and the titlebar occupies fresh space above it.
  ///
  /// The chrome alpha and mirror inset are set *before* the single `setFrame`,
  /// so the grow/collapse, the inset and the alpha all land in one redraw — no
  /// intermediate frame that would flash a bare strip.
  private func applyTitlebarState(visible: Bool) {
    guard let mirrorTopConstraint else { return }
    let inset = visible ? resolvedTitlebarHeight : mirrorTopConstraint.constant

    titlebarContainerView?.alphaValue = visible ? 1 : 0
    mirrorTopConstraint.constant = visible ? inset : 0

    guard let window, inset > 0 else {
      window?.contentView?.layoutSubtreeIfNeeded()
      return
    }
    var frame = window.frame
    frame.size.height += visible ? inset : -inset
    if visible,
      let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
      frame.maxY > visibleFrame.maxY
    {
      frame.origin.y -= frame.maxY - visibleFrame.maxY
    }

    isApplyingAspectResize = true
    window.setFrame(frame, display: true, animate: false)
    isApplyingAspectResize = false
  }

  private var resolvedTitlebarHeight: CGFloat {
    if let height = titlebarContainerView?.frame.height, height > 1 { return height }
    return Self.fallbackTitlebarHeight
  }

  private func reassertTitlebarAlphaIfHidden() {
    guard !isTitlebarVisible else { return }
    titlebarContainerView?.alphaValue = 0
  }

  /// The `NSTitlebarContainerView` holding the traffic lights and both titlebar
  /// accessories. Fading it hides the whole chrome overlay at once.
  private var titlebarContainerView: NSView? {
    guard let titlebarView = window?.standardWindowButton(.closeButton)?.superview else {
      return nil
    }
    return titlebarView.superview ?? titlebarView
  }

  var areTitlebarControlsVisible: Bool {
    isTitlebarVisible
  }

  private var windowChromeHeight: CGFloat {
    guard let window else { return 0 }
    return max(0, window.frame.height - mirrorView.bounds.height)
  }

  private func fitWindowToDisplayedFrameIfNeeded(force: Bool = false) {
    guard let frame = mirrorView.displayedFrame else { return }
    let aspectRatio = frame.aspectRatio
    let changed = mirrorAspectRatio.map { abs($0 - aspectRatio) > 0.001 } ?? true
    guard force || changed else { return }

    rememberCurrentViewerSize()
    mirrorAspectRatio = aspectRatio
    let viewerHeight = rememberedWindowSizes.size(for: aspectRatio)?.height
      ?? mirrorView.bounds.height
    resizeWindow(viewerHeight: viewerHeight, aspectRatio: aspectRatio)
    rememberCurrentViewerSize()
  }

  private func rememberCurrentViewerSize() {
    guard let mirrorAspectRatio else { return }
    window?.contentView?.layoutSubtreeIfNeeded()
    rememberedWindowSizes.remember(
      viewerSize: mirrorView.bounds.size,
      aspectRatio: mirrorAspectRatio
    )
  }

  private func resizeWindow(viewerHeight: CGFloat, aspectRatio: CGFloat) {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }

    let chromeHeight = windowChromeHeight
    let visibleSize = screen.visibleFrame.size
    var height = max(1, viewerHeight)
    var width = height * aspectRatio

    if width < window.minSize.width {
      width = window.minSize.width
      height = width / aspectRatio
    }

    let maxWidth = visibleSize.width * 0.95
    let maxHeight = max(1, visibleSize.height * 0.95 - chromeHeight)
    let scale = min(1, maxWidth / width, maxHeight / height)
    width *= scale
    height *= scale

    var targetFrame = window.frame
    targetFrame.origin.x = window.frame.midX - width / 2
    targetFrame.origin.y = window.frame.maxY - height - chromeHeight
    targetFrame.size = NSSize(width: width, height: height + chromeHeight)
    targetFrame = MirrorLayout.constrainedWindowFrame(
      targetFrame,
      visibleFrame: screen.visibleFrame
    )

    isApplyingAspectResize = true
    window.setFrame(targetFrame, display: true, animate: false)
    isApplyingAspectResize = false
    correctWindowHeightForViewerWidth()
  }

  private func correctWindowHeightForViewerWidth() {
    guard !isApplyingAspectResize, let window, let mirrorAspectRatio else { return }
    window.contentView?.layoutSubtreeIfNeeded()

    let desiredViewerHeight = mirrorView.bounds.width / mirrorAspectRatio
    let screen = window.screen ?? NSScreen.main
    let maximumHeight = (screen?.visibleFrame.height ?? .greatestFiniteMagnitude) * 0.95
    let chromeHeight = windowChromeHeight
    let maximumViewerHeight = max(1, maximumHeight - chromeHeight)

    var correctedWidth = window.frame.width
    let correctedViewerHeight: CGFloat
    if desiredViewerHeight > maximumViewerHeight {
      correctedViewerHeight = maximumViewerHeight
      correctedWidth = max(window.minSize.width, correctedViewerHeight * mirrorAspectRatio)
    } else {
      correctedViewerHeight = desiredViewerHeight
    }
    let correctedHeight = correctedViewerHeight + chromeHeight
    let widthDelta = correctedWidth - window.frame.width
    let heightDelta = correctedHeight - window.frame.height
    guard abs(widthDelta) > 0.5 || abs(heightDelta) > 0.5 else { return }

    var correctedFrame = window.frame
    correctedFrame.origin.x -= widthDelta / 2
    correctedFrame.origin.y = window.frame.maxY - correctedHeight
    correctedFrame.size.width = correctedWidth
    correctedFrame.size.height = correctedHeight
    if let visibleFrame = screen?.visibleFrame {
      correctedFrame = MirrorLayout.constrainedWindowFrame(
        correctedFrame,
        visibleFrame: visibleFrame
      )
    }
    isApplyingAspectResize = true
    window.setFrame(correctedFrame, display: true, animate: false)
    isApplyingAspectResize = false
  }

  private func present(error: Error) {
    guard let window else { return }
    if let mirrorError = error as? MirrorPhoneError,
      case .cameraPermission = mirrorError
    {
      presentCapturePermissionAlert(for: window)
      return
    }
    let alert = NSAlert(error: error)
    alert.beginSheetModal(for: window)
  }

  private func presentCapturePermissionAlert(for window: NSWindow) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "iPhone capture access is blocked"
    alert.informativeText =
      "MirrorPhone opens the iPhone USB screen device directly. If macOS has blocked its video access, allow MirrorPhone in System Settings under Privacy & Security > Camera, then return to retry."
    alert.addButton(withTitle: "Open Camera Settings")
    alert.addButton(withTitle: "Retry")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        retryCaptureWhenActive = true
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) {
          NSWorkspace.shared.open(url)
        }
      case .alertSecondButtonReturn:
        retrySelectedDevice()
      default:
        break
      }
    }
  }

  private func retrySelectedDevice() {
    guard source == nil, connectionTask == nil, let selectedDeviceID,
      let device = devices.first(where: { $0.id == selectedDeviceID })
    else { return }
    connect(to: device)
  }

  private func restartSelectedIOSCapture() {
    guard let selectedDeviceID,
      let device = devices.first(where: { $0.id == selectedDeviceID }),
      case .iosScreen = device.kind
    else { return }
    connect(to: device, preserveFrame: true)
  }

  private static let filenameDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()

  private static var waitingStatus: String {
    if AndroidADB.executableURL == nil {
      return "Connect an iPhone/iPad by USB · Android transport unavailable"
    }
    return "Connect and unlock a phone by USB"
  }
}
