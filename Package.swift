// swift-tools-version: 6.2
import PackageDescription
import Foundation

func selectedDeveloperDirectory() -> String {
    if let value = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !value.isEmpty {
        return value
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !value.isEmpty { return value }
    } catch {
        // SwiftPM will report the missing runtime clearly at link time.
    }
    return "/Library/Developer/CommandLineTools"
}

let developerDirectory = selectedDeveloperDirectory()
let developerLibraries = "\(developerDirectory)/Library/Developer/usr/lib"

let package = Package(
    name: "Desklog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Desklog", targets: ["Desklog"]),
        .executable(name: "DesklogSpeakerHelper", targets: ["DesklogSpeakerHelper"]),
        .executable(name: "DesklogSelfTest", targets: ["DesklogSelfTest"]),
        .executable(name: "DesklogModelSetup", targets: ["DesklogModelSetup"]),
        .library(name: "DesklogCore", targets: ["DesklogCore"])
    ],
    dependencies: [
        // Speaker centroid embeddings (used for cross-segment identity learning)
        // are newer than the 1.0.0 tag, so pin the reviewed upstream revision.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            revision: "dcf3a00f0ae4d5b57bc0aad92063b102b70d5fd1"
        ),
        // The selected Command Line Tools installation does not bundle a
        // runnable XCTest/Testing runtime. Pin the matching open-source Swift
        // Testing release so `swift test` is deterministic on developer Macs.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "70eff261d7f462cad1fff51e05bcc74aa0b0f420"
        )
    ],
    targets: [
        .target(name: "DesklogCore"),
        .executableTarget(
            name: "Desklog",
            dependencies: ["DesklogCore"]
        ),
        .executableTarget(
            name: "DesklogSpeakerHelper",
            dependencies: [
                "DesklogCore",
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ]
        ),
        .executableTarget(
            name: "DesklogSelfTest",
            dependencies: ["DesklogCore"]
        ),
        .executableTarget(
            name: "DesklogModelSetup",
            dependencies: [
                "DesklogCore",
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(
            name: "DesklogCoreTests",
            dependencies: [
                "DesklogCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", developerLibraries,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerLibraries
                ])
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
