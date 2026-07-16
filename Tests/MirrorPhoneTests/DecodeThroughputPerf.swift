import CoreGraphics
import Foundation
import Testing

@testable import MirrorPhone

@Suite("Decode throughput (manual perf harness)")
struct DecodeThroughputPerf {
  @Test(
    "Measures decode-path throughput on a captured stream",
    .enabled(if: ProcessInfo.processInfo.environment["MIRRORPHONE_PERF_H264"] != nil)
  )
  func decodeThroughput() throws {
    let path = ProcessInfo.processInfo.environment["MIRRORPHONE_PERF_H264"]!
    let stream = try Data(contentsOf: URL(fileURLWithPath: path))

    let rendered = ManagedAtomic()
    let decoder = H264Decoder(onFrame: { _ in rendered.increment() })

    var parser = AnnexBParser()
    var sps: Data?
    var pps: Data?
    var configured = false
    var decoded = 0
    let start = ContinuousClock.now

    var offset = 0
    let chunkSize = 65_536
    while offset < stream.count {
      let end = min(offset + chunkSize, stream.count)
      for nalUnit in parser.append(stream.subdata(in: offset..<end)) {
        guard let header = nalUnit.first else { continue }
        switch header & 0x1F {
        case 7: sps = nalUnit
        case 8: pps = nalUnit
        case 1, 5:
          if !configured, let sps, let pps {
            var payload = Data()
            payload.appendUInt16(UInt16(sps.count))
            payload.append(sps)
            payload.appendUInt16(UInt16(pps.count))
            payload.append(pps)
            try decoder.configure(with: payload)
            configured = true
          }
          guard configured else { continue }
          var sample = Data()
          sample.appendUInt32(UInt32(nalUnit.count))
          sample.append(nalUnit)
          decoder.decode(sample)
          decoded += 1
        default: break
        }
      }
      offset = end
    }

    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    print(
      "PERF frames=\(decoded) rendered=\(rendered.value) elapsed=\(String(format: "%.2f", seconds))s "
        + "fps=\(String(format: "%.1f", Double(decoded) / seconds))"
    )
    #expect(decoded > 0)
  }
}

private final class ManagedAtomic: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
