// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v15)],
    targets: [
        // Reads the hardware: Apple silicon's temperature sensors and the SMC (fans, power). C, no UI.
        .target(name: "Sensors", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // The menu bar app.
        .executableTarget(name: "Vitals", dependencies: ["Sensors"]),
    ],
    swiftLanguageModes: [.v5]
)
