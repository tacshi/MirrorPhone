import Foundation

enum MirrorQualityMode: String, CaseIterable, Equatable, Sendable {
  case automatic
  case quality
  case balanced
  case performance

  var title: String {
    switch self {
    case .automatic: "Auto"
    case .quality: "Quality"
    case .balanced: "Balanced"
    case .performance: "Performance"
    }
  }

  var fixedLevel: MirrorQualityLevel? {
    switch self {
    case .automatic: nil
    case .quality: .quality
    case .balanced: .balanced
    case .performance: .performance
    }
  }
}

enum MirrorQualityLevel: Int, CaseIterable, Comparable, Equatable, Hashable, Sendable {
  case performance
  case balanced
  case quality

  static func < (lhs: MirrorQualityLevel, rhs: MirrorQualityLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var title: String {
    switch self {
    case .quality: "Quality"
    case .balanced: "Balanced"
    case .performance: "Performance"
    }
  }
}

struct MirrorQualityState: Equatable, Sendable {
  let mode: MirrorQualityMode
  let effectiveLevel: MirrorQualityLevel?
  let isAdjusting: Bool
  let limitation: String?
}

struct MirrorPerformanceWindow: Equatable, Sendable {
  let sourceFrames: Int
  let replacedDisplayFrames: Int
  let decodeOccupancy: Double
  let renderOccupancy: Double

  var isValid: Bool { sourceFrames >= 10 }

  var replacementRatio: Double {
    guard sourceFrames > 0 else { return 0 }
    return Double(replacedDisplayFrames) / Double(sourceFrames)
  }

  var isOverloaded: Bool {
    replacementRatio >= 0.20 || decodeOccupancy >= 0.85 || renderOccupancy >= 0.85
  }

  var isHealthy: Bool {
    replacementRatio <= 0.02 && decodeOccupancy <= 0.60 && renderOccupancy <= 0.60
  }
}

struct MirrorAdaptiveQualityPolicy: Equatable, Sendable {
  static let cooldown: TimeInterval = 15
  static let overloadedWindowCount = 3
  static let healthyWindowCount = 20

  private(set) var mode: MirrorQualityMode
  private(set) var effectiveLevel: MirrorQualityLevel
  private(set) var supportedLevels: Set<MirrorQualityLevel>
  private var consecutiveOverloadedWindows = 0
  private var consecutiveHealthyWindows = 0
  private var lastAdaptiveTransitionTime: TimeInterval?

  init(
    mode: MirrorQualityMode = .automatic,
    supportedLevels: Set<MirrorQualityLevel> = Set(MirrorQualityLevel.allCases)
  ) {
    let supported = supportedLevels.isEmpty ? Set(MirrorQualityLevel.allCases) : supportedLevels
    self.mode = mode
    self.supportedLevels = supported
    effectiveLevel = Self.resolve(mode.fixedLevel ?? .balanced, within: supported)
  }

  @discardableResult
  mutating func setMode(_ mode: MirrorQualityMode) -> MirrorQualityLevel? {
    let previous = effectiveLevel
    self.mode = mode
    effectiveLevel = Self.resolve(mode.fixedLevel ?? .balanced, within: supportedLevels)
    resetObservations()
    // Returning to Auto starts at Balanced and can react immediately rather
    // than inheriting a cooldown from a prior automatic decision.
    lastAdaptiveTransitionTime = nil
    return previous == effectiveLevel ? nil : effectiveLevel
  }

  @discardableResult
  mutating func setSupportedLevels(
    _ levels: Set<MirrorQualityLevel>
  ) -> MirrorQualityLevel? {
    guard !levels.isEmpty else { return nil }
    let previous = effectiveLevel
    supportedLevels = levels
    effectiveLevel = Self.resolve(mode.fixedLevel ?? effectiveLevel, within: levels)
    resetObservations()
    return previous == effectiveLevel ? nil : effectiveLevel
  }

  @discardableResult
  mutating func observe(
    _ window: MirrorPerformanceWindow,
    now: TimeInterval
  ) -> MirrorQualityLevel? {
    guard mode == .automatic, window.isValid else {
      resetObservations()
      return nil
    }
    if let lastAdaptiveTransitionTime,
      now - lastAdaptiveTransitionTime < Self.cooldown
    {
      resetObservations()
      return nil
    }

    if window.isOverloaded {
      consecutiveOverloadedWindows += 1
      consecutiveHealthyWindows = 0
    } else if window.isHealthy {
      consecutiveHealthyWindows += 1
      consecutiveOverloadedWindows = 0
    } else {
      resetObservations()
      return nil
    }

    if consecutiveOverloadedWindows >= Self.overloadedWindowCount,
      let lower = nextLowerLevel()
    {
      effectiveLevel = lower
      lastAdaptiveTransitionTime = now
      resetObservations()
      return lower
    }
    if consecutiveHealthyWindows >= Self.healthyWindowCount,
      let higher = nextHigherLevel()
    {
      effectiveLevel = higher
      lastAdaptiveTransitionTime = now
      resetObservations()
      return higher
    }
    return nil
  }

  private mutating func resetObservations() {
    consecutiveOverloadedWindows = 0
    consecutiveHealthyWindows = 0
  }

  private func nextLowerLevel() -> MirrorQualityLevel? {
    supportedLevels.filter { $0 < effectiveLevel }.max()
  }

