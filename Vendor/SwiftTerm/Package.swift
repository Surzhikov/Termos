// swift-tools-version:5.9
// Vendored copy of SwiftTerm v1.11.2 (MIT, Miguel de Icaza) without heavy dev dependencies.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: ["Mac/README.md"])
    ],
    swiftLanguageVersions: [.v5]
)
