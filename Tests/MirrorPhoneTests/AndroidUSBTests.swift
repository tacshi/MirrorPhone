import Foundation
import Testing

@testable import MirrorPhone

@Suite("Android USB transport")
struct AndroidUSBTests {
  @Test("Parses only authorized ADB devices")
  func parsesDeviceList() {
    let output = """
      List of devices attached
      emulator-5554          device product:sdk model:Pixel_9 device:emu transport_id:1
      R58M1234               unauthorized usb:1-2 transport_id:2
      ABC123                 offline usb:1-3 transport_id:3

      """

    #expect(
      AndroidADB.parseDeviceList(output) == [
        AndroidADBDevice(serial: "emulator-5554", name: "Pixel 9")
      ]
    )
  }

  @Test("Parses fragmented ADB device tracking snapshots")
  func parsesTrackedDevices() {
    let payload =
      "RFCY7126ARP device usb:17825792X product:pa1qxxx model:SM_S931B transport_id:4\n"
    let frame = Data(String(format: "%04x", payload.utf8.count).utf8) + Data(payload.utf8)
    var parser = ADBTrackDevicesParser()

    #expect(parser.append(Data(frame.prefix(3))).isEmpty)
    #expect(
      parser.append(Data(frame.dropFirst(3))) == [
        [AndroidADBDevice(serial: "RFCY7126ARP", name: "SM S931B")]
      ]
    )
    #expect(parser.append(Data("0000".utf8)) == [[]])
  }

  @Test("Parses fragmented Android rotation events")
  func parsesRotationEvents() {
    var parser = AndroidRotationLogParser()
    let first = "I/WindowManager: Display id=0 rotation changed to 3 fr"
    let second = "om 0, lastOrientation=4\n"
    let ignored = "I/WindowManager: Display id=1 rotation changed to 2 from 0\n"

    #expect(parser.append(Data(first.utf8)).isEmpty)
    #expect(parser.append(Data(second.utf8)) == [3])
    #expect(parser.append(Data(ignored.utf8)).isEmpty)
    #expect(
      AndroidRotationLogParser.rotation(
        in: "I/WindowManager: Display id=0 rotation changed to 0 from 3"
      ) == 0
    )
  }

  @Test("Parses Android display size and creates an encoder-safe fallback")
  func parsesDisplaySize() {
    #expect(
      AndroidDisplaySize.parseWMSize("Physical size: 1920x2560\n")
        == AndroidDisplaySize(width: 1920, height: 2560)
    )
    #expect(
      AndroidDisplaySize.parseWMSize(
        "Physical size: 1920x2560\nOverride size: 1440x1920\n"
      ) == AndroidDisplaySize(width: 1440, height: 1920)
    )
    #expect(
      AndroidDisplaySize(width: 1920, height: 2560).screenrecordFallback
        == AndroidDisplaySize(width: 1080, height: 1440)
    )
    #expect(
      AndroidDisplaySize(width: 2560, height: 1920).screenrecordFallback
        == AndroidDisplaySize(width: 1440, height: 1080)
    )
  }

  @Test("Uses framebuffer polling for Smart X3 Pro")
  func selectsEInkCaptureCompatibility() {
    #expect(AndroidVideoCompatibility.requiresFramebufferPolling(deviceName: "Smart X3 Pro"))
    #expect(!AndroidVideoCompatibility.requiresFramebufferPolling(deviceName: "Pixel 9"))
  }

  @Test("Parses fragmented consecutive PNG images")
  func parsesPNGStream() {
    let first = fakePNG(payload: Data([1, 2, 3]))
    let second = fakePNG(payload: Data([4, 5]))
    var parser = PNGStreamParser()

    #expect(parser.append(Data(first.prefix(11))).isEmpty)
    #expect(parser.append(Data(first.dropFirst(11)) + second) == [first, second])
  }

  @Test("Parses Annex B start codes split across reads")
  func parsesSplitAnnexBStream() {
    var parser = AnnexBParser()

    #expect(parser.append(Data([0x00, 0x00])).isEmpty)
    let first = parser.append(
      Data([0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x01, 0x68, 0xCE])
    )
    #expect(first == [Data([0x67, 0x42])])
    #expect(parser.finish() == Data([0x68, 0xCE]))
  }

  @Test("Accepts both three-byte and four-byte Annex B start codes")
  func parsesMixedStartCodes() {
    var parser = AnnexBParser()
    let units = parser.append(
      Data([
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88,
        0x00, 0x00, 0x01, 0x41, 0x9A,
        0x00, 0x00, 0x00, 0x01, 0x06, 0x05,
      ])
    )

    #expect(units == [Data([0x65, 0x88]), Data([0x41, 0x9A])])
    #expect(parser.finish() == Data([0x06, 0x05]))
  }

  private func fakePNG(payload: Data) -> Data {
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.appendUInt32(UInt32(payload.count))
    png.append(Data("IDAT".utf8))
    png.append(payload)
    png.append(Data(repeating: 0, count: 4))
    png.appendUInt32(0)
    png.append(Data("IEND".utf8))
    png.append(Data(repeating: 0, count: 4))
    return png
  }
}
