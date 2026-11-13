// swift-tools-version:5.9
import PackageDescription

// BookModel (Foundation + Yams), MystSyntax, BuildService and ProjectIndex (Foundation) build on any platform.
// The SwiftUI app target exists only when the manifest is evaluated on macOS.
var products: [Product] = [
    .library(name: "BookModel", targets: ["BookModel"]),
    .library(name: "MystSyntax", targets: ["MystSyntax"]),
    .library(name: "BuildService", targets: ["BuildService"]),
    .library(name: "ProjectIndex", targets: ["ProjectIndex"]),
]
var targets: [Target] = [
    .target(
        name: "BookModel",
        dependencies: [.product(name: "Yams", package: "Yams")]
    ),
    // MyST highlighting, spell-check ranges and outline; Foundation only.
    .target(name: "MystSyntax"),
    // Finding and running jupyter-book / myst, parsing build logs, the managed toolchain.
    .target(name: "BuildService"),
    // Labels, citations and files of a book; completion and diagnostics.
    .target(name: "ProjectIndex", dependencies: ["MystSyntax"]),
]

#if os(macOS)
products.append(.executable(name: "JupyterBookNook", targets: ["JupyterBookNook"]))
// Resources: the app icon (AppIcon.png), also shown in the Dock when started with `swift run`.
targets.append(.executableTarget(name: "JupyterBookNook", dependencies: ["BookModel", "MystSyntax", "BuildService", "ProjectIndex"],
                                 resources: [.copy("Resources/AppIcon.png")]))
#endif

let package = Package(
    name: "JupyterBookNook",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: targets
)
