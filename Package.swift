// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFMe",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PDFMe", targets: ["PDFMe"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "PDFMeCore"),
        .executableTarget(name: "PDFMe", dependencies: ["PDFMeCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PDFMeCoreTests", dependencies: ["PDFMeCore"])
    ]
)
