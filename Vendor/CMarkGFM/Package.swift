// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "CMarkGFM",
    products: [.library(name: "libcmark", targets: ["libcmark"])],
    targets: [.target(name: "libcmark", publicHeadersPath: ".",
                      cSettings: [.define("CMARK_GFM_STATIC_DEFINE"), .define("CMARK_GFM_EXTENSIONS_STATIC_DEFINE")])]
)
