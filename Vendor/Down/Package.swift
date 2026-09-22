// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "Down",
    platforms: [
        .macOS("10.11"),
        .iOS("9.0"),
        .tvOS("9.0")
    ],
    products: [
        .library(
            name: "Down",
            targets: ["Down"]
        )
    ],
    targets: [
        .target(
            name: "libcmark",
            dependencies: [],
            path: "Source/cmark",
            exclude: ["include"],
            publicHeadersPath: "./"
        ),
        .target(
            name: "Down",
            dependencies: ["libcmark"],
            path: "Source/",
            exclude: ["cmark", "Down.h"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
