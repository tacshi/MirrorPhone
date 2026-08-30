import AppKit

/// Translates AppKit keyboard events into platform-neutral input semantics.
enum MacInputMap {
  private static let specialKeys: [UInt16: DeviceKey] = [
    36: .enter,
    76: .keypadEnter,
    51: .backspace,
    117: .forwardDelete,
    48: .tab,
    53: .escape,
    123: .leftArrow,
    124: .rightArrow,
    125: .downArrow,
    126: .upArrow,
    115: .home,
    119: .end,
    116: .pageUp,
    121: .pageDown,
  ]

  static func specialKey(macKeyCode: UInt16) -> DeviceKey? {
    specialKeys[macKeyCode]
  }

  /// A semantic letter or digit key for shortcuts such as Command-C.
  static func shortcutKey(for character: Character) -> DeviceKey? {
    guard let scalar = character.lowercased().unicodeScalars.first else { return nil }
    switch scalar {
    case "a"..."z", "0"..."9": return .character(Character(String(scalar)))
    default: return nil
    }
  }

  /// Command-C/X/V belong to MirrorPhone's Edit menu. If a clipboard bridge is
  /// unavailable and AppKit lets the disabled key equivalent reach the mirror
  /// view, keep it from silently becoming an Android Control shortcut.
  static func isClipboardCommandShortcut(
    character: Character?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    guard modifierFlags.contains(.command), let character else { return false }
    switch character.lowercased() {
    case "c", "x", "v": return true
    default: return false
    }
  }

  static func modifiers(from flags: NSEvent.ModifierFlags) -> DeviceInputModifiers {
    var modifiers: DeviceInputModifiers = []
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.command) { modifiers.insert(.command) }
    return modifiers
  }

  /// Printable output uses the active Mac keyboard layout and input method.
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
