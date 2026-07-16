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
  private let tutorial = NSStackView()
  private let loading = NSStackView()
  private let loadingIndicator = NSProgressIndicator()
  private let loadingLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureTutorial()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureTutorial()
  }

  override var isOpaque: Bool { true }

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
