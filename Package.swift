// swift-tools-version:5.9
// Platform-independent core (SRT parsing, paragraphs, pairing, exporters, LLM client).
// The macOS app itself is built from project.yml (XcodeGen); this package exists so the
// core can be unit-tested with `swift test`.
import PackageDescription

let package = Package(
    name: "MinutesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"]),
    ],
    targets: [
        .target(name: "MinutesCore", path: "Sources/MinutesCore"),
        .testTarget(name: "MinutesCoreTests", dependencies: ["MinutesCore"], path: "Tests/MinutesCoreTests"),
    ]
)
