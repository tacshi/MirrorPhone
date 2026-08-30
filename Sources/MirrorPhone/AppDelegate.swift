import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowCoordinator: MirrorWindowCoordinator?
  private var terminationTask: Task<Void, Never>?

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMainMenu()
    let coordinator = MirrorWindowCoordinator()
    windowCoordinator = coordinator
    coordinator.start()
    NSApp.activate(ignoringOtherApps: true)
    registerCameraPermission()
  }

  func applicationWillTerminate(_ notification: Notification) {
    windowCoordinator?.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let windowCoordinator, windowCoordinator.hasRecordingsToFinalize else {
      return .terminateNow
    }
    guard terminationTask == nil else { return .terminateLater }
    terminationTask = Task { @MainActor [weak self, weak sender] in
      let succeeded = await windowCoordinator.finalizeRecordingsForTermination()
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

  @objc private func newWindow(_ sender: Any?) {
    windowCoordinator?.openWindow(sender)
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

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let newWindowItem = fileMenu.addItem(
      withTitle: "New Window",
      action: #selector(newWindow(_:)),
      keyEquivalent: "n"
    )
    newWindowItem.target = self
    fileMenu.addItem(.separator())
    let recordingItem = fileMenu.addItem(
      withTitle: "Start Recording…",
      action: #selector(MirrorWindowController.toggleRecording(_:)),
      keyEquivalent: "r"
    )
    recordingItem.target = nil
    let captureItem = fileMenu.addItem(
      withTitle: "Capture Image", action: #selector(MirrorWindowController.captureImage(_:)),
      keyEquivalent: "s")
    captureItem.target = nil
    fileMenuItem.submenu = fileMenu

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    let actualSizeItem = viewMenu.addItem(
      withTitle: "Actual Size", action: #selector(MirrorWindowController.actualSize(_:)),
      keyEquivalent: "0")
    actualSizeItem.target = nil
    viewMenu.addItem(.separator())
    let qualityItem = viewMenu.addItem(withTitle: "Quality Profile", action: nil, keyEquivalent: "")
    let qualityMenu = NSMenu(title: "Quality Profile")
    let qualityActions: [(String, Selector)] = [
      ("Auto", #selector(MirrorWindowController.selectAutomaticQuality(_:))),
      ("Quality", #selector(MirrorWindowController.selectQualityQuality(_:))),
      ("Balanced", #selector(MirrorWindowController.selectBalancedQuality(_:))),
      ("Performance", #selector(MirrorWindowController.selectPerformanceQuality(_:))),
    ]
    for (title, action) in qualityActions {
      let item = qualityMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = nil
    }
    qualityItem.submenu = qualityMenu
    viewMenuItem.submenu = viewMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    let minimizeItem = windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    minimizeItem.target = nil
    let zoomItem = windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    zoomItem.target = nil
    windowMenu.addItem(.separator())
    let frontItem = windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )
    frontItem.target = NSApp
    windowMenuItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }
}
