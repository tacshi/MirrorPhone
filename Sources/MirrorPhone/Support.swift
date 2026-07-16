import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MirrorPhoneError: LocalizedError {
  case cameraPermission
  case sourceUnavailable(String)
  case processFailed(String)
  case noFrame

  var errorDescription: String? {
    switch self {
    case .cameraPermission:
      "iPhone capture access is blocked."
    case .sourceUnavailable(let message):
      message
    case .processFailed(let message):
      message
    case .noFrame:
      "No frame has arrived from the device yet."
    }
  }
}

enum ImageUtilities {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
    let turn = ((quarterTurns % 4) + 4) % 4
    guard turn != 0 else { return image }

    let orientation: CGImagePropertyOrientation =
      switch turn {
      case 1: .right
      case 2: .down
      default: .left
      }
    let oriented = CIImage(cgImage: image).oriented(orientation)
    let extent = oriented.extent.integral
    let normalized = oriented.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    return context.createCGImage(normalized, from: normalized.extent) ?? image
  }

  static func writePNG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw MirrorPhoneError.processFailed("Could not create the PNG file.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw MirrorPhoneError.processFailed("Could not finish writing the PNG file.")
    }
  }
}
