// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "NexClip",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NexClip", targets: ["NexClip"])],
    targets: [
        .target(name: "ClipCore", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "NexClip", dependencies: ["ClipCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"),
                                           .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"),
                                           .linkedFramework("Security")]),
        .testTarget(name: "NexClipTests", dependencies: ["NexClip", "ClipCore"])
    ]
)
