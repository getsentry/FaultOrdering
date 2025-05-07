// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EMGFaultOrdering",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "EMGFaultOrdering", targets: ["EMGFaultOrdering"]),
    ],
    dependencies: [
      .package(url: "https://github.com/EmergeTools/SimpleDebugger", revision: "e0ad1cd304132efa0ab3b4707bd0eea761dbe2b5"),
    ],
    targets: [
      .target(name: "EMGFaultOrdering", dependencies: ["SimpleDebugger"], path: "Sources/EMGFaultOrdering"),
    ],
    cxxLanguageStandard: .cxx14
)
