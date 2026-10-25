// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "muCommonLISP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MuLispCore", targets: ["MuLispCore"]),
        .executable(name: "mulisp", targets: ["mulisp"]),
        .executable(name: "muCommonLISP", targets: ["muCommonLISP"]),
    ],
    targets: [
        .target(
            name: "MuLispCore",
            path: "Sources/MuLispCore"
        ),
        .executableTarget(
            name: "mulisp",
            dependencies: ["MuLispCore"],
            path: "Sources/mulisp"
        ),
        .executableTarget(
            name: "muCommonLISP",
            dependencies: ["MuLispCore"],
            path: "Sources/MuLispApp"
        ),
        .testTarget(
            name: "MuLispCoreTests",
            dependencies: ["MuLispCore"],
            path: "Tests/MuLispCoreTests"
        ),
    ]
)
