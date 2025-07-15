// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FaultOrdering",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "FaultOrdering", type: .dynamic, targets: ["FaultOrdering"]),
        .library(name: "FaultOrderingTests", targets: ["FaultOrderingTests"]),
    ],
    dependencies: [
      .package(url: "https://github.com/EmergeTools/SimpleDebugger", exact: "1.0.0"),
      .package(url: "https://github.com/swhitty/FlyingFox.git", exact: "0.16.0"),
    ],
    targets: [
      .target(name: "FaultOrderingSwift", dependencies: ["FlyingFox"]),
      .target(name: "FaultOrdering", dependencies: ["SimpleDebugger", "FaultOrderingSwift"], path: "Sources/EMGFaultOrdering"),
      .target(name: "FaultOrderingTests", dependencies: ["FlyingFox"]),
    ],
    cxxLanguageStandard: .cxx14
)
