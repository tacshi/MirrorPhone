import Foundation

struct MirrorDevice: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case iosScreen(uniqueID: String)
    case androidADB(serial: String)
  }

  let id: String
  let name: String
  let detail: String
  let kind: Kind
}
