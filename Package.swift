// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Transcriber",
    defaultLocalization: "en",
    platforms: [.macOS("13.3")],
    products: [.executable(name: "Transcriber", targets: ["Transcriber"])],
    targets: [
        .binaryTarget(name: "whisper",
                      url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.3/whisper-v1.8.3-xcframework.zip",
                      checksum: "a970006f256c8e689bc79e73f7fa7ddb8c1ed2703ad43ee48eb545b5bb6de6af"),
        .target(name: "TranscriberCore", resources: [.process("Resources")]),
        .target(name: "TranscriberLocal", dependencies: ["TranscriberCore", "whisper"]),
        .executableTarget(name: "Transcriber", dependencies: ["TranscriberCore", "TranscriberLocal"]),
        .testTarget(name: "TranscriberCoreTests", dependencies: ["TranscriberCore"]),
        .testTarget(name: "TranscriberLocalTests", dependencies: ["TranscriberCore", "TranscriberLocal"])
    ]
)
