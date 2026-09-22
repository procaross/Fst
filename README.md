# Fst

A fast, minimal native macOS text editor plus developer-focused Quick Look previews. This fork adds a QLMarkdown-style rendered Markdown view while keeping Fst's highlighted source preview. macOS 14+.

In Finder, press Space on source files to get Fst's selectable syntax-highlighted preview. Markdown files open as rendered documents and include a **预览 / 源码** switch, so a README can be read normally or inspected as Markdown without leaving Quick Look.

Quick Look uses a GitHub Light palette with a white canvas and padded code blocks. JSON previews are automatically indented without changing the file, key order, number spelling or string escapes. JSON input/output is bounded to 8 MiB; other files retain the 1 MiB preview limit. Truncated previews show a small notice.

Markdown supports inline math (`$…$`, `\(…\)`) and display math (`$$…$$`, `\[…\]`, fenced `math` / `latex`) through the bundled native SwiftMath engine. Common fractions, roots, sums, integrals and matrices render offline. Unsupported expressions remain readable as source. This is a math-mode subset, not a full TeX engine; macros, packages and full LaTeX documents are not supported.

Source and Markdown previews use viewport-based TextKit 2 layout. Formatting, syntax coloring and formula preparation run off the UI thread. Long files show an initial prefix, then the complete bounded preview; full replacement and layout warmup pause during live scrolling. Formulas are cached as Retina images.

The Markdown renderer is bundled locally with the app and uses cmark plus native AppKit text layout. It works offline and does not start WebKit or execute JavaScript.

### Development

Build and launch: `just run`. Test: `just test`; after a Release build, `Scripts/test-quicklook.sh` exercises JSON, math, viewport layout and scrolling. [Development](Development.md).

The fork uses bundle identifiers `com.procaross.Fst` and `com.procaross.Fst.QuickLook` so it does not collide with the upstream app. Upstream Sparkle auto-updating is intentionally removed; a custom build must not update itself back to the upstream Fst release. The upstream release command is disabled until fork-specific signing and release destinations are configured.

### License

Fst is MIT licensed. The vendored cmark source and upstream licenses are under `Vendor/Down`. SwiftMath 1.7.3 is MIT licensed; its source, upstream revision and bundled font licenses are in `Vendor/SwiftMath`.
