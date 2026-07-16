import AppKit

extension CGImage {
  var aspectRatio: CGFloat {
    CGFloat(width) / CGFloat(height)
  }
}

enum MirrorLayout {
  static func widthFillingRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0 else { return .zero }
    let scale = bounds.width / imageSize.width
    let size = CGSize(width: bounds.width, height: imageSize.height * scale)
    return CGRect(
      x: bounds.minX,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  /// Inverse of `widthFillingRect`: maps a point in view coordinates to a pixel
  /// in the device frame. The view is not flipped, so device y=0 (image top)
  /// corresponds to `rect.maxY`. Coordinates are clamped into the frame.
  /// Returns `nil` if nothing is drawn.
  static func devicePoint(
    viewPoint: CGPoint, imageSize: CGSize, in bounds: CGRect
  ) -> CGPoint? {
    let rect = widthFillingRect(imageSize: imageSize, in: bounds)
    guard rect.width > 0, rect.height > 0, imageSize.width > 0 else { return nil }
    let scale = imageSize.width / rect.width
    return CGPoint(
      x: min(max((viewPoint.x - rect.minX) * scale, 0), imageSize.width - 1),
      y: min(max((rect.maxY - viewPoint.y) * scale, 0), imageSize.height - 1)
    )
  }

  static func restoredWindowFrame(
    currentFrame: CGRect,
    portraitSize: CGSize,
    visibleFrame: CGRect
  ) -> CGRect {
    constrainedWindowFrame(
      CGRect(
        x: currentFrame.midX - portraitSize.width / 2,
        y: currentFrame.maxY - portraitSize.height,
        width: portraitSize.width,
        height: portraitSize.height
      ),
      visibleFrame: visibleFrame
    )
  }

  static func constrainedWindowFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
    let width = min(frame.width, visibleFrame.width)
    let height = min(frame.height, visibleFrame.height)
    let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
    let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}

struct MirrorWindowSizeMemory {
  private var portraitSize: CGSize?
  private var landscapeSize: CGSize?

  mutating func remember(viewerSize: CGSize, aspectRatio: CGFloat) {
    guard viewerSize.width > 0, viewerSize.height > 0 else { return }
    if aspectRatio > 1 {
      landscapeSize = viewerSize
    } else {
      portraitSize = viewerSize
    }
  }

  func size(for aspectRatio: CGFloat) -> CGSize? {
    aspectRatio > 1 ? landscapeSize : portraitSize
  }
}

@MainActor
final class MirrorView: NSView {
  private(set) var displayedFrame: CGImage?
  /// Forwards platform-neutral mouse and keyboard input. `nil` when the active
  /// source can't accept input, which leaves normal responder behavior intact.
  var onInput: ((DeviceInputEvent) -> Void)?
  private let scrollMapper = ScrollSwipeMapper()
  private var dragActive = false
  /// macOS keycodes currently held that were forwarded as key-downs, so their
  /// key-ups are forwarded too (and only those).
  private var forwardedKeys: [UInt16: DeviceKey] = [:]
  private let tutorial = NSStackView()
  private let loading = NSStackView()
  private let loadingIndicator = NSProgressIndicator()
  private let loadingLabel = NSTextField(labelWithString: "")

  /// How many view points a wheel "line" (non-precise scroll) maps to before
  /// conversion to device pixels. Precise trackpad deltas use ×1 directly.
  private static let wheelStep: CGFloat = 12
  private static let preciseSensitivity: CGFloat = 1

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureTutorial()
    scrollMapper.emit = { [weak self] phase, point, frame in
      self?.emitTouch(phase, point: point, referenceSize: frame)
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureTutorial()
    scrollMapper.emit = { [weak self] phase, point, frame in
      self?.emitTouch(phase, point: point, referenceSize: frame)
    }
  }

  override var isOpaque: Bool { true }

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var frameSize: CGSize? {
    guard let image = displayedFrame else { return nil }
    return CGSize(width: image.width, height: image.height)
  }

  // MARK: - Mouse forwarding

