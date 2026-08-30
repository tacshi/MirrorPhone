import Foundation
import AppKit
import Testing

@testable import MirrorPhone

@Suite("Android clipboard wire protocol")
struct AndroidClipboardWireTests {
  @Test("Carries multiline Unicode text through Base64 framing")
  func unicodeRoundTrip() throws {
    let text = "First line\n世界 👋\nLast line"
    let token = try AndroidClipboardWire.encodedText(text)
    let command = try AndroidClipboardWire.pasteCommand(requestID: 42, text: text)

    #expect(command == "cb-paste 42 \(token)\n")
    #expect(AndroidClipboardWire.decodedText(Substring(token)) == text)
    #expect(AndroidClipboardWire.decodedText("-") == "")
  }

  @Test("Rejects clipboard text larger than 256 KiB")
  func rejectsOversizedText() {
    let oversized = String(
      repeating: "a",
      count: AndroidClipboardWire.maximumTextBytes + 1
    )

    #expect(throws: DeviceClipboardError.self) {
      try AndroidClipboardWire.encodedText(oversized)
    }
  }

  @Test("Parses fragmented readiness, results, states, and events")
  func parsesFragmentedOutput() throws {
    let unicode = try AndroidClipboardWire.encodedText("copied\n文本")
    let reason = try AndroidClipboardWire.encodedText("listener stopped")
    let output =
      "READY clipboard=sync\r\n"
        + "cb-event 7 text \(unicode)\n"
        + "cb-result 19 empty\n"
        + "cb-result 20 unsupported\n"
        + "cb-result 21 ok\n"
        + "cb-result 22 error \(reason)\n"
        + "cb-state manual \(reason)\n"
    let stream = Data(output.utf8)
    var parser = AndroidInputServerOutputParser()

    let first = parser.append(Data(stream.prefix(11)))
    let second = parser.append(Data(stream.dropFirst(11).prefix(17)))
    let third = parser.append(Data(stream.dropFirst(28)))

    #expect(first.isEmpty)
    #expect(second == [.ready(.sync)])
    #expect(
      third == [
        .clipboardEvent(7, .text("copied\n文本")),
        .clipboardResult(19, .content(.empty)),
        .clipboardResult(20, .content(.unsupported)),
        .clipboardResult(21, .ok),
        .clipboardResult(22, .failure("listener stopped")),
        .clipboardState(.manual, "listener stopped"),
      ]
    )
  }

  @Test("Ignores malformed, unknown, and overlong protocol lines")
  func ignoresMalformedOutput() {
    var parser = AndroidInputServerOutputParser()
    let malformed = Data(
      ("diagnostic noise\n"
        + "cb-event nope empty\n"
        + "cb-event 2 empty extra\n"
        + "cb-result 1 text %%%\n"
        + "cb-result 2 ok extra\n"
        + "cb-state manual %%%\n").utf8
    )
    #expect(parser.append(malformed).isEmpty)

    let overlong = Data(repeating: 0x61, count: AndroidClipboardWire.maximumLineBytes + 1)
    #expect(parser.append(overlong).isEmpty)
    #expect(parser.append(Data("\nREADY clipboard=manual\n".utf8)) == [.ready(.manual)])
  }

  @Test("Drops duplicate and out-of-order clipboard event sequences")
  func sequencesAreMonotonic() {
    var sequencer = AndroidClipboardEventSequencer()

    let first = sequencer.accept(4)
    let duplicate = sequencer.accept(4)
    let older = sequencer.accept(3)
    let newer = sequencer.accept(9)
    #expect(first)
    #expect(!duplicate)
    #expect(!older)
    #expect(newer)
    sequencer.reset()
    let afterReset = sequencer.accept(1)
    #expect(afterReset)
  }
}

@Suite("Clipboard activation policy")
struct MirrorClipboardActivationPolicyTests {
  @Test("Only the current key Android window applies automatic updates")
  func requiresActiveCurrentWindow() {
    #expect(
      MirrorClipboardActivationPolicy.acceptsAutomaticUpdate(
        isApplicationActive: true,
        isWindowKey: true,
        isSourceCurrent: true,
        isDeviceConnected: true,
        isTransitioning: false,
        isClosing: false
      )
    )

    let rejectedStates: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
      (false, true, true, true, false, false),
      (true, false, true, true, false, false),
      (true, true, false, true, false, false),
      (true, true, true, false, false, false),
      (true, true, true, true, true, false),
      (true, true, true, true, false, true),
    ]
    for state in rejectedStates {
      #expect(
        !MirrorClipboardActivationPolicy.acceptsAutomaticUpdate(
          isApplicationActive: state.0,
          isWindowKey: state.1,
          isSourceCurrent: state.2,
          isDeviceConnected: state.3,
          isTransitioning: state.4,
          isClosing: state.5
        )
      )
    }
  }
}

@MainActor
private final class InMemoryMirrorPasteboard: MirrorPasteboard {
  var plainText: String?
  private(set) var replacements = [String?]()
  var acceptsWrites = true

  init(_ plainText: String? = nil) {
    self.plainText = plainText
  }

