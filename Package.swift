// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IndependentEditor",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "IndependentEditor", targets: ["IndependentEditor"])],
    targets: [
        .target(name: "EditorCore"),
        .target(name: "MediaEngine", dependencies: ["EditorCore"]),
        .executableTarget(name: "IndependentEditor", dependencies: ["EditorCore", "MediaEngine"]),
        .executableTarget(name: "CoreChecks", dependencies: ["EditorCore", "MediaEngine"], path: "Tests/EditorCoreTests"),
        // swift test 入口：需要完整 Xcode（XCTest），运行与 CoreChecks 相同的检查。
        .testTarget(name: "CoreChecksXCTests", dependencies: ["CoreChecks"], path: "Tests/CoreChecksXCTests")
    ],
    swiftLanguageModes: [.v5]
)
