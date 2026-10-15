// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "angl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "angl", targets: ["angl"]),
        .executable(name: "angl-lists", targets: ["angl-lists"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.0"),
        // Already in the graph through SafariConverterLib; AnglCore uses it for login URI matching.
        .package(url: "https://github.com/ameshkov/swift-psl", from: "1.1.184"),
    ],
    targets: [
        // Pure model/logic: no AppKit, no WebKit. Unit-tested.
        .target(name: "AnglCore", dependencies: [
            .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
            .product(name: "PublicSuffixList", package: "swift-psl"),
        ], linkerSettings: [.linkedLibrary("sqlite3")]),
        // bitwarden/ (Rust over the official Bitwarden SDK), built by scripts/bitwarden.sh into
        // build/bitwarden/libangl_bitwarden.a.
        .systemLibrary(name: "CBitwarden", path: "Sources/CBitwarden"),
        // The browser: AppKit shell over the system WKWebView. App resources live in
        // /Resources and are copied into angl.app by scripts/bundle.sh (not SwiftPM bundles,
        // which land at the .app root and break code signing).
        .executableTarget(name: "angl", dependencies: ["AnglCore", "CBitwarden"],
                          linkerSettings: [.unsafeFlags(["-L", Context.packageDirectory + "/build/bitwarden"])]),
        .executableTarget(name: "angl-lists", dependencies: ["AnglCore"]),
        .testTarget(name: "AnglCoreTests", dependencies: ["AnglCore"]),
    ]
)
