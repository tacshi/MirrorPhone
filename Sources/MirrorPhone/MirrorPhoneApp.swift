import AppKit

@main
@MainActor
struct MirrorPhoneApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
  }
}
