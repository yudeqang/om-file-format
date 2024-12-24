// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if arch(x86_64)
// Docker and Ubuntu release system uses `march=skylake`
let mArch = ProcessInfo.processInfo.environment["MARCH_SKYLAKE"] == "TRUE" ? ["-march=skylake"] : ["-march=native"]
#else
let mArch: [String] = []
#endif

let swiftFlags: [PackageDescription.SwiftSetting] = [
    .unsafeFlags(["-cross-module-optimization", "-Ounchecked"],
    .when(configuration: .release))
]

// Note: Fast math flags reduce performance for compression
let cFlagsPFor2D = [PackageDescription.CSetting.unsafeFlags(["-O3"] + mArch)]
let cFlagsPFor = [PackageDescription.CSetting.unsafeFlags(["-O3", "-Wall", "-Werror"] + mArch)]


let package = Package(
    name: "om-file-format",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OmFileFormat",
            targets: ["OmFileFormatSwift"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "OmFileFormatSwift",
            dependencies: ["OmFileFormatC"],
            cSettings: cFlagsPFor2D,
            swiftSettings: swiftFlags
        ),
        .target(
            name: "OmFileFormatC",
            cSettings: cFlagsPFor,
            swiftSettings: swiftFlags
        ),
        .testTarget(
            name: "OmFileFormatTests",
            dependencies: ["OmFileFormatSwift"]
        ),
    ]
)
