import AppKit
import UniformTypeIdentifiers

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  private static let defaultContentSize = NSSize(width: 453, height: 1014)
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
  private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let actualSizeButton = NSButton()
  private let captureButton = NSButton()
  private let recordButton = NSButton()
  private var assignment = MirrorWindowAssignment.empty
  private var receivesCoordinatedAssignments = false
  private var sourceFactory: any MirrorSourceCreating = DefaultMirrorSourceFactory()
  private var pasteboard: any MirrorPasteboard = GeneralMirrorPasteboard.shared
  private var applicationIsActive: @MainActor () -> Bool = { NSApp.isActive }
  private var windowIsKeyOverride: (@MainActor () -> Bool)?
  private var qualityPreferences: any MirrorQualityPreferenceStoring =
    UserDefaultsMirrorQualityPreferences.shared
  private var qualityMode = MirrorQualityMode.automatic
  private var displayedQualityState = MirrorQualityState(
    mode: .automatic,
    effectiveLevel: nil,
    isAdjusting: false,
    limitation: nil
  )
  private var source: (any MirrorSource)?
  private var sourceDeviceID: String?
  private var connectionTask: Task<Void, Never>?
  private var disconnectionTask: Task<Void, Never>?
  private var restartTask: Task<Void, Never>?
  private var connectionGeneration = 0
  private var retryCaptureWhenActive = false
  private var receivedFirstFrame = false
  private var reportedFrameSize: CGSize?
  private var mirrorAspectRatio: CGFloat?
  private var rememberedWindowSizes = MirrorWindowSizeMemory()
  private var isApplyingAspectResize = false
  private var isTitlebarVisible = false
  private var mirrorTopConstraint: NSLayoutConstraint?
  private var titlebarMonitorTask: Task<Void, Never>?
  private var titlebarHidePendingSince: ContinuousClock.Instant?
  private var recorder: MP4Recorder?
  private var recordingTap: MirrorRecordingTap?
  private var recordingStartedAt: ContinuousClock.Instant?
  private var recordingAudioState = MirrorRecordingAudioState.pending
  private var recordingTimerTask: Task<Void, Never>?
  private var recordingFinishTask: Task<Bool, Never>?
  private var recordingStatusDismissTask: Task<Void, Never>?
  private var savePanelOpen = false
  private var isPreparingDeviceSwitch = false
  private var isPreparingToClose = false
  private var closeRequested = false
  private var allowWindowClose = false
  private var recordingGeneration = 0
  private var clipboardGeneration = 0
  private var clipboardTask: Task<Void, Never>?

  var onDeviceSelectionRequested: ((String) -> Void)?
  var onWindowCloseRequested: (() -> Void)?
  var onWindowClosed: (() -> Void)?
  var onIOSCaptureLive: ((String) -> Void)?

  convenience init() {
    self.init(sourceFactory: DefaultMirrorSourceFactory())
  }

  convenience init(
    sourceFactory: any MirrorSourceCreating,
    qualityPreferences: any MirrorQualityPreferenceStoring =
      UserDefaultsMirrorQualityPreferences.shared,
    pasteboard: any MirrorPasteboard = GeneralMirrorPasteboard.shared,
    applicationIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
    windowIsKey: (@MainActor () -> Bool)? = nil
  ) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    self.init(window: window)
    self.sourceFactory = sourceFactory
    self.qualityPreferences = qualityPreferences
    self.pasteboard = pasteboard
    self.applicationIsActive = applicationIsActive
    self.windowIsKeyOverride = windowIsKey
    qualityMode = qualityPreferences.defaultMode
    displayedQualityState = MirrorQualityState(
      mode: qualityMode,
      effectiveLevel: nil,
      isAdjusting: false,
      limitation: nil
    )
    configureWindow()
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    if assignment.selectedDevice == nil || !assignment.isSelectedDeviceConnected {
      setTitlebarVisible(true)
    }
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

    configureQualityPopup()

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
    configureTitlebarButton(
      recordButton,
      symbol: "record.circle",
      help: "Start recording…",
      action: #selector(toggleRecording(_:))
    )
    updateRecordingAction()

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

    let actionsContainer = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
    actionsContainer.addSubview(qualityPopup)
    actionsContainer.addSubview(actualSizeButton)
    actionsContainer.addSubview(captureButton)
    actionsContainer.addSubview(recordButton)
    NSLayoutConstraint.activate([
      qualityPopup.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor, constant: 6),
      qualityPopup.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      qualityPopup.widthAnchor.constraint(equalToConstant: 132),
      qualityPopup.heightAnchor.constraint(equalToConstant: 22),
      actualSizeButton.leadingAnchor.constraint(equalTo: qualityPopup.trailingAnchor, constant: 8),
      actualSizeButton.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      captureButton.leadingAnchor.constraint(equalTo: actualSizeButton.trailingAnchor, constant: 8),
      captureButton.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      actualSizeButton.widthAnchor.constraint(equalToConstant: 22),
      actualSizeButton.heightAnchor.constraint(equalToConstant: 20),
      captureButton.widthAnchor.constraint(equalToConstant: 22),
      captureButton.heightAnchor.constraint(equalToConstant: 20),
      recordButton.leadingAnchor.constraint(equalTo: captureButton.trailingAnchor, constant: 8),
      recordButton.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
      recordButton.widthAnchor.constraint(equalToConstant: 22),
      recordButton.heightAnchor.constraint(equalToConstant: 20),
    ])
    let trailingAccessory = NSTitlebarAccessoryViewController()
    trailingAccessory.layoutAttribute = .trailing
    trailingAccessory.view = actionsContainer
    window.addTitlebarAccessoryViewController(trailingAccessory)
  }

  private func configureQualityPopup() {
    qualityPopup.target = self
    qualityPopup.action = #selector(qualitySelectionChanged(_:))
    qualityPopup.controlSize = .small
    qualityPopup.font = .systemFont(ofSize: 11)
    qualityPopup.translatesAutoresizingMaskIntoConstraints = false
    for mode in MirrorQualityMode.allCases {
      qualityPopup.addItem(withTitle: mode.title)
      qualityPopup.lastItem?.representedObject = mode.rawValue
    }
    updateQualityControls()
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

  @objc private func deviceSelectionChanged(_ sender: Any?) {
    guard let deviceID = devicePopup.selectedItem?.representedObject as? String,
      deviceID != assignment.selectedDeviceID
    else {
      updateDeviceMenu()
      return
    }
    onDeviceSelectionRequested?(deviceID)
  }

  @objc private func qualitySelectionChanged(_ sender: Any?) {
    guard let rawValue = qualityPopup.selectedItem?.representedObject as? String,
      let mode = MirrorQualityMode(rawValue: rawValue)
    else {
      updateQualityControls()
      return
    }
    selectQualityMode(mode)
  }

  @objc func selectAutomaticQuality(_ sender: Any?) {
    selectQualityMode(.automatic)
  }

  @objc func selectQualityQuality(_ sender: Any?) {
    selectQualityMode(.quality)
  }

  @objc func selectBalancedQuality(_ sender: Any?) {
    selectQualityMode(.balanced)
  }

  @objc func selectPerformanceQuality(_ sender: Any?) {
    selectQualityMode(.performance)
  }

  var selectedQualityMode: MirrorQualityMode { qualityMode }

  private func selectQualityMode(_ mode: MirrorQualityMode) {
    qualityMode = mode
    qualityPreferences.defaultMode = mode
    if let adjustableSource = source as? any QualityAdjustableMirrorSource {
      adjustableSource.setQualityMode(mode)
      displayedQualityState = adjustableSource.qualityState
    } else {
      displayedQualityState = MirrorQualityState(
        mode: mode,
        effectiveLevel: nil,
        isAdjusting: false,
        limitation: nil
      )
    }
    updateQualityControls()
  }

  private func updateQualityControls() {
    let displayTitle: String
    if displayedQualityState.isAdjusting {
      displayTitle = "\(qualityMode.title) · Adjusting…"
    } else if qualityMode == .automatic,
      let effectiveLevel = displayedQualityState.effectiveLevel
    {
      displayTitle = "Auto · \(effectiveLevel.title)"
    } else if let requestedLevel = qualityMode.fixedLevel,
      let effectiveLevel = displayedQualityState.effectiveLevel,
      requestedLevel != effectiveLevel
    {
      displayTitle = "\(qualityMode.title) · \(effectiveLevel.title)"
    } else {
      displayTitle = qualityMode.title
    }

    for item in qualityPopup.itemArray {
      guard let rawValue = item.representedObject as? String,
        let mode = MirrorQualityMode(rawValue: rawValue)
      else { continue }
      item.title = mode == .automatic && qualityMode == .automatic ? displayTitle : mode.title
      item.state = mode == qualityMode ? .on : .off
    }
    if let selectedItem = qualityPopup.itemArray.first(where: {
      ($0.representedObject as? String) == qualityMode.rawValue
    }) {
      qualityPopup.select(selectedItem)
    }
    qualityPopup.isEnabled = !isPreparingToClose
    qualityPopup.toolTip = displayedQualityState.limitation ?? "Capture quality profile"
    qualityPopup.setAccessibilityLabel(displayTitle)
  }

  func apply(assignment newAssignment: MirrorWindowAssignment) {
    let previousAssignment = assignment
    receivesCoordinatedAssignments = true
    assignment = newAssignment
    updateDeviceMenu()
    updateWindowTitle()
    updateRecordingAction()

    if newAssignment.selectedDevice == nil || !newAssignment.isSelectedDeviceConnected {
      setTitlebarVisible(true)
    }

    guard !newAssignment.isTransitioning, !isPreparingDeviceSwitch, !isPreparingToClose else {
      return
    }

    guard let selectedDevice = newAssignment.selectedDevice else {
      if previousAssignment.selectedDevice != nil || source != nil || connectionTask != nil {
        disconnectSelectedDevice(showDisconnectedReservation: false)
      } else {
        showDefaultScreen()
      }
      return
    }

    guard newAssignment.isSelectedDeviceConnected else {
      if previousAssignment.isSelectedDeviceConnected || source != nil || connectionTask != nil {
        disconnectSelectedDevice(showDisconnectedReservation: true)
      } else if disconnectionTask == nil {
        showDisconnectedScreen(deviceName: selectedDevice.name)
      }
      return
    }

    disconnectionTask?.cancel()
    if sourceDeviceID != selectedDevice.id && connectionTask == nil
      && disconnectionTask == nil && restartTask == nil
    {
      connect(to: selectedDevice)
    }
  }

  private func updateDeviceMenu() {
    devicePopup.removeAllItems()
    if assignment.selectedDevice == nil {
      devicePopup.addItem(withTitle: "No device")
      devicePopup.lastItem?.isEnabled = false
    }

    for option in assignment.options {
      let suffix: String
      switch option.state {
      case .selected, .available:
        suffix = ""
      case .inAnotherWindow:
        suffix = " — In Another Window"
      case .disconnected:
        suffix = " — Disconnected"
      case .switching:
        suffix = " — Switching…"
      }
      devicePopup.addItem(withTitle: option.device.name + suffix)
      guard let item = devicePopup.lastItem else { continue }
      item.representedObject = option.device.id
      item.isEnabled = option.state == .available
    }

    devicePopup.isEnabled = !assignment.isTransitioning && !assignment.options.isEmpty
    if let selectedDeviceID = assignment.selectedDeviceID,
      let selectedItem = devicePopup.itemArray.first(where: {
        ($0.representedObject as? String) == selectedDeviceID
      })
    {
      devicePopup.select(selectedItem)
    } else if assignment.selectedDevice == nil {
      devicePopup.selectItem(at: 0)
    }
  }

  private func updateWindowTitle() {
    if let device = assignment.selectedDevice {
      window?.title = "MirrorPhone — \(device.name)"
    } else {
      window?.title = "MirrorPhone"
    }
  }

  private func connect(to device: MirrorDevice, preserveFrame: Bool = false) {
    guard assignment.selectedDeviceID == device.id,
      assignment.isSelectedDeviceConnected,
      !assignment.isTransitioning,
      !isPreparingDeviceSwitch,
      !isPreparingToClose
    else { return }

    connectionGeneration += 1
    let generation = connectionGeneration
    let priorConnectionTask = connectionTask
    priorConnectionTask?.cancel()
    let previousSource = source
    invalidateClipboardBinding()
    source = nil
    sourceDeviceID = nil
    resetQualityStateForNoSource()
    updateRecordingAction()
    mirrorView.resetInputState()
    mirrorView.onInput = nil
    receivedFirstFrame = false
    reportedFrameSize = nil
    if !preserveFrame {
      mirrorView.showLoading(deviceName: device.name)
    }
    setStatus("Connecting to \(device.name) by USB")

    connectionTask = Task { @MainActor [weak self] in
      await priorConnectionTask?.value
      await previousSource?.stop()
      guard let self, !Task.isCancelled,
        connectionGeneration == generation,
        assignment.selectedDeviceID == device.id,
        assignment.isSelectedDeviceConnected
      else { return }

      let newSource = sourceFactory.makeSource(for: device)
      configure(source: newSource, for: device)

      do {
        try await newSource.start()
        guard !Task.isCancelled,
          connectionGeneration == generation,
          assignment.selectedDeviceID == device.id,
          assignment.isSelectedDeviceConnected
        else {
          await newSource.stop()
          if connectionGeneration == generation {
            invalidateClipboardBinding()
            source = nil
            sourceDeviceID = nil
            resetQualityStateForNoSource()
            updateRecordingAction()
          }
          return
        }
      } catch {
        await newSource.stop()
        if connectionGeneration == generation {
          invalidateClipboardBinding()
          source = nil
          sourceDeviceID = nil
          resetQualityStateForNoSource()
          updateRecordingAction()
          setStatus(error.localizedDescription)
          present(error: error)
        }
      }
      if connectionGeneration == generation {
        connectionTask = nil
      }
    }
  }

  private func configure(source newSource: any MirrorSource, for device: MirrorDevice) {
    invalidateClipboardBinding()
    source = newSource
    sourceDeviceID = device.id
    newSource.onFrame = { [weak self] frame in
      guard let self, sourceDeviceID == device.id,
        assignment.selectedDeviceID == device.id || isPreparingDeviceSwitch
      else { return }
      mirrorView.show(frame: frame)
      fitWindowToDisplayedFrameIfNeeded()
      let frameSize = CGSize(width: frame.width, height: frame.height)
      if !receivedFirstFrame || reportedFrameSize != frameSize {
        if !receivedFirstFrame, case .iosScreen = device.kind {
          onIOSCaptureLive?(device.id)
        }
        receivedFirstFrame = true
        reportedFrameSize = frameSize
        updateRecordingAction()
        setStatus("Live · \(device.name) · \(frame.width) × \(frame.height)")
      }
    }
    newSource.onStatus = { [weak self] message in
      guard let self, sourceDeviceID == device.id else { return }
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
    configureClipboardBridge(for: newSource)
    if let adjustableSource = newSource as? any QualityAdjustableMirrorSource {
      let sourceIdentity = ObjectIdentifier(newSource)
      adjustableSource.onQualityStateChanged = { [weak self] state in
        guard let self, let source,
          ObjectIdentifier(source) == sourceIdentity
        else { return }
        displayedQualityState = state
        updateQualityControls()
      }
      adjustableSource.setQualityMode(qualityMode)
      displayedQualityState = adjustableSource.qualityState
    } else {
      resetQualityStateForNoSource()
    }
    updateQualityControls()
    updateRecordingAction()
  }

  private func configureClipboardBridge(for newSource: any MirrorSource) {
    guard let bridge = newSource.clipboardBridge else {
      NSApp.mainMenu?.update()
      return
    }
    let sourceIdentity = ObjectIdentifier(newSource)
    bridge.onClipboardStateChanged = { [weak self] _ in
      guard let self, let source, ObjectIdentifier(source) == sourceIdentity else { return }
      NSApp.mainMenu?.update()
    }
    bridge.onClipboardContentChanged = { [weak self] content in
      guard let self else { return }
      handleAutomaticClipboardContent(content, sourceIdentity: sourceIdentity)
    }
    NSApp.mainMenu?.update()
  }

  private func invalidateClipboardBinding() {
    source?.clipboardBridge?.onClipboardStateChanged = nil
    source?.clipboardBridge?.onClipboardContentChanged = nil
    clipboardGeneration += 1
    clipboardTask?.cancel()
    clipboardTask = nil
    NSApp.mainMenu?.update()
  }

  private func handleAutomaticClipboardContent(
    _ content: DeviceClipboardContent,
    sourceIdentity: ObjectIdentifier
  ) {
    let isSourceCurrent = source.map { ObjectIdentifier($0) == sourceIdentity } ?? false
    guard MirrorClipboardActivationPolicy.acceptsAutomaticUpdate(
      isApplicationActive: applicationIsActive(),
      isWindowKey: windowIsKeyOverride?() ?? window?.isKeyWindow == true,
      isSourceCurrent: isSourceCurrent,
      isDeviceConnected: assignment.isSelectedDeviceConnected,
      isTransitioning: assignment.isTransitioning || isPreparingDeviceSwitch,
      isClosing: isPreparingToClose
    ) else { return }
    try? applyClipboardContent(content, explicit: false)
  }

  private func applyClipboardContent(
    _ content: DeviceClipboardContent,
    explicit: Bool
  ) throws {
    switch content {
    case .text(let text):
      // ClipboardManager may report the same value more than once while Android
      // classifies it. Avoid replacing matching rich Mac pasteboard types with
      // a plain-text-only representation.
      guard pasteboard.plainText != text else { return }
      guard pasteboard.replacePlainText(with: text) else {
        throw DeviceClipboardError.pasteboardWriteFailed
      }
    case .empty:
      guard pasteboard.replacePlainText(with: nil) else {
        throw DeviceClipboardError.pasteboardWriteFailed
      }
    case .unsupported:
      if explicit {
        NSSound.beep()
      }
    }
  }

  private func resetQualityStateForNoSource() {
    displayedQualityState = MirrorQualityState(
      mode: qualityMode,
      effectiveLevel: nil,
      isAdjusting: false,
      limitation: nil
    )
    updateQualityControls()
  }

  private func stopConnectionImmediately(clearFrame: Bool) async {
    connectionGeneration += 1
    let generation = connectionGeneration
    let priorConnectionTask = connectionTask
    connectionTask = nil
    priorConnectionTask?.cancel()
    await priorConnectionTask?.value
    guard connectionGeneration == generation else { return }

    mirrorView.resetInputState()
    mirrorView.onInput = nil
    let previousSource = source
    invalidateClipboardBinding()
    source = nil
    sourceDeviceID = nil
    resetQualityStateForNoSource()
    updateRecordingAction()
    await previousSource?.stop()
    guard connectionGeneration == generation else { return }
    if clearFrame {
      showDefaultScreen()
    }
  }

  private func disconnectSelectedDevice(showDisconnectedReservation: Bool) {
    guard disconnectionTask == nil else { return }
    let pendingRestart = restartTask
    pendingRestart?.cancel()
    disconnectionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await pendingRestart?.value
      restartTask = nil
      _ = await finishRecording()
      guard !Task.isCancelled else {
        disconnectionTask = nil
        reconnectAssignedDeviceIfNeeded()
        return
      }
      await stopConnectionImmediately(clearFrame: !showDisconnectedReservation)
      guard !Task.isCancelled else {
        disconnectionTask = nil
        reconnectAssignedDeviceIfNeeded()
        return
      }

      if showDisconnectedReservation,
        let selectedDevice = assignment.selectedDevice,
        !assignment.isSelectedDeviceConnected
      {
        showDisconnectedScreen(deviceName: selectedDevice.name)
      }
      disconnectionTask = nil
      reconnectAssignedDeviceIfNeeded()
    }
  }

  func prepareForDeviceSwitch() async -> Bool {
    guard !isPreparingDeviceSwitch, !isPreparingToClose else { return false }
    isPreparingDeviceSwitch = true
    updateRecordingAction()
    defer {
      isPreparingDeviceSwitch = false
      updateRecordingAction()
    }

    await cancelPendingSourceTransitions()
    guard await finishRecording(), !Task.isCancelled, !isPreparingToClose else {
      return false
    }
    await stopConnectionImmediately(clearFrame: false)
    return !Task.isCancelled && !isPreparingToClose
  }

  func prepareForDeviceSwitch(to targetDevice: MirrorDevice) async -> Bool {
    guard !isPreparingDeviceSwitch, !isPreparingToClose else { return false }
    isPreparingDeviceSwitch = true
    updateRecordingAction()
    defer {
      isPreparingDeviceSwitch = false
      updateRecordingAction()
    }

    await cancelPendingSourceTransitions()
    guard await finishRecording(), !Task.isCancelled, !isPreparingToClose else {
      return false
    }
    await stopConnectionImmediately(clearFrame: false)
    guard !Task.isCancelled, !isPreparingToClose,
      assignment.pendingDeviceID == targetDevice.id
    else { return false }
    return await startPreparedSwitchSource(for: targetDevice)
  }

  private func startPreparedSwitchSource(for device: MirrorDevice) async -> Bool {
    connectionGeneration += 1
    let generation = connectionGeneration
    receivedFirstFrame = false
    reportedFrameSize = nil
    mirrorView.resetInputState()
    mirrorView.onInput = nil
    mirrorView.showLoading(deviceName: device.name)
    setStatus("Connecting to \(device.name) by USB")

    let newSource = sourceFactory.makeSource(for: device)
    configure(source: newSource, for: device)
    do {
      try await newSource.start()
      guard !Task.isCancelled, !isPreparingToClose,
        connectionGeneration == generation,
        assignment.pendingDeviceID == device.id
      else {
        await newSource.stop()
        if connectionGeneration == generation, sourceDeviceID == device.id {
          invalidateClipboardBinding()
          source = nil
          sourceDeviceID = nil
          resetQualityStateForNoSource()
          updateRecordingAction()
        }
        return false
      }
      return true
    } catch {
      await newSource.stop()
      if connectionGeneration == generation, sourceDeviceID == device.id {
        invalidateClipboardBinding()
        source = nil
        sourceDeviceID = nil
        resetQualityStateForNoSource()
        updateRecordingAction()
        setStatus(error.localizedDescription)
        present(error: error)
      }
      return false
    }
  }

  func restartIOSCapture(deviceID: String) {
    guard assignment.selectedDeviceID == deviceID,
      assignment.isSelectedDeviceConnected,
      !assignment.isTransitioning,
      !isPreparingDeviceSwitch,
      !isPreparingToClose,
      disconnectionTask == nil,
      restartTask == nil
    else { return }

    restartTask = Task { @MainActor [weak self] in
      guard let self, await finishRecording(), !Task.isCancelled else {
        self?.restartTask = nil
        self?.reconnectAssignedDeviceIfNeeded()
        return
      }
      await stopConnectionImmediately(clearFrame: false)
      restartTask = nil
      guard !Task.isCancelled,
        assignment.selectedDeviceID == deviceID,
        let device = assignment.selectedDevice
      else { return }
      guard assignment.isSelectedDeviceConnected else {
        showDisconnectedScreen(deviceName: device.name)
        return
      }
      connect(to: device, preserveFrame: true)
    }
  }

  private func cancelPendingSourceTransitions() async {
    let pendingDisconnection = disconnectionTask
    let pendingRestart = restartTask
    pendingDisconnection?.cancel()
    pendingRestart?.cancel()
    await pendingDisconnection?.value
    await pendingRestart?.value
    disconnectionTask = nil
    restartTask = nil
  }

  private func reconnectAssignedDeviceIfNeeded() {
    guard disconnectionTask == nil, restartTask == nil, connectionTask == nil,
      sourceDeviceID == nil,
      !assignment.isTransitioning, !isPreparingDeviceSwitch, !isPreparingToClose,
      assignment.isSelectedDeviceConnected, let device = assignment.selectedDevice
    else { return }
    connect(to: device)
  }

  private func showDefaultScreen() {
    rememberCurrentViewerSize()
    receivedFirstFrame = false
    reportedFrameSize = nil
    mirrorAspectRatio = nil
    mirrorView.clear()
    updateRecordingAction()
    restorePortraitWindow()
  }

  private func showDisconnectedScreen(deviceName: String) {
    rememberCurrentViewerSize()
    receivedFirstFrame = false
    reportedFrameSize = nil
    mirrorAspectRatio = nil
    mirrorView.showDisconnected(deviceName: deviceName)
    updateRecordingAction()
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

  @objc func copyFromAndroid(_ sender: Any?) {
    performClipboardSelection(.copy)
  }

  @objc func cutFromAndroid(_ sender: Any?) {
    performClipboardSelection(.cut)
  }

  @objc func pasteToAndroid(_ sender: Any?) {
    guard clipboardTask == nil, let bridge = clipboardBridgeForAction else {
      NSSound.beep()
      return
    }
    guard let text = pasteboard.plainText else {
      NSSound.beep()
      return
    }

    let generation = clipboardGeneration
    let bridgeIdentity = ObjectIdentifier(bridge)
    clipboardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finishClipboardTask(generation: generation) }
      do {
        try await bridge.paste(text)
      } catch {
        guard !Task.isCancelled,
          isCurrentClipboardBridge(identity: bridgeIdentity, generation: generation)
        else { return }
        presentClipboardFailure(error, action: "Paste to Android")
      }
    }
    NSApp.mainMenu?.update()
  }

  private func performClipboardSelection(_ operation: DeviceClipboardSelectionOperation) {
    guard clipboardTask == nil, let bridge = clipboardBridgeForAction else {
      NSSound.beep()
      return
    }

    let generation = clipboardGeneration
    let bridgeIdentity = ObjectIdentifier(bridge)
    clipboardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finishClipboardTask(generation: generation) }
      do {
        let content = try await bridge.readSelection(operation)
        guard !Task.isCancelled,
          isCurrentClipboardBridge(identity: bridgeIdentity, generation: generation)
        else { return }
        try applyClipboardContent(content, explicit: true)
      } catch {
        guard !Task.isCancelled,
          isCurrentClipboardBridge(identity: bridgeIdentity, generation: generation)
        else { return }
        presentClipboardFailure(
          error,
          action: operation == .copy ? "Copy from Android" : "Cut from Android"
        )
      }
    }
    NSApp.mainMenu?.update()
  }

  private var clipboardBridgeForAction: (any DeviceClipboardBridge)? {
    guard assignment.isSelectedDeviceConnected,
      !assignment.isTransitioning,
      !isPreparingDeviceSwitch,
      !isPreparingToClose,
      let bridge = source?.clipboardBridge,
      bridge.clipboardState.isAvailable
    else { return nil }
    return bridge
  }

  private func isCurrentClipboardBridge(identity: ObjectIdentifier, generation: Int) -> Bool {
    guard clipboardGeneration == generation, let bridge = source?.clipboardBridge else {
      return false
    }
    return ObjectIdentifier(bridge) == identity
  }

  private func finishClipboardTask(generation: Int) {
    guard clipboardGeneration == generation else { return }
    clipboardTask = nil
    NSApp.mainMenu?.update()
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

  @objc func toggleRecording(_ sender: Any?) {
    if recorder != nil || recordingFinishTask != nil {
      Task { [weak self] in
        _ = await self?.finishRecording()
      }
      return
    }
    guard !savePanelOpen,
      !assignment.isTransitioning,
      !isPreparingDeviceSwitch,
      !isPreparingToClose,
      mirrorView.displayedFrame != nil,
      source is any RecordableMirrorSource,
      let window
    else {
      if mirrorView.displayedFrame == nil {
        present(error: MirrorPhoneError.noFrame)
      }
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue =
      "MirrorPhone \(Self.filenameDateFormatter.string(from: Date())).mp4"
    savePanelOpen = true
    updateRecordingAction()
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      savePanelOpen = false
      updateRecordingAction()
      guard response == .OK, let destinationURL = panel.url else { return }
      startRecording(at: destinationURL)
    }
  }

  private func startRecording(at destinationURL: URL) {
    guard recorder == nil, recordingFinishTask == nil,
      let frame = mirrorView.displayedFrame,
      let recordableSource = source as? any RecordableMirrorSource
    else { return }

    recordingGeneration += 1
    let generation = recordingGeneration
    do {
      let recorder = try MP4Recorder(
        destinationURL: destinationURL,
        canvasSize: CGSize(width: frame.width, height: frame.height)
      ) { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self, recordingGeneration == generation else { return }
          recordingAudioState = state
          updateRecordingOverlay()
        }
      }
      try recorder.start()
      self.recorder = recorder
      recordingTap = recordableSource.recordingTap
      recordingStartedAt = .now
      recordingAudioState = .pending
      recordingStatusDismissTask?.cancel()
      recordableSource.recordingTap.attach(recorder)
      startRecordingTimer()
      updateRecordingAction()
      updateRecordingOverlay()
    } catch {
      presentRecordingFailure(error, destinationURL: destinationURL)
    }
  }

  private func startRecordingTimer() {
    recordingTimerTask?.cancel()
    recordingTimerTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, recorder != nil, recordingFinishTask == nil else { return }
        updateRecordingOverlay()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func updateRecordingOverlay() {
    guard let started = recordingStartedAt, recorder != nil, recordingFinishTask == nil else {
      return
    }
    mirrorView.showRecording(
      elapsed: started.duration(to: .now),
      audioState: recordingAudioState
    )
  }

  @discardableResult
  func finishRecording() async -> Bool {
    if let recordingFinishTask {
      return await recordingFinishTask.value
    }
    guard let recorder else { return true }

    recordingTap?.detach(recorder)
    recordingTimerTask?.cancel()
    recordingTimerTask = nil
    mirrorView.showRecordingFinishing()
    updateRecordingAction(finishing: true)
    let destinationURL = recorderDestinationURL(recorder)

    let task = Task { @MainActor [weak self] () -> Bool in
      do {
        let result = try await recorder.finish()
        guard let self else { return true }
        completeRecording(success: true)
        showSavedStatus()
        if result.droppedVideoFrameCount > 0 {
          setStatus("Saved with \(result.droppedVideoFrameCount) overloaded video frames dropped")
        }
        return true
      } catch {
        guard let self else { return false }
        completeRecording(success: false)
        presentRecordingFailure(error, destinationURL: destinationURL)
        return false
      }
    }
    recordingFinishTask = task
    return await task.value
  }

  private func completeRecording(success: Bool) {
    recorder = nil
    recordingTap = nil
    recordingStartedAt = nil
    recordingFinishTask = nil
    recordingAudioState = .pending
    updateRecordingAction()
    if !success {
      mirrorView.hideRecordingStatus()
    }
  }

  private func showSavedStatus() {
    mirrorView.showRecordingSaved()
    recordingStatusDismissTask?.cancel()
    recordingStatusDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let self, recorder == nil else { return }
      mirrorView.hideRecordingStatus()
    }
  }

  private func updateRecordingAction(finishing: Bool = false) {
    let isRecording = recorder != nil
    let isFinishing = finishing || recordingFinishTask != nil
    let canStart =
      mirrorView.displayedFrame != nil && source is any RecordableMirrorSource && !savePanelOpen
      && !assignment.isTransitioning && !isPreparingDeviceSwitch && !isPreparingToClose
    recordButton.isEnabled = !isFinishing && (isRecording || canStart)
    let title: String
    let symbol: String
    if isFinishing {
      title = "Finishing…"
      symbol = "hourglass"
    } else if isRecording {
      title = "Stop recording"
      symbol = "stop.circle.fill"
    } else {
      title = "Start recording…"
      symbol = "record.circle"
    }
    recordButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    recordButton.contentTintColor = isRecording && !isFinishing ? .systemRed : nil
    recordButton.toolTip = title
    recordButton.setAccessibilityLabel(title)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(copyFromAndroid(_:))
      || menuItem.action == #selector(cutFromAndroid(_:))
    {
      return clipboardTask == nil && clipboardBridgeForAction != nil
    }
    if menuItem.action == #selector(pasteToAndroid(_:)) {
      return clipboardTask == nil && clipboardBridgeForAction != nil && pasteboard.plainText != nil
    }
    if menuItem.action == #selector(toggleRecording(_:)) {
      if recordingFinishTask != nil {
        menuItem.title = "Finishing…"
        return false
      }
      if recorder != nil {
        menuItem.title = "Stop Recording"
        return true
      }
      menuItem.title = "Start Recording…"
      return mirrorView.displayedFrame != nil && source is any RecordableMirrorSource && !savePanelOpen
        && !assignment.isTransitioning && !isPreparingDeviceSwitch && !isPreparingToClose
    }
    if menuItem.action == #selector(captureImage(_:)) {
      return mirrorView.displayedFrame != nil
    }
    if let mode = qualityMode(for: menuItem.action) {
      menuItem.state = mode == qualityMode ? .on : .off
      return !isPreparingToClose
    }
    return true
  }

  private func qualityMode(for action: Selector?) -> MirrorQualityMode? {
    switch action {
    case #selector(selectAutomaticQuality(_:)): .automatic
    case #selector(selectQualityQuality(_:)): .quality
    case #selector(selectBalancedQuality(_:)): .balanced
    case #selector(selectPerformanceQuality(_:)): .performance
    default: nil
    }
  }

  var hasRecordingToFinalize: Bool {
    recorder != nil || recordingFinishTask != nil
  }

  func finalizeRecordingForTermination() async -> Bool {
    return await finishRecording()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowWindowClose { return true }
    guard !closeRequested else { return false }
    closeRequested = true
    isPreparingToClose = true
    updateRecordingAction()
    updateQualityControls()
    onWindowCloseRequested?()
    Task { @MainActor [weak self, weak sender] in
      guard let self else { return }
      await cancelPendingSourceTransitions()
      let succeeded = await finishRecording()
      if succeeded {
        await stopConnectionImmediately(clearFrame: false)
      }
      isPreparingToClose = false
      updateRecordingAction()
      updateQualityControls()
      closeRequested = false
      guard succeeded, let sender else { return }
      allowWindowClose = true
      sender.performClose(nil)
    }
    return false
  }

  func windowWillClose(_ notification: Notification) {
    titlebarMonitorTask?.cancel()
    titlebarMonitorTask = nil
    disconnectionTask?.cancel()
    restartTask?.cancel()
    connectionTask?.cancel()
    recordingTimerTask?.cancel()
    recordingStatusDismissTask?.cancel()
    let remainingSource = source
    invalidateClipboardBinding()
    source = nil
    sourceDeviceID = nil
    resetQualityStateForNoSource()
    Task { [remainingSource] in
      await remainingSource?.stop()
    }
    onWindowClosed?()
    onWindowClosed = nil
    onWindowCloseRequested = nil
    onDeviceSelectionRequested = nil
    onIOSCaptureLive = nil
  }

  private func presentRecordingFailure(_ error: Error, destinationURL: URL) {
    guard let window else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "The recording could not be saved"
    alert.informativeText =
      "\(error.localizedDescription)\n\nAny existing file was left unchanged. Check free space or choose another folder and try again."
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Show Folder")
    alert.beginSheetModal(for: window) { response in
      if response == .alertSecondButtonReturn {
        NSWorkspace.shared.open(destinationURL.deletingLastPathComponent())
      }
    }
  }

  private func recorderDestinationURL(_ recorder: MP4Recorder) -> URL {
    recorder.outputURL
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
      if !inKeepBand, !isTitlebarPickerHighlighted {
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
    if inKeepBand || isTitlebarPickerHighlighted {
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

  private var isTitlebarPickerHighlighted: Bool {
    devicePopup.cell?.isHighlighted == true || qualityPopup.cell?.isHighlighted == true
  }

  func setTitlebarVisible(_ visible: Bool) {
    let effectiveVisibility = visible || shouldKeepTitlebarVisible
    guard isTitlebarVisible != effectiveVisibility else { return }
    isTitlebarVisible = effectiveVisibility
    applyTitlebarState(visible: effectiveVisibility)
  }

  private var shouldKeepTitlebarVisible: Bool {
    receivesCoordinatedAssignments
      && (assignment.selectedDevice == nil || !assignment.isSelectedDeviceConnected)
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

  private func presentClipboardFailure(_ error: Error, action: String) {
    guard let window, !isPreparingToClose else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(action) failed"
    alert.informativeText =
      "\(error.localizedDescription)\n\nControl-C, Control-X, and Control-V still send raw Android shortcuts when an app needs keyboard-specific behavior."
    alert.addButton(withTitle: "OK")
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
    guard source == nil, connectionTask == nil,
      assignment.isSelectedDeviceConnected,
      let device = assignment.selectedDevice
    else { return }
    connect(to: device)
  }

  private static let filenameDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()

}
