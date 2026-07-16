import CoreGraphics
import Foundation

/// Turns a stream of scroll-wheel / trackpad events into a synthetic touch
/// swipe: a finger goes down at the cursor on the first scroll, follows the
/// accumulated scroll delta, and lifts after a short pause (or when momentum
/// ends). All positions are in device-frame pixels; the owning view converts
/// view points and picks a sensitivity per input class.
@MainActor
final class ScrollSwipeMapper {
  /// Emits a touch event: phase, device-pixel position, and the frame size the
  /// position is relative to.
  var emit: ((TouchPhase, CGPoint, CGSize) -> Void)?

  private struct Active {
    var anchor: CGPoint
    var finger: CGPoint
    var frame: CGSize
  }

  private var active: Active?
  private var endWorkItem: DispatchWorkItem?

  /// How long without a scroll event before the finger lifts.
  private static let endDelay: TimeInterval = 0.15

  var isActive: Bool { active != nil }

  /// Feed one scroll event. `delta` is the finger displacement in device pixels
  /// (already scaled and signed by the caller). `cursor` seeds the finger on the
  /// first event of a gesture. `momentumEnded` lifts immediately.
  func handleScroll(delta: CGVector, cursor: CGPoint, frame: CGSize, momentumEnded: Bool) {
    if momentumEnded {
      finishImmediately()
      return
    }

    if active == nil {
      let start = clamp(cursor, in: frame)
      active = Active(anchor: start, finger: start, frame: frame)
      emit?(.down, start, frame)
    } else if active!.frame != frame {
      // Rotation/resize changed the frame mid-scroll; end cleanly and restart.
      finishImmediately()
      let start = clamp(cursor, in: frame)
      active = Active(anchor: start, finger: start, frame: frame)
      emit?(.down, start, frame)
    }

    guard var state = active else { return }
    let target = CGPoint(x: state.finger.x + delta.dx, y: state.finger.y + delta.dy)

    if isInside(target, in: state.frame) {
      state.finger = target
      active = state
      emit?(.move, target, state.frame)
    } else {
      // The finger would leave the screen. Lift at the edge and re-press at the
      // anchor so a long scroll keeps flowing (scrcpy-style).
      let edge = clamp(target, in: state.frame)
      emit?(.up, edge, state.frame)
      emit?(.down, state.anchor, state.frame)
      state.finger = state.anchor
      active = state
    }

    scheduleEnd()
  }

  /// Lift the finger now if a scroll gesture is in progress.
  func finishImmediately() {
    endWorkItem?.cancel()
    endWorkItem = nil
    guard let state = active else { return }
    active = nil
    emit?(.up, state.finger, state.frame)
  }

  /// Abandon an in-progress scroll gesture (e.g. rotation, disconnect).
  func cancel() {
    endWorkItem?.cancel()
    endWorkItem = nil
    guard let state = active else { return }
    active = nil
    emit?(.cancel, state.finger, state.frame)
  }

  private func scheduleEnd() {
    endWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.finishImmediately()
    }
    endWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDelay, execute: work)
  }

  private func isInside(_ point: CGPoint, in frame: CGSize) -> Bool {
    point.x >= 0 && point.y >= 0 && point.x <= frame.width - 1 && point.y <= frame.height - 1
  }

  private func clamp(_ point: CGPoint, in frame: CGSize) -> CGPoint {
    CGPoint(
      x: min(max(point.x, 0), frame.width - 1),
      y: min(max(point.y, 0), frame.height - 1)
    )
  }
}
