import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MirrorWindowController?

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMainMenu()

    let controller = MirrorWindowController()
    windowController = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    registerCameraPermission()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func registerCameraPermission() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
    Task {
      _ = await AVCaptureDevice.requestAccess(for: .video)
    }
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About MirrorPhone",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit MirrorPhone",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      withTitle: "Actual Size", action: #selector(MirrorWindowController.actualSize(_:)),
      keyEquivalent: "0")
    viewMenuItem.submenu = viewMenu

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(
      withTitle: "Capture Image", action: #selector(MirrorWindowController.captureImage(_:)),
      keyEquivalent: "s")
    fileMenuItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
  }
}
