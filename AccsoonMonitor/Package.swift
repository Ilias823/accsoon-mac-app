// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AccsoonMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        // Packet parsing and reassembly. No Apple media frameworks, so it is easy to test.
        .target(name: "CineEyeProtocol"),
        // H.264 Annex-B to CoreMedia sample buffers.
        .target(name: "CineEyeVideo", dependencies: ["CineEyeProtocol"]),
        .executableTarget(name: "AccsoonMonitor", dependencies: ["CineEyeProtocol", "CineEyeVideo"]),
        // Command line check: runs a client.py --dump capture through the same pipeline as the app.
        .executableTarget(name: "cineeye-replay", dependencies: ["CineEyeProtocol", "CineEyeVideo"]),
        // Protocol checks as a plain executable, so they run without a test framework.
        .executableTarget(name: "protocol-check", dependencies: ["CineEyeProtocol", "CineEyeVideo"]),
    ]
)
