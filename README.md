# Fst

A fast, minimal native macOS text editor plus developer-focused Quick Look previews. This fork adds a QLMarkdown-style rendered Markdown view while keeping Fst's highlighted source preview. macOS 14+.

In Finder, press Space on source files to get Fst's selectable syntax-highlighted preview. Markdown files open as rendered documents and include a **Rendered / Source** switch, so a README can be read normally or inspected as Markdown without leaving Quick Look.

The Markdown renderer is bundled locally with the app and uses cmark plus native AppKit text layout. It works offline and does not start WebKit or execute JavaScript.

### Development

Build and launch: `just run`. Test: `just test`. [Development](Development.md).

The fork uses bundle identifiers `com.procaross.Fst` and `com.procaross.Fst.QuickLook` so it does not collide with the upstream app. Upstream Sparkle auto-updating is intentionally removed; a custom build must not update itself back to the upstream Fst release. The upstream release command is disabled until fork-specific signing and release destinations are configured.

### License

Fst is MIT licensed. The vendored cmark source and upstream licenses are under `Vendor/Down`.
