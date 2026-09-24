// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFMe",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PDFMe", targets: ["PDFMe"])],
    targets: [
        .target(name: "PDFMeCore"),
        .executableTarget(name: "PDFMe", dependencies: ["PDFMeCore"]),
        .testTarget(name: "PDFMeCoreTests", dependencies: ["PDFMeCore"])
    ]
)
