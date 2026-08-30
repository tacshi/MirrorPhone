import Foundation
@preconcurrency import AVFoundation
import AppKit
import Testing

@testable import MirrorPhone

@Suite("Adaptive mirror quality")
struct MirrorQualityTests {
  private let overloaded = MirrorPerformanceWindow(
    sourceFrames: 60,
    replacedDisplayFrames: 15,
    decodeOccupancy: 0.40,
    renderOccupancy: 0.50
  )
  private let healthy = MirrorPerformanceWindow(
    sourceFrames: 60,
    replacedDisplayFrames: 1,
    decodeOccupancy: 0.30,
    renderOccupancy: 0.40
  )

  @Test("Auto starts Balanced and downshifts after three overloaded windows")
  func automaticDownshift() {
    var policy = MirrorAdaptiveQualityPolicy()

    #expect(policy.mode == .automatic)
    #expect(policy.effectiveLevel == .balanced)
    #expect(policy.observe(overloaded, now: 0) == nil)
    #expect(policy.observe(overloaded, now: 1) == nil)
    #expect(policy.observe(overloaded, now: 2) == .performance)
    #expect(policy.effectiveLevel == .performance)
  }

  @Test("Auto restores one level after a long healthy period")
  func automaticUpshift() {
    var policy = MirrorAdaptiveQualityPolicy()

    for second in 0..<19 {
      #expect(policy.observe(healthy, now: Double(second)) == nil)
    }
    #expect(policy.observe(healthy, now: 19) == .quality)
    #expect(policy.effectiveLevel == .quality)
  }

  @Test("Cooldown prevents immediate oscillation")
  func cooldown() {
    var policy = MirrorAdaptiveQualityPolicy()
    _ = policy.observe(overloaded, now: 0)
    _ = policy.observe(overloaded, now: 1)
    #expect(policy.observe(overloaded, now: 2) == .performance)

    for second in 3...16 {
      #expect(policy.observe(healthy, now: Double(second)) == nil)
    }
    for second in 17..<36 {
      #expect(policy.observe(healthy, now: Double(second)) == nil)
    }
    #expect(policy.observe(healthy, now: 36) == .balanced)
  }

  @Test("Neutral and undersized windows reset consecutive observations")
  func invalidWindowsResetPressure() {
    var policy = MirrorAdaptiveQualityPolicy()
    let neutral = MirrorPerformanceWindow(
      sourceFrames: 60,
      replacedDisplayFrames: 5,
      decodeOccupancy: 0.70,
      renderOccupancy: 0.70
    )
    let undersized = MirrorPerformanceWindow(
      sourceFrames: 9,
      replacedDisplayFrames: 9,
      decodeOccupancy: 1,
      renderOccupancy: 1
    )

    _ = policy.observe(overloaded, now: 0)
    _ = policy.observe(overloaded, now: 1)
    #expect(policy.observe(neutral, now: 2) == nil)
    #expect(policy.observe(overloaded, now: 3) == nil)
    #expect(policy.observe(overloaded, now: 4) == nil)
    #expect(policy.observe(undersized, now: 5) == nil)
    #expect(policy.observe(overloaded, now: 6) == nil)
    #expect(policy.observe(overloaded, now: 7) == nil)
    #expect(policy.observe(overloaded, now: 8) == .performance)
  }

  @Test("Fixed profiles ignore performance observations")
  func fixedModeDoesNotAdapt() {
    var policy = MirrorAdaptiveQualityPolicy(mode: .quality)

    for second in 0..<10 {
      #expect(policy.observe(overloaded, now: Double(second)) == nil)
    }
    #expect(policy.effectiveLevel == .quality)
    #expect(policy.setMode(.automatic) == .balanced)
  }

  @Test("Unsupported levels fall downward and fixed requests recover when support returns")
  func supportedLevelFallback() {
    var policy = MirrorAdaptiveQualityPolicy(
      mode: .quality,
      supportedLevels: [.balanced, .performance]
    )

    #expect(policy.effectiveLevel == .balanced)
    #expect(policy.setSupportedLevels([.performance]) == .performance)
    #expect(policy.setSupportedLevels(Set(MirrorQualityLevel.allCases)) == .quality)
  }