  private func nextHigherLevel() -> MirrorQualityLevel? {
    supportedLevels.filter { $0 > effectiveLevel }.min()
  }

  private static func resolve(
    _ requested: MirrorQualityLevel,
    within supported: Set<MirrorQualityLevel>
  ) -> MirrorQualityLevel {
    if supported.contains(requested) { return requested }
    if let lower = supported.filter({ $0 < requested }).max() { return lower }
    return supported.filter { $0 > requested }.min() ?? requested
  }
}

@MainActor
final class MirrorQualityController {
  private var policy: MirrorAdaptiveQualityPolicy
  private(set) var state: MirrorQualityState
  var onStateChanged: ((MirrorQualityState) -> Void)?

  init(
    mode: MirrorQualityMode = .automatic,
    supportedLevels: Set<MirrorQualityLevel> = Set(MirrorQualityLevel.allCases),
    limitation: String? = nil
  ) {
    policy = MirrorAdaptiveQualityPolicy(mode: mode, supportedLevels: supportedLevels)
    state = MirrorQualityState(
      mode: mode,
      effectiveLevel: policy.effectiveLevel,
      isAdjusting: false,
      limitation: limitation
    )
  }

  @discardableResult
  func setMode(_ mode: MirrorQualityMode) -> MirrorQualityLevel? {
    let changedLevel = policy.setMode(mode)
    publish(isAdjusting: changedLevel != nil, limitation: state.limitation)
    return changedLevel
  }

  @discardableResult
  func setSupportedLevels(
    _ levels: Set<MirrorQualityLevel>,
    limitation: String?
  ) -> MirrorQualityLevel? {
    let changedLevel = policy.setSupportedLevels(levels)
    publish(isAdjusting: changedLevel != nil, limitation: limitation)
    return changedLevel
  }

  @discardableResult
  func observe(
    _ window: MirrorPerformanceWindow,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> MirrorQualityLevel? {
    guard let level = policy.observe(window, now: now) else { return nil }
    publish(isAdjusting: true, limitation: state.limitation)
    return level
  }

  func markApplied(limitation: String? = nil) {
    publish(isAdjusting: false, limitation: limitation ?? state.limitation)
  }

  func markAdjustmentFailed(_ reason: String) {
    publish(isAdjusting: false, limitation: reason)
  }

  private func publish(isAdjusting: Bool, limitation: String?) {
    state = MirrorQualityState(
      mode: policy.mode,
      effectiveLevel: policy.effectiveLevel,
      isAdjusting: isAdjusting,
      limitation: limitation
    )
    onStateChanged?(state)
  }
}

final class MirrorFramePressureMeter: @unchecked Sendable {
  typealias WindowHandler = @Sendable (MirrorPerformanceWindow) -> Void

  private let lock = NSLock()
  private let onWindow: WindowHandler
  private var windowStart = ProcessInfo.processInfo.systemUptime
  private var sourceFrames = 0
  private var replacedDisplayFrames = 0
  private var decodeTime: TimeInterval = 0
  private var renderTime: TimeInterval = 0

  init(onWindow: @escaping WindowHandler) {
    self.onWindow = onWindow
  }

  func recordSourceFrame() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let completed = rollWindowIfNeeded(now: now)
    sourceFrames += 1
    lock.unlock()
    if let completed { onWindow(completed) }
  }

  func recordDisplayReplacement() {
    lock.lock()
    replacedDisplayFrames += 1
    lock.unlock()
  }

  func recordDecode(duration: TimeInterval) {
    lock.lock()
    decodeTime += max(0, duration)
    lock.unlock()
  }

  func recordRender(duration: TimeInterval) {
    lock.lock()
    renderTime += max(0, duration)
    lock.unlock()
  }

  func reset() {
    lock.lock()
    windowStart = ProcessInfo.processInfo.systemUptime
    sourceFrames = 0
    replacedDisplayFrames = 0
    decodeTime = 0
    renderTime = 0
    lock.unlock()
  }

  private func rollWindowIfNeeded(now: TimeInterval) -> MirrorPerformanceWindow? {
    let elapsed = now - windowStart
    guard elapsed >= 1 else { return nil }
    let completed = MirrorPerformanceWindow(
      sourceFrames: sourceFrames,
      replacedDisplayFrames: replacedDisplayFrames,
      decodeOccupancy: min(1, decodeTime / elapsed),
      renderOccupancy: min(1, renderTime / elapsed)
    )
    windowStart = now
    sourceFrames = 0
    replacedDisplayFrames = 0
    decodeTime = 0
    renderTime = 0
    return completed
  }
}

@MainActor
protocol MirrorQualityPreferenceStoring: AnyObject {
  var defaultMode: MirrorQualityMode { get set }
}

@MainActor
final class UserDefaultsMirrorQualityPreferences: MirrorQualityPreferenceStoring {
  static let shared = UserDefaultsMirrorQualityPreferences()

  private static let key = "mirrorQualityMode"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var defaultMode: MirrorQualityMode {
    get {
      guard let value = defaults.string(forKey: Self.key),
        let mode = MirrorQualityMode(rawValue: value)
      else { return .automatic }
      return mode
    }
    set {
      defaults.set(newValue.rawValue, forKey: Self.key)
    }
  }
}
