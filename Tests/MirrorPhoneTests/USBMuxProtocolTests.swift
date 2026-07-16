import Foundation
import Testing

@testable import MirrorPhone

@Suite("iPhone USB transport")
struct USBMuxProtocolTests {
  @Test("Encodes and decodes usbmuxd plist packets")
  func packetRoundTrip() throws {
    let original: [String: Any] = [
      "MessageType": "Connect",
      "DeviceID": 42,
      "PortNumber": Int(USBMuxCompanionReceiver.companionPort.bigEndian),
    ]
    let packet = try USBMuxClient.encodedPacket(plist: original, tag: 7)
    let decoded = try USBMuxClient.decodePacket(packet)

    #expect(decoded.consumed == packet.count)
    #expect(decoded.plist["MessageType"] as? String == "Connect")
    #expect((decoded.plist["DeviceID"] as? NSNumber)?.intValue == 42)
  }

  @Test("Tracks native usbmuxd attach and detach events")
  func deviceEvents() throws {
    var state = USBMuxDeviceEventState()
    let attached: [String: Any] = [
      "MessageType": "Attached",
      "DeviceID": 17,
      "Properties": [
        "ConnectionType": "USB",
        "SerialNumber": "00008130-TEST",
      ],
    ]

    let didAttach = state.apply(attached)
    #expect(didAttach)
    #expect(state.devices == [USBMuxDevice(deviceID: 17, serialNumber: "00008130-TEST")])
    let didChangeDuplicate = state.apply(attached)
    #expect(!didChangeDuplicate)
    let didDetach = state.apply(["MessageType": "Detached", "DeviceID": 17])
    #expect(didDetach)
    #expect(state.devices.isEmpty)
  }

  @Test("Consumes complete packets and preserves an incomplete packet")
  func streamingPackets() throws {
    let first = try USBMuxClient.encodedPacket(
      plist: ["MessageType": "Attached", "DeviceID": 1],
      tag: 1
    )
    let second = try USBMuxClient.encodedPacket(
      plist: ["MessageType": "Detached", "DeviceID": 1],
      tag: 2
    )
    var stream = first + second.prefix(12)

    let packets = try USBMuxClient.takePackets(from: &stream)
    #expect(packets.count == 1)
    #expect(packets.first?["MessageType"] as? String == "Attached")
    #expect(stream == second.prefix(12))

    stream.append(second.dropFirst(12))
    let remainingPackets = try USBMuxClient.takePackets(from: &stream)
    #expect(remainingPackets.count == 1)
    #expect(remainingPackets.first?["MessageType"] as? String == "Detached")
    #expect(stream.isEmpty)
  }

  @Test("Queries macOS USB device service")
  func listsDevices() throws {
    var tag: UInt32 = 1
    let devices = try USBMuxClient.listUSBDevices(nextTag: &tag)
    #expect(devices.allSatisfy { !$0.serialNumber.isEmpty })
    #expect(tag == 2)
  }
}
