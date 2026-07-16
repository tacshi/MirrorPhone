import CoreGraphics
import Testing

@testable import MirrorPhone

@Suite("Coordinate transform (view → device pixels)")
struct DevicePointTests {
  // A portrait device frame drawn to fill the view width, with the window
  // exactly matching the frame aspect ratio (no letterbox).
  private let frame = CGSize(width: 1080, height: 2340)

  @Test("Top-left view corner maps to device origin")
  func topLeftMapsToOrigin() {
    // View is not flipped: top-left of the drawn image is at rect.maxY.
    let bounds = CGRect(x: 0, y: 0, width: 540, height: 1170)
    let rect = MirrorLayout.widthFillingRect(imageSize: frame, in: bounds)
    let device = MirrorLayout.devicePoint(
      viewPoint: CGPoint(x: rect.minX, y: rect.maxY), imageSize: frame, in: bounds
    )
    #expect(device?.x == 0)
    #expect(device?.y == 0)
  }

  @Test("Bottom-right view corner maps near max device pixel")
  func bottomRightMapsToMax() {
    let bounds = CGRect(x: 0, y: 0, width: 540, height: 1170)
    let rect = MirrorLayout.widthFillingRect(imageSize: frame, in: bounds)
    let device = MirrorLayout.devicePoint(
      viewPoint: CGPoint(x: rect.maxX, y: rect.minY), imageSize: frame, in: bounds
    )
    #expect(device?.x == frame.width - 1)
    #expect(device?.y == frame.height - 1)
  }

  @Test("Center maps to device center")
  func centerMapsToCenter() {
    let bounds = CGRect(x: 0, y: 0, width: 540, height: 1170)
    let device = MirrorLayout.devicePoint(
      viewPoint: CGPoint(x: bounds.midX, y: bounds.midY), imageSize: frame, in: bounds
    )
    #expect(abs((device?.x ?? 0) - frame.width / 2) <= 1)
    #expect(abs((device?.y ?? 0) - frame.height / 2) <= 1)
  }

  @Test("Transform is independent of backing scale (fractional window widths)")
  func independentOfBackingScale() {
    // Same relative point at 1x and at a fractional width must map identically
    // in device pixels — the math must not reference backingScaleFactor.
    for width in [540.0, 811.0, 1080.0, 1234.5] {
      let height = width * frame.height / frame.width
      let bounds = CGRect(x: 0, y: 0, width: width, height: height)
      let device = MirrorLayout.devicePoint(
        viewPoint: CGPoint(x: bounds.midX, y: bounds.midY), imageSize: frame, in: bounds
      )
      #expect(abs((device?.x ?? 0) - frame.width / 2) <= 1)
      #expect(abs((device?.y ?? 0) - frame.height / 2) <= 1)
    }
  }

  @Test("Points above/below the drawn rect clamp into the frame")
  func clampsOutsidePoints() {
    // Window taller than the frame's aspect ratio: letterbox top and bottom.
    let bounds = CGRect(x: 0, y: 0, width: 540, height: 2000)
    let rect = MirrorLayout.widthFillingRect(imageSize: frame, in: bounds)
    let aboveTop = MirrorLayout.devicePoint(
      viewPoint: CGPoint(x: bounds.midX, y: rect.maxY + 100), imageSize: frame, in: bounds
    )
    let belowBottom = MirrorLayout.devicePoint(
      viewPoint: CGPoint(x: bounds.midX, y: rect.minY - 100), imageSize: frame, in: bounds
    )
    #expect(aboveTop?.y == 0)
    #expect(belowBottom?.y == frame.height - 1)
  }

  @Test("Zero-size bounds yields nil")
  func zeroBoundsIsNil() {
    #expect(
      MirrorLayout.devicePoint(
        viewPoint: .zero, imageSize: frame, in: .zero
      ) == nil
    )
  }
}

@Suite("Platform-neutral device input")
struct DeviceInputEventTests {
  @Test("Touch locations round-trip through normalized coordinates")
  func normalizedTouchRoundTrip() throws {
    let frame = CGSize(width: 1080, height: 2340)
    let point = CGPoint(x: 721, y: 1804)
    let touch = try #require(
      DeviceTouchEvent(phase: .move, point: point, referenceSize: frame)
    )

