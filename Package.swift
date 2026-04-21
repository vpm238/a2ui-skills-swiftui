// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "A2UISkills",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "A2UISkills", targets: ["A2UISkills"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vpm238/a2ui-swiftui.git", branch: "main"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "A2UISkills",
            dependencies: [
                .product(name: "A2UI", package: "a2ui-swiftui"),
                "Yams",
            ]
        ),
        .testTarget(
            name: "A2UISkillsTests",
            dependencies: ["A2UISkills"]
        ),
    ]
)
