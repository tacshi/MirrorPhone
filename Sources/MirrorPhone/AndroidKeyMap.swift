/// Maps platform-neutral keys and modifiers to Android `KeyEvent` values.
enum AndroidKeyMap {
  // android.view.KeyEvent meta flags (base | left-variant, like scrcpy sends).
  static let metaShift = 0x1 | 0x40
  static let metaAlt = 0x02 | 0x10
  static let metaCtrl = 0x1000 | 0x2000

  static func keycode(for key: DeviceKey) -> Int? {
    switch key {
    case .enter, .keypadEnter: return 66
    case .backspace: return 67
    case .forwardDelete: return 112
    case .tab: return 61
    case .escape: return 111
    case .leftArrow: return 21
    case .rightArrow: return 22
    case .downArrow: return 20
    case .upArrow: return 19
    case .home: return 122
    case .end: return 123
    case .pageUp: return 92
    case .pageDown: return 93
    case .character(let character):
      guard let scalar = character.lowercased().unicodeScalars.first else { return nil }
      switch scalar {
      case "a"..."z": return 29 + Int(scalar.value - UnicodeScalar("a").value)
      case "0"..."9": return 7 + Int(scalar.value - UnicodeScalar("0").value)
      default: return nil
      }
    }
  }

  /// Command maps to Android Control so familiar Mac shortcuts drive Android's
  /// Control shortcuts while the shared event retains the original modifier.
  static func metaState(from modifiers: DeviceInputModifiers) -> Int {
    var meta = 0
    if modifiers.contains(.shift) { meta |= metaShift }
    if modifiers.contains(.option) { meta |= metaAlt }
    if modifiers.contains(.control) || modifiers.contains(.command) { meta |= metaCtrl }
    return meta
  }
}