    #expect(touch.phase == .move)
    #expect(touch.location.point(in: frame) == point)
  }

  @Test("Normalized touch locations clamp to the reference surface")
  func normalizedTouchClamps() throws {
    let frame = CGSize(width: 100, height: 200)
    let touch = try #require(
      DeviceTouchEvent(
        phase: .down,
        point: CGPoint(x: -20, y: 250),
        referenceSize: frame
      )
    )

    #expect(touch.location == NormalizedPoint(point: CGPoint(x: 0, y: 199), in: frame))
  }

  @Test("Mac special keys map to semantic device keys")
  func macSpecialKeysAreSemantic() {
    #expect(MacInputMap.specialKey(macKeyCode: 36) == .enter)
    #expect(MacInputMap.specialKey(macKeyCode: 51) == .backspace)
    #expect(MacInputMap.specialKey(macKeyCode: 123) == .leftArrow)
    #expect(MacInputMap.shortcutKey(for: "C") == .character("c"))
  }

  @Test("Mac modifiers retain platform-independent meaning")
  func macModifiersStayIndependent() {
    let modifiers = MacInputMap.modifiers(from: [.command, .option])
    #expect(modifiers.contains(.command))
    #expect(modifiers.contains(.option))
    #expect(!modifiers.contains(.control))
  }

  @Test("Android adapts semantic keys to its existing keycodes")
  func androidKeycodesRemainStable() {
    let expected: [(DeviceKey, Int)] = [
      (.enter, 66),
      (.keypadEnter, 66),
      (.backspace, 67),
      (.forwardDelete, 112),
      (.tab, 61),
      (.escape, 111),
      (.leftArrow, 21),
      (.rightArrow, 22),
      (.downArrow, 20),
      (.upArrow, 19),
      (.home, 122),
      (.end, 123),
      (.pageUp, 92),
      (.pageDown, 93),
      (.character("a"), 29),
      (.character("z"), 54),
      (.character("0"), 7),
      (.character("9"), 16),
    ]

    for (key, keycode) in expected {
      #expect(AndroidKeyMap.keycode(for: key) == keycode)
    }
  }

  @Test("Android alone maps Mac Command to Control")
  func androidMapsCommandToControl() {
    let meta = AndroidKeyMap.metaState(from: [.command, .shift, .option])
    #expect(meta & AndroidKeyMap.metaCtrl != 0)
    #expect(meta & AndroidKeyMap.metaShift != 0)
    #expect(meta & AndroidKeyMap.metaAlt != 0)
  }
}

@MainActor
@Suite("Scroll → swipe state machine")
struct ScrollSwipeMapperTests {
  private let frame = CGSize(width: 1000, height: 2000)

  private func makeMapper() -> (ScrollSwipeMapper, () -> [(TouchPhase, CGPoint)]) {
    let mapper = ScrollSwipeMapper()
    var events: [(TouchPhase, CGPoint)] = []
    mapper.emit = { phase, point, _ in events.append((phase, point)) }
    return (mapper, { events })
  }

  @Test("First scroll presses down at the cursor")
  func firstScrollPressesDown() {
    let (mapper, events) = makeMapper()
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 500, y: 400),
      frame: frame, momentumEnded: false
    )
    #expect(events().first?.0 == .down)
    #expect(events().first?.1 == CGPoint(x: 500, y: 400))
  }

  @Test("Scrolls accumulate into moves from the anchor")
  func accumulatesMoves() {
    let (mapper, events) = makeMapper()
    // First event: down at cursor, then the delta is applied as the first move.
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 500, y: 400),
      frame: frame, momentumEnded: false
    )
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: 20), cursor: CGPoint(x: 500, y: 400),
      frame: frame, momentumEnded: false
    )
    let moves = events().filter { $0.0 == .move }
    #expect(moves.count == 2)
    #expect(moves[0].1 == CGPoint(x: 500, y: 410))
    #expect(moves[1].1 == CGPoint(x: 500, y: 430))
  }

  @Test("Finger leaving the frame lifts and re-presses at the anchor")
  func liftsAndRePressesAtEdge() {
    let (mapper, events) = makeMapper()
    let anchor = CGPoint(x: 500, y: 100)
    // First event with no delta: down, then a move that stays at the anchor.
    mapper.handleScroll(delta: .zero, cursor: anchor, frame: frame, momentumEnded: false)
    // A huge upward delta would leave the top of the frame.
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: -5000), cursor: anchor, frame: frame, momentumEnded: false
    )
    let phases = events().map(\.0)
    #expect(phases == [.down, .move, .up, .down])
    // Re-press returns to the original anchor.
    #expect(events().last?.1 == anchor)
  }

  @Test("Momentum end lifts the finger")
  func momentumEndLifts() {
    let (mapper, events) = makeMapper()
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 500, y: 400),
      frame: frame, momentumEnded: false
    )
    mapper.handleScroll(
      delta: .zero, cursor: CGPoint(x: 500, y: 400), frame: frame, momentumEnded: true
    )
    #expect(events().last?.0 == .up)
    #expect(mapper.isActive == false)
  }

  @Test("Cancel emits a cancel and clears state")
  func cancelClearsState() {
    let (mapper, events) = makeMapper()
    mapper.handleScroll(
      delta: CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 500, y: 400),
      frame: frame, momentumEnded: false
    )
    mapper.cancel()
    #expect(events().last?.0 == .cancel)
    #expect(mapper.isActive == false)
  }
}
