import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MirrorWindowController?
  private var terminationTask: Task<Void, Never>?

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = MirrorWindowController()
    windowController = controller
    configureMainMenu()
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    registerCameraPermission()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let windowController, windowController.hasRecordingToFinalize else {
      return .terminateNow
    }
    guard terminationTask == nil else { return .terminateLater }
    terminationTask = Task { @MainActor [weak self, weak sender] in
      let succeeded = await windowController.finalizeRecordingForTermination()
      self?.terminationTask = nil
      sender?.reply(toApplicationShouldTerminate: succeeded)
    }
    return .terminateLater
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
    let actualSizeItem = viewMenu.addItem(
      withTitle: "Actual Size", action: #selector(MirrorWindowController.actualSize(_:)),
      keyEquivalent: "0")
    actualSizeItem.target = windowController
    viewMenuItem.submenu = viewMenu

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let recordingItem = fileMenu.addItem(
      withTitle: "Start Recording…",
      action: #selector(MirrorWindowController.toggleRecording(_:)),
      keyEquivalent: "r"
    )
    recordingItem.target = windowController
    let captureItem = fileMenu.addItem(
      withTitle: "Capture Image", action: #selector(MirrorWindowController.captureImage(_:)),
      keyEquivalent: "s")
    captureItem.target = windowController
    fileMenuItem.submenu = fileMenu

    NSApp.mainMenu = mainMenu
  }
}
