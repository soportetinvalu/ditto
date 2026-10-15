// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "MemoriaLocal",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MemoriaLocal", targets: ["MemoriaLocal"])],
    targets: [
        .target(name: "ClipCore", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MemoriaLocal", dependencies: ["ClipCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"),
                                           .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "MemoriaLocalTests", dependencies: ["MemoriaLocal", "ClipCore"])
    ]
)