  override func mouseDown(with event: NSEvent) {
    guard onInput != nil, let size = frameSize else { return super.mouseDown(with: event) }
    let point = convert(event.locationInWindow, from: nil)
    let rect = MirrorLayout.widthFillingRect(imageSize: size, in: bounds)
    // A click outside the drawn frame (letterbox) is ignored, not clamped.
    guard rect.contains(point),
      let device = MirrorLayout.devicePoint(viewPoint: point, imageSize: size, in: bounds)
    else { return }
    scrollMapper.finishImmediately()
    dragActive = true
    emitTouch(.down, point: device, referenceSize: size)
  }

  override func mouseDragged(with event: NSEvent) {
    guard dragActive, onInput != nil, let size = frameSize else {
      return super.mouseDragged(with: event)
    }
    let point = convert(event.locationInWindow, from: nil)
    guard let device = MirrorLayout.devicePoint(viewPoint: point, imageSize: size, in: bounds)
    else { return }
    emitTouch(.move, point: device, referenceSize: size)
  }

  override func mouseUp(with event: NSEvent) {
    guard dragActive, onInput != nil, let size = frameSize else {
      return super.mouseUp(with: event)
    }
    dragActive = false
    let point = convert(event.locationInWindow, from: nil)
    let device =
      MirrorLayout.devicePoint(viewPoint: point, imageSize: size, in: bounds)
      ?? CGPoint(x: 0, y: 0)
    emitTouch(.up, point: device, referenceSize: size)
  }

  override func scrollWheel(with event: NSEvent) {
    // A mouse drag owns the finger; ignore scroll until it ends.
    guard !dragActive, onInput != nil, let size = frameSize else {
      return super.scrollWheel(with: event)
    }
    let point = convert(event.locationInWindow, from: nil)
    let rect = MirrorLayout.widthFillingRect(imageSize: size, in: bounds)
    guard rect.contains(point),
      let cursor = MirrorLayout.devicePoint(viewPoint: point, imageSize: size, in: bounds)
    else { return }

    let scale = size.width / rect.width
    let sensitivity = event.hasPreciseScrollingDeltas ? Self.preciseSensitivity : Self.wheelStep
    // scrollingDelta already reflects the user's natural-scrolling preference;
    // the finger moves the same way, so device content follows the cursor.
    // scrollingDeltaY is positive when content should move down (finger swipes
    // down), and device y grows downward, so the sign maps directly.
    let delta = CGVector(
      dx: event.scrollingDeltaX * sensitivity * scale,
      dy: event.scrollingDeltaY * sensitivity * scale
    )
    let momentumEnded = event.momentumPhase == .ended || event.phase == .cancelled
    scrollMapper.handleScroll(
      delta: delta, cursor: cursor, frame: size, momentumEnded: momentumEnded)
  }

  // MARK: - Keyboard forwarding

  override func keyDown(with event: NSEvent) {
    guard onInput != nil, displayedFrame != nil else {
      return super.keyDown(with: event)
    }
    let modifiers = MacInputMap.modifiers(from: event.modifierFlags)

    if let key = MacInputMap.specialKey(macKeyCode: event.keyCode) {
      if !event.isARepeat {
        forwardedKeys[event.keyCode] = key
      }
      onInput?(.key(DeviceKeyEvent(phase: .down, key: key, modifiers: modifiers)))
      return
    }

    // Preserve shortcut keys and modifiers so each platform can translate them.
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
      let character = event.charactersIgnoringModifiers?.first,
      let key = MacInputMap.shortcutKey(for: character)
    {
      if !event.isARepeat {
        forwardedKeys[event.keyCode] = key
      }
      onInput?(.key(DeviceKeyEvent(phase: .down, key: key, modifiers: modifiers)))
      return
    }

    if let text = MacInputMap.textToType(from: event) {
      onInput?(.text(text))
      return
    }

    super.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    guard let key = forwardedKeys.removeValue(forKey: event.keyCode) else {
      return super.keyUp(with: event)
    }
    onInput?(
      .key(
        DeviceKeyEvent(
          phase: .up,
          key: key,
          modifiers: MacInputMap.modifiers(from: event.modifierFlags)
        )
      )
    )
  }

  /// Abandon any in-flight gesture (source teardown, injector restart).
  func resetInputState() {
    if dragActive {
      dragActive = false
      if let size = frameSize {
        emitTouch(.cancel, point: .zero, referenceSize: size)
      }
    }
    scrollMapper.cancel()
    forwardedKeys.removeAll()
  }

