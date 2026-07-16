import AppKit

/// Maps macOS keyboard events to Android `KeyEvent` keycodes and meta flags.
enum AndroidKeyMap {
  // android.view.KeyEvent meta flags (base | left-variant, like scrcpy sends).
  static let metaShift = 0x1 | 0x40
  static let metaAlt = 0x02 | 0x10
  static let metaCtrl = 0x1000 | 0x2000

  /// Non-printing keys by macOS virtual keycode → Android keycode.
  private static let specialKeys: [UInt16: Int] = [
    36: 66,  // return        → ENTER
    76: 66,  // keypad enter  → ENTER
    51: 67,  // delete        → DEL (backspace)
    117: 112,  // forward delete → FORWARD_DEL
    48: 61,  // tab           → TAB
    53: 111,  // escape        → ESCAPE (acts as back in most apps)
    123: 21,  // left          → DPAD_LEFT
    124: 22,  // right         → DPAD_RIGHT
    125: 20,  // down          → DPAD_DOWN
    126: 19,  // up            → DPAD_UP
    115: 122,  // home          → MOVE_HOME
    119: 123,  // end           → MOVE_END
    116: 92,  // page up       → PAGE_UP
    121: 93,  // page down     → PAGE_DOWN
  ]

  static func specialKeycode(macKeyCode: UInt16) -> Int? {
    specialKeys[macKeyCode]
  }

  /// Keycode for a letter/digit, used for shortcuts like ⌘C → Ctrl+C.
  static func shortcutKeycode(for character: Character) -> Int? {
    guard let scalar = character.lowercased().unicodeScalars.first else { return nil }
    switch scalar {
    case "a"..."z": return 29 + Int(scalar.value - UnicodeScalar("a").value)
    case "0"..."9": return 7 + Int(scalar.value - UnicodeScalar("0").value)
    default: return nil
    }
  }

  /// Android meta state for the held modifiers. ⌘ maps to Android Ctrl so
  /// familiar Mac shortcuts (⌘C/⌘V/⌘A…) drive Android's Ctrl shortcuts.
  static func metaState(from flags: NSEvent.ModifierFlags) -> Int {
    var meta = 0
    if flags.contains(.shift) { meta |= metaShift }
    if flags.contains(.option) { meta |= metaAlt }
    if flags.contains(.control) || flags.contains(.command) { meta |= metaCtrl }
    return meta
  }

  /// True when the event should be forwarded as typed text rather than a
  /// keycode: it produced printable characters and no shortcut modifier is held.
  static func textToType(from event: NSEvent) -> String? {
    guard !event.modifierFlags.contains(.command),
      !event.modifierFlags.contains(.control),
      let characters = event.characters,
      !characters.isEmpty,
      characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
    else { return nil }
    return characters
  }
}