  func replacePlainText(with text: String?) -> Bool {
    replacements.append(text)
    guard acceptsWrites else { return false }
    plainText = text
    return true
  }
}

@MainActor
private final class ClipboardWindowKeyState {
  var isKey: Bool

  init(_ isKey: Bool) {
    self.isKey = isKey
  }
}

@MainActor
private final class ClipboardTestMirrorSource: MirrorSource, DeviceClipboardBridge {
  var onFrame: ((CGImage) -> Void)?
  var onStatus: ((String) -> Void)?
  var clipboardState = DeviceClipboardState.synchronized
  var onClipboardStateChanged: ((DeviceClipboardState) -> Void)?
  var onClipboardContentChanged: ((DeviceClipboardContent) -> Void)?
  var clipboardBridge: DeviceClipboardBridge? { self }
  var nextReadContent = DeviceClipboardContent.text("Android text")
  private(set) var selectionOperations = [DeviceClipboardSelectionOperation]()
  private(set) var pastedTexts = [String]()
  private var pendingRead: CheckedContinuation<DeviceClipboardContent, any Error>?
  var suspendsNextRead = false

  func start() async throws {}
  func stop() async {}

  func readSelection(
    _ operation: DeviceClipboardSelectionOperation
  ) async throws -> DeviceClipboardContent {
    selectionOperations.append(operation)
    if suspendsNextRead {
      suspendsNextRead = false
      return try await withCheckedThrowingContinuation { continuation in
        pendingRead = continuation
      }
    }
    return nextReadContent
  }

  func paste(_ text: String) async throws {
    pastedTexts.append(text)
  }

  func emit(_ content: DeviceClipboardContent) {
    onClipboardContentChanged?(content)
  }

  func setClipboardState(_ state: DeviceClipboardState) {
    clipboardState = state
    onClipboardStateChanged?(state)
  }

  func resumeRead(with content: DeviceClipboardContent) {
    pendingRead?.resume(returning: content)
    pendingRead = nil
  }
}

@MainActor
private final class ClipboardTestSourceFactory: MirrorSourceCreating {
  private(set) var sources = [String: ClipboardTestMirrorSource]()

  func makeSource(for device: MirrorDevice) -> any MirrorSource {
    let source = ClipboardTestMirrorSource()
    sources[device.id] = source
    return source
  }
}

@MainActor
@Suite("Android clipboard window integration")
struct AndroidClipboardWindowTests {
  @Test("Copy, cut, paste, empty, unsupported, and duplicate text use the active bridge")
  func explicitAndAutomaticClipboardBehavior() async throws {
    let keyState = ClipboardWindowKeyState(true)
    let pasteboard = InMemoryMirrorPasteboard("Mac text")
    let factory = ClipboardTestSourceFactory()
    let device = clipboardTestDevice("primary")
    let controller = MirrorWindowController(
      sourceFactory: factory,
      pasteboard: pasteboard,
      applicationIsActive: { true },
      windowIsKey: { keyState.isKey }
    )
    controller.apply(assignment: clipboardAssignment(device))
    let source = try await requireClipboardSource(factory, deviceID: device.id)

    source.nextReadContent = .text("Copied from Android")
    controller.copyFromAndroid(nil)
    await settleClipboardTasks()
    #expect(source.selectionOperations == [.copy])
    #expect(pasteboard.plainText == "Copied from Android")

    source.nextReadContent = .empty
    controller.cutFromAndroid(nil)
    await settleClipboardTasks()
    #expect(source.selectionOperations == [.copy, .cut])
    #expect(pasteboard.plainText == nil)

    pasteboard.plainText = "Paste\n文本"
    controller.pasteToAndroid(nil)
    await settleClipboardTasks()
    #expect(source.pastedTexts == ["Paste\n文本"])

    pasteboard.plainText = "Keep me"
    let replacementCount = pasteboard.replacements.count
    source.nextReadContent = .unsupported
    controller.copyFromAndroid(nil)
    await settleClipboardTasks()
    #expect(pasteboard.plainText == "Keep me")
    #expect(pasteboard.replacements.count == replacementCount)

    source.emit(.text("Keep me"))
    #expect(pasteboard.replacements.count == replacementCount)
    source.emit(.text("Automatic update"))
    #expect(pasteboard.plainText == "Automatic update")

    keyState.isKey = false
    source.emit(.text("Background value"))
    #expect(pasteboard.plainText == "Automatic update")
    keyState.isKey = true
    // Becoming key does not replay the ignored value.
    #expect(pasteboard.plainText == "Automatic update")

    controller.window?.close()
    await settleClipboardTasks()
  }

  @Test("A completion from a disconnected source cannot overwrite the Mac clipboard")
  func staleCompletionIsIgnored() async throws {
    let pasteboard = InMemoryMirrorPasteboard("Original")
    let factory = ClipboardTestSourceFactory()
    let device = clipboardTestDevice("stale")
    let controller = MirrorWindowController(
      sourceFactory: factory,
      pasteboard: pasteboard,
      applicationIsActive: { true },
      windowIsKey: { true }
    )
    controller.apply(assignment: clipboardAssignment(device))
    let source = try await requireClipboardSource(factory, deviceID: device.id)
    source.suspendsNextRead = true

    controller.copyFromAndroid(nil)
    await settleClipboardTasks()
    controller.apply(assignment: .empty)
    await settleClipboardTasks()
    source.resumeRead(with: .text("Stale"))
    await settleClipboardTasks()

    #expect(pasteboard.plainText == "Original")
    controller.window?.close()
    await settleClipboardTasks()
  }