  private func emitTouch(_ phase: TouchPhase, point: CGPoint, referenceSize: CGSize) {
    guard
      let event = DeviceTouchEvent(
        phase: phase,
        point: point,
        referenceSize: referenceSize
      )
    else { return }
    onInput?(.touch(event))
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.setFill()
    dirtyRect.fill()

    guard let image = displayedFrame,
      let context = NSGraphicsContext.current?.cgContext
    else { return }

    let imageSize = CGSize(width: image.width, height: image.height)
    // Fill the viewer horizontally. Window sizing keeps the full frame visible;
    // this width-first fallback prevents pillar bars if macOS constrains the height.
    let rect = MirrorLayout.widthFillingRect(imageSize: imageSize, in: bounds)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
  }

  func show(frame: CGImage) {
    // A frame-size change means the device rotated (screenrecord restarted);
    // abandon any in-flight gesture so it isn't continued in the new geometry.
    if let previous = displayedFrame,
      previous.width != frame.width || previous.height != frame.height,
      dragActive || scrollMapper.isActive
    {
      resetInputState()
    }
    displayedFrame = frame
    tutorial.isHidden = true
    loading.isHidden = true
    loadingIndicator.stopAnimation(nil)
    needsDisplay = true
  }

  func showLoading(deviceName: String) {
    displayedFrame = nil
    tutorial.isHidden = true
    loadingLabel.stringValue = "Connecting to \(deviceName)"
    loading.isHidden = false
    loadingIndicator.startAnimation(nil)
    needsDisplay = true
  }

  func clear() {
    displayedFrame = nil
    tutorial.isHidden = false
    loading.isHidden = true
    loadingIndicator.stopAnimation(nil)
    needsDisplay = true
  }

  private func configureTutorial() {
    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: "iphone.and.arrow.forward",
      accessibilityDescription: "Mirror a phone"
    )
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
    icon.contentTintColor = NSColor(white: 0.72, alpha: 1)
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "Mirror your phone")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.textColor = .white

    let steps = NSTextField(
      wrappingLabelWithString:
        "1. Connect and unlock your phone by USB.\n2. Trust this Mac on iPhone, or allow USB debugging on Android.\n3. Optional: Select a different detected device above."
    )
    steps.font = .systemFont(ofSize: 14)
    steps.textColor = NSColor(white: 0.72, alpha: 1)
    steps.alignment = .left
    steps.maximumNumberOfLines = 0
    steps.preferredMaxLayoutWidth = 380

    tutorial.setViews([icon, title, steps], in: .top)
    tutorial.orientation = .vertical
    tutorial.alignment = .centerX
    tutorial.spacing = 14
    tutorial.setCustomSpacing(22, after: title)
    tutorial.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tutorial)

    NSLayoutConstraint.activate([
      tutorial.centerXAnchor.constraint(equalTo: centerXAnchor),
      tutorial.centerYAnchor.constraint(equalTo: centerYAnchor),
      tutorial.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 36),
      tutorial.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -36),
      icon.widthAnchor.constraint(equalToConstant: 54),
      icon.heightAnchor.constraint(equalToConstant: 54),
      steps.widthAnchor.constraint(equalToConstant: 380),
    ])

    configureLoading()
  }

  private func configureLoading() {
    loadingIndicator.style = .spinning
    loadingIndicator.controlSize = .large
    loadingIndicator.isIndeterminate = true
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

    loadingLabel.font = .systemFont(ofSize: 18, weight: .medium)
    loadingLabel.textColor = NSColor(white: 0.82, alpha: 1)
    loadingLabel.alignment = .center

    loading.setViews([loadingIndicator, loadingLabel], in: .top)
    loading.orientation = .vertical
    loading.alignment = .centerX
    loading.spacing = 18
    loading.translatesAutoresizingMaskIntoConstraints = false
    loading.isHidden = true
    addSubview(loading)

    NSLayoutConstraint.activate([
      loading.centerXAnchor.constraint(equalTo: centerXAnchor),
      loading.centerYAnchor.constraint(equalTo: centerYAnchor),
      loading.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 36),
      loading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -36),
      loadingIndicator.widthAnchor.constraint(equalToConstant: 32),
      loadingIndicator.heightAnchor.constraint(equalToConstant: 32),
    ])
  }
}
