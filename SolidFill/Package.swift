// swift-tools-version:5.9
import PackageDescription

let fast: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]

let package = Package(
    name: "SolidFill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SolidFillApp", targets: ["SolidFillApp"]),
        .executable(name: "solidfill", targets: ["solidfill"]),
    ],
    targets: [
        .target(name: "SolidFillCore", swiftSettings: fast),
        .executableTarget(name: "solidfill", dependencies: ["SolidFillCore"], swiftSettings: fast),
        .executableTarget(name: "SolidFillApp", dependencies: ["SolidFillCore"], swiftSettings: fast),
    ],
    swiftLanguageVersions: [.v5]
)
