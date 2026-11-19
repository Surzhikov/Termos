// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Termos",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "Termos",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Termos"
        )
    ]
)