  @Test("Clipboard menu validation follows bridge availability and in-flight work")
  func menuValidationTracksClipboardState() async throws {
    let pasteboard = InMemoryMirrorPasteboard("Mac text")
    let factory = ClipboardTestSourceFactory()
    let device = clipboardTestDevice("menus")
    let controller = MirrorWindowController(
      sourceFactory: factory,
      pasteboard: pasteboard,
      applicationIsActive: { true },
      windowIsKey: { true }
    )
    let copyItem = NSMenuItem(
      title: "Copy",
      action: #selector(MirrorWindowController.copyFromAndroid(_:)),
      keyEquivalent: "c"
    )
    let pasteItem = NSMenuItem(
      title: "Paste",
      action: #selector(MirrorWindowController.pasteToAndroid(_:)),
      keyEquivalent: "v"
    )

    #expect(!controller.validateMenuItem(copyItem))
    controller.apply(assignment: clipboardAssignment(device))
    let source = try await requireClipboardSource(factory, deviceID: device.id)
    #expect(controller.validateMenuItem(copyItem))
    #expect(controller.validateMenuItem(pasteItem))

    source.setClipboardState(.unavailable("blocked by vendor policy"))
    #expect(!controller.validateMenuItem(copyItem))
    source.setClipboardState(.manual("automatic events unavailable"))
    #expect(controller.validateMenuItem(copyItem))

    source.suspendsNextRead = true
    controller.copyFromAndroid(nil)
    await settleClipboardTasks()
    #expect(!controller.validateMenuItem(copyItem))
    #expect(!controller.validateMenuItem(pasteItem))
    source.resumeRead(with: .text("Finished"))
    await settleClipboardTasks()
    #expect(controller.validateMenuItem(copyItem))

    pasteboard.plainText = nil
    #expect(!controller.validateMenuItem(pasteItem))

    controller.window?.close()
    await settleClipboardTasks()
  }

  @Test("Automatic updates from a background Android window do not race the key window")
  func simultaneousWindowsUseOnlyKeySource() async throws {
    let firstKeyState = ClipboardWindowKeyState(false)
    let secondKeyState = ClipboardWindowKeyState(true)
    let pasteboard = InMemoryMirrorPasteboard("Original")
    let firstFactory = ClipboardTestSourceFactory()
    let secondFactory = ClipboardTestSourceFactory()
    let firstDevice = clipboardTestDevice("first")
    let secondDevice = clipboardTestDevice("second")
    let first = MirrorWindowController(
      sourceFactory: firstFactory,
      pasteboard: pasteboard,
      applicationIsActive: { true },
      windowIsKey: { firstKeyState.isKey }
    )
    let second = MirrorWindowController(
      sourceFactory: secondFactory,
      pasteboard: pasteboard,
      applicationIsActive: { true },
      windowIsKey: { secondKeyState.isKey }
    )
    first.apply(assignment: clipboardAssignment(firstDevice))
    second.apply(assignment: clipboardAssignment(secondDevice))
    let firstSource = try await requireClipboardSource(firstFactory, deviceID: firstDevice.id)
    let secondSource = try await requireClipboardSource(secondFactory, deviceID: secondDevice.id)

    firstSource.emit(.text("Background"))
    secondSource.emit(.text("Key window"))
    #expect(pasteboard.plainText == "Key window")

    firstKeyState.isKey = true
    secondKeyState.isKey = false
    secondSource.emit(.text("Now background"))
    firstSource.emit(.text("Now key"))
    #expect(pasteboard.plainText == "Now key")

    first.window?.close()
    second.window?.close()
    await settleClipboardTasks()
  }
}

@MainActor
private func clipboardTestDevice(_ id: String) -> MirrorDevice {
  MirrorDevice(
    id: "adb:\(id)",
    name: id,
    detail: "Android · USB debugging",
    kind: .androidADB(serial: id)
  )
}

private func clipboardAssignment(_ device: MirrorDevice) -> MirrorWindowAssignment {
  MirrorWindowAssignment(
    selectedDevice: device,
    isSelectedDeviceConnected: true,
    pendingDeviceID: nil,
    options: [MirrorDeviceOption(device: device, state: .selected)],
    isTransitioning: false
  )
}

@MainActor
private func requireClipboardSource(
  _ factory: ClipboardTestSourceFactory,
  deviceID: String
) async throws -> ClipboardTestMirrorSource {
  for _ in 0..<30 where factory.sources[deviceID] == nil {
    await Task.yield()
  }
  return try #require(factory.sources[deviceID])
}

@MainActor
private func settleClipboardTasks() async {
  for _ in 0..<20 {
    await Task.yield()
  }
}
