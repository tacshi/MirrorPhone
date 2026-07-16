import ImageIO
import Testing

@testable import MirrorPhone

@Suite("ReplayKit orientation")
struct ReplayKitOrientationTests {
  @Test("Converts ReplayKit device rotations to Core Image display transforms")
  func displayTransforms() {
    #expect(ReplayKitOrientation.displayOrientation(rawValue: 1) == .up)
    #expect(ReplayKitOrientation.displayOrientation(rawValue: 3) == .down)
    #expect(ReplayKitOrientation.displayOrientation(rawValue: 6) == .left)
    #expect(ReplayKitOrientation.displayOrientation(rawValue: 8) == .right)
    #expect(ReplayKitOrientation.displayOrientation(rawValue: 0) == nil)
  }
}
