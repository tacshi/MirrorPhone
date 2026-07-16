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
}
