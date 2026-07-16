// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MirrorPhone",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "MirrorPhone", targets: ["MirrorPhone"])
  ],
  targets: [
    .target(
      name: "MirrorPhoneUSB",
      path: "Sources/MirrorPhoneUSB",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("IOUSBHost"),
      ]
    ),
    .executableTarget(
      name: "MirrorPhone",
      dependencies: ["MirrorPhoneUSB"],
      path: "Sources/MirrorPhone",
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
    .testTarget(
      name: "MirrorPhoneTests",
      dependencies: ["MirrorPhone"]
    ),
  ]
)
