// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "FstMarkdownCore",
    platforms: [
        .macOS("10.11"),
        .iOS("9.0"),
        .tvOS("9.0")
    ],
    products: [
        .library(
            name: "libcmark",
            targets: ["libcmark"]
        )
    ],
    targets: [
        .target(
            name: "libcmark",
            dependencies: [],
            path: "Source/cmark",
            exclude: ["include"],
            publicHeadersPath: "./"
        )
    ],
    swiftLanguageVersions: [.v5]
)