  @Test("Android profiles preserve aspect ratio, even dimensions, and fixed bitrates")
  func androidProfileMapping() {
    let portrait = AndroidDisplaySize(width: 1179, height: 2556)
    let quality = AndroidScreenrecordConfiguration.make(level: .quality, nativeSize: portrait)
    let balanced = AndroidScreenrecordConfiguration.make(level: .balanced, nativeSize: portrait)
    let performance = AndroidScreenrecordConfiguration.make(
      level: .performance,
      nativeSize: portrait
    )

    #expect(quality.size == nil)
    #expect(quality.bitrate == 12_000_000)
    #expect(balanced.size == AndroidDisplaySize(width: 884, height: 1920))
    #expect(balanced.bitrate == 8_000_000)
    #expect(performance.size == AndroidDisplaySize(width: 590, height: 1280))
    #expect(performance.bitrate == 4_000_000)
    #expect(
      performance.screenrecordArguments == [
        "exec-out", "screenrecord", "--output-format=h264", "--bit-rate", "4000000",
        "--size", "590x1280", "-",
      ]
    )

    let alreadySmall = AndroidDisplaySize(width: 720, height: 1280)
    #expect(
      alreadySmall.fitted(maxShortEdge: 1080, maxLongEdge: 1920) == alreadySmall
    )
  }

  @Test("AVFoundation preset resolution prefers the requested semantic level")
  func avCapturePresetResolution() {
    let supported: Set<AVCaptureSession.Preset> = [.high, .medium, .hd1920x1080, .low]

    #expect(
      AVCaptureQualityPresetResolver.resolve(.balanced, supportedPresets: supported)
        == AVCaptureQualityPresetChoice(level: .balanced, preset: .hd1920x1080)
    )
    #expect(
      AVCaptureQualityPresetResolver.resolve(.performance, supportedPresets: [.high])
        == AVCaptureQualityPresetChoice(level: .quality, preset: .high)
    )
    #expect(
      AVCaptureQualityPresetResolver.supportedLevels(in: supported)
        == Set(MirrorQualityLevel.allCases)
    )
  }
}

@Suite("Mirror quality preferences")
@MainActor
struct MirrorQualityPreferenceTests {
  @Test("Defaults to Auto and persists the selected mode")
  func persistence() throws {
    let suiteName = "MirrorPhoneTests.Quality.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = UserDefaultsMirrorQualityPreferences(defaults: defaults)

    #expect(preferences.defaultMode == .automatic)
    preferences.defaultMode = .performance
    #expect(preferences.defaultMode == .performance)
  }

  @Test("Windows keep independent modes while new windows copy the saved default")
  func perWindowDefaults() {
    let preferences = InMemoryMirrorQualityPreferences(defaultMode: .automatic)
    let first = MirrorWindowController(
      sourceFactory: DefaultMirrorSourceFactory(),
      qualityPreferences: preferences
    )

    #expect(first.selectedQualityMode == .automatic)
    first.selectPerformanceQuality(nil)
    #expect(first.selectedQualityMode == .performance)
    #expect(preferences.defaultMode == .performance)

    let second = MirrorWindowController(
      sourceFactory: DefaultMirrorSourceFactory(),
      qualityPreferences: preferences
    )
    #expect(second.selectedQualityMode == .performance)

    first.selectBalancedQuality(nil)
    #expect(first.selectedQualityMode == .balanced)
    #expect(second.selectedQualityMode == .performance)

    let performanceItem = NSMenuItem(
      title: "Performance",
      action: #selector(MirrorWindowController.selectPerformanceQuality(_:)),
      keyEquivalent: ""
    )
    #expect(second.validateMenuItem(performanceItem))
    #expect(performanceItem.state == .on)
  }

  @Test("Changing quality preserves a source's recording tap")
  func recordingTapIdentity() {
    let source = AndroidADBMirrorSource(serial: "test", deviceName: "Test Android")
    let recordingTap = source.recordingTap

    source.setQualityMode(.quality)
    source.setQualityMode(.performance)

    #expect(source.recordingTap === recordingTap)
  }
}

@MainActor
private final class InMemoryMirrorQualityPreferences: MirrorQualityPreferenceStoring {
  var defaultMode: MirrorQualityMode

  init(defaultMode: MirrorQualityMode) {
    self.defaultMode = defaultMode
  }
}
