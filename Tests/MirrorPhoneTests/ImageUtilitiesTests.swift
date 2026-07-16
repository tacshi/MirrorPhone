import AppKit
import Testing

@testable import MirrorPhone

@Suite("Image rotation")
struct ImageUtilitiesTests {
  @Test("Quarter turns produce the expected dimensions")
  func rotatesDimensions() throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: 2,
        height: 3,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let image = try #require(context.makeImage())

    let right = ImageUtilities.rotated(image, quarterTurns: 1)
    let upsideDown = ImageUtilities.rotated(image, quarterTurns: 2)
    let left = ImageUtilities.rotated(image, quarterTurns: -1)

    #expect(right.width == 3 && right.height == 2)
    #expect(upsideDown.width == 2 && upsideDown.height == 3)
    #expect(left.width == 3 && left.height == 2)
  }
}

@Suite("Mirror layout")
struct MirrorLayoutTests {
  @Test("Phone frames fill the viewer from edge to edge")
  func fillsViewerWidth() {
    let viewer = CGRect(x: 0, y: 0, width: 904, height: 1_670)
    let rect = MirrorLayout.widthFillingRect(
      imageSize: CGSize(width: 1_179, height: 2_556),
      in: viewer
    )

    #expect(abs(rect.minX - viewer.minX) < 0.001)
    #expect(abs(rect.maxX - viewer.maxX) < 0.001)
    #expect(rect.height >= viewer.height)
  }

  @Test("Disconnect restores a portrait window without moving its top center")
  func restoresPortraitWindow() {
    let current = CGRect(x: 100, y: 100, width: 1_800, height: 900)
    let visible = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
    let restored = MirrorLayout.restoredWindowFrame(
      currentFrame: current,
      portraitSize: CGSize(width: 560, height: 860),
      visibleFrame: visible
    )

    #expect(restored.size == CGSize(width: 560, height: 860))
    #expect(restored.midX == current.midX)
    #expect(restored.maxY == current.maxY)
  }

  @Test("Rotation keeps the complete window inside the visible screen")
  func constrainsRotatedWindow() {
    let visible = CGRect(x: 0, y: 50, width: 1_600, height: 900)
    let constrained = MirrorLayout.constrainedWindowFrame(
      CGRect(x: -120, y: -80, width: 1_800, height: 1_100),
      visibleFrame: visible
    )

    #expect(constrained == visible)
  }

  @Test("Portrait and landscape viewer sizes are remembered independently")
  func remembersOrientationSizes() {
    var memory = MirrorWindowSizeMemory()
    let landscape = CGSize(width: 1_400, height: 650)
    let portrait = CGSize(width: 440, height: 950)

    memory.remember(viewerSize: landscape, aspectRatio: 2.15)
    memory.remember(viewerSize: portrait, aspectRatio: 0.46)

    #expect(memory.size(for: 1.8) == landscape)
    #expect(memory.size(for: 0.5) == portrait)
  }
}

@Suite("Mirror window chrome")
@MainActor
struct MirrorWindowChromeTests {
  @Test("Revealing the titlebar keeps the mirror fixed and grows the window above it")
  func titlebarSitsAboveMirrorWithoutMovingIt() throws {
    let controller = MirrorWindowController()
    let window = try #require(controller.window)
    let contentView = try #require(window.contentView)
    let mirrorView = try #require(contentView.subviews.compactMap { $0 as? MirrorView }.first)

    // Content spans the whole frame; the titlebar lives in space added above.
    #expect(window.styleMask.contains(.fullSizeContentView))
    // Park the window with headroom above so the reveal is not clamped by the
    // screen edge, keeping the geometry assertions deterministic.
    window.setFrame(NSRect(x: 200, y: 120, width: 560, height: 720), display: false)
    contentView.layoutSubtreeIfNeeded()

    // Hidden: the mirror fills the window edge-to-edge.
    #expect(!controller.areTitlebarControlsVisible)
    #expect(mirrorView.frame == contentView.bounds)
    let baseMirrorSize = mirrorView.bounds.size
    let baseWindowHeight = window.frame.height
    let baseMirrorFrame = window.convertToScreen(mirrorView.convert(mirrorView.bounds, to: nil))

    // Shown: the mirror does not move, and the window is taller by the titlebar.
    controller.setTitlebarVisible(true)
    contentView.layoutSubtreeIfNeeded()
    #expect(controller.areTitlebarControlsVisible)
    #expect(mirrorView.bounds.size == baseMirrorSize)
    #expect(mirrorView.frame.minY == 0)  // still pinned to the window bottom
    #expect(window.frame.height > baseWindowHeight)
    #expect(
      window.convertToScreen(mirrorView.convert(mirrorView.bounds, to: nil)) == baseMirrorFrame
    )

    // Hidden again: the window collapses back and the mirror is unchanged.
    controller.setTitlebarVisible(false)
    contentView.layoutSubtreeIfNeeded()
    #expect(!controller.areTitlebarControlsVisible)
    #expect(mirrorView.frame == contentView.bounds)
    #expect(window.frame.height == baseWindowHeight)
    #expect(
      window.convertToScreen(mirrorView.convert(mirrorView.bounds, to: nil)) == baseMirrorFrame
    )
  }

  @Test("Pointer near the top reveals the titlebar; moving onto the content hides it")
  func pointerRevealTogglesTitlebar() throws {
    let controller = MirrorWindowController()
    let window = try #require(controller.window)
    let contentView = try #require(window.contentView)
    let mirrorView = try #require(contentView.subviews.compactMap { $0 as? MirrorView }.first)
    contentView.layoutSubtreeIfNeeded()

    controller.setTitlebarVisible(false)
    #expect(!controller.areTitlebarControlsVisible)

    let nearTop = CGPoint(x: mirrorView.bounds.midX, y: mirrorView.bounds.maxY - 2)
    controller.handlePointerMoved(to: nearTop)
    #expect(controller.areTitlebarControlsVisible)

    // Idle movement that stays near the top keeps it revealed.
    controller.handlePointerMoved(to: nearTop)
    #expect(controller.areTitlebarControlsVisible)

    // Moving well down onto the content hides it again.
    controller.handlePointerMoved(
      to: CGPoint(x: mirrorView.bounds.midX, y: mirrorView.bounds.maxY - 200)
    )
    #expect(!controller.areTitlebarControlsVisible)

    // And it reveals once more when the pointer returns to the top edge.
    controller.handlePointerMoved(to: nearTop)
    #expect(controller.areTitlebarControlsVisible)
  }
}
