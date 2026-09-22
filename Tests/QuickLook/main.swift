import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let original = #"{"z":123456789012345678901234567890,"a":"中文🐢\\\"$","b":[true,null,{},[]],"z":-1.2300e+45}"#
let pretty = JSONPreview.format(original, truncated: false)
expect(pretty.formatted && !pretty.truncated, "Valid JSON should format")
expect(pretty.text.contains("123456789012345678901234567890"), "Do not round large integers")
expect(pretty.text.contains("-1.2300e+45"), "Do not rewrite numeric spelling")
expect(pretty.text.hasPrefix("{\n  \"z\":"), "Keep key order")
expect(pretty.text.contains("{},\n    []"), "Empty containers remain compact")
expect(JSONPreview.format(pretty.text, truncated: false).text == pretty.text, "Formatting is idempotent")
let invalid = "{\"missing\":}"
expect(JSONPreview.format(invalid, truncated: false).text == invalid, "Invalid input stays unchanged")
let prefix = JSONPreview.format("[{\"a\":1,\"b\":\"partial", truncated: true)
expect(prefix.formatted && prefix.truncated && prefix.text.contains("\n"), "Format a bounded incomplete prefix")
let limited = JSONPreview.format(original, truncated: false, limit: 70)
expect(limited.truncated && !limited.text.contains("�"), "Output limit remains Unicode-safe")

let examples = [
    (#"Inline $x_i^2 + \alpha$ end."#, 1),
    (#"\(\frac{1}{2}\) and \[\sum_{i=1}^n i\]"#, 2),
    ("$$\n\\int_0^1 x^2\\,dx = \\frac{1}{3}\n$$", 1),
    (#"Price $5 and $10; escaped \$x$; `$z$`."#, 0),
    ("```sh\necho '$x$'\n```\n\n$x$", 1),
    ("    $not_math$\n\n$x$", 1),
    (#"`unmatched and $x$"#, 1),
    (#"**bold $a_b$** and $\unknown{1}$"#, 2)
]
for (input, count) in examples {
    let parsed = MarkdownMath(input)
    expect(parsed.formulas.count == count, "Math delimiter recognition: \(input) -> \(parsed.formulas.count)")
    let output = try MarkdownRenderer.render(input).attributedString
    expect(!output.string.contains(MarkdownMath.markerStart), "Internal math marker leaked")
}
let math = try MarkdownRenderer.render(#"Euler $e^{i\pi}+1=0$ and $$\frac{-b\pm\sqrt{b^2-4ac}}{2a}$$"#).attributedString
var attachments = 0
math.enumerateAttribute(.attachment, in: NSRange(location: 0, length: math.length)) { value, _, _ in
    if let attachment = value as? NSTextAttachment {
        attachments += 1
        expect(attachment.image?.size.width ?? 0 > 0, "Formula should have image content")
    }
}
expect(attachments == 2, "Inline and display formulas should be typeset")
let unsupported = try MarkdownRenderer.render(#"$\notacommand{a}$"#).attributedString.string
expect(unsupported.contains(#"\notacommand"#), "Unsupported math stays readable")
let block = try MarkdownRenderer.render("```sh\n# comment\necho hello\n```\n\n`inline`").attributedString
expect(block.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil, "Code blocks must not paint each token background")
expect(block.attribute(.previewCodeBlock, at: 0, effectiveRange: nil) != nil, "Code block has a fragment background")

// Use the same TextKit 2 view and decoration delegate as the extension.
let controller = PreviewViewController()
controller.loadViewIfNeeded()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentViewController = controller
let fixture = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/QuickLook/preview.md")
var done = false
var previewError: Error?
let began = ProcessInfo.processInfo.systemUptime
controller.preparePreviewOfFile(at: fixture) { error in previewError = error; done = true }
while !done && ProcessInfo.processInfo.systemUptime - began < 15 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
expect(done && previewError == nil, "Preview controller should finish")
window.displayIfNeeded()
print(String(format: "Preview initial content: %.2f ms", (ProcessInfo.processInfo.systemUptime - began) * 1_000))
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
func collect(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(collect) }
let visibleText = collect(controller.view).compactMap { $0 as? NSTextView }.first { $0.enclosingScrollView?.isHidden == false }!
expect(visibleText.textLayoutManager != nil, "Preview must stay on TextKit 2")
expect(!visibleText.string.isEmpty, "Preview must display content")
if let output = ProcessInfo.processInfo.environment["FST_PREVIEW_CAPTURE"], let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
}

// Deterministic 2 MiB minified JSON: measure formatting separately from viewport layout.
let row = #"{"id":1234567890123456789,"title":"Unicode 中文🐢","enabled":true,"values":[1,2,3]}"#
let large = "[" + Array(repeating: row, count: 22_000).joined(separator: ",") + "]"
let start = ProcessInfo.processInfo.systemUptime
let formatted = JSONPreview.format(large, truncated: false)
expect(formatted.formatted && !formatted.truncated, "Large JSON is formatted in full within budget")
print(String(format: "JSON %.2f MiB -> %.2f MiB: %.2f ms", Double(large.utf8.count) / 1_048_576, Double(formatted.text.utf8.count) / 1_048_576, (ProcessInfo.processInfo.systemUptime - start) * 1_000))
print("PASS: JSON fidelity/bounds; math delimiters/fallback; code decoration; TextKit 2 preview")

// A reused controller must show the complete document after first paint, without replacing it
// during a live scroll. The same guarantee applies to Markdown and formatted source.
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let markdownFile = directory.appendingPathComponent("large.md")
let markdown = String(repeating: "## Heading\n\nA paragraph with **bold**, `code` and words for scrolling.\n\n", count: 8_000)
try markdown.write(to: markdownFile, atomically: true, encoding: .utf8)
done = false
controller.preparePreviewOfFile(at: markdownFile) { error in previewError = error; done = true }
while !done { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
expect(previewError == nil, "Reused controller accepts Markdown")
let rendered = collect(controller.view).compactMap { $0 as? NSTextView }.first { $0.enclosingScrollView?.isHidden == false }!
let scroll = rendered.enclosingScrollView!
let prefixLength = rendered.string.utf16.count
NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
expect(rendered.string.utf16.count == prefixLength, "Full render must not replace content during live scrolling")
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
let deadline = Date(timeIntervalSinceNow: 10)
while rendered.string.utf16.count == prefixLength && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
expect(rendered.string.utf16.count > prefixLength, "Full Markdown installs when scroll ends")
expect(scroll.contentView.bounds.minY == 0, "Full replacement preserves top position")
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
var samples: [Double] = []
for step in 0..<120 {
    let began = ProcessInfo.processInfo.systemUptime
    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 90)))
    scroll.reflectScrolledClipView(scroll.contentView)
    rendered.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    samples.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
}
NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
samples.sort()
print(String(format: "Native Markdown scroll: p50 %.2f ms; p99 %.2f ms; max %.2f ms", samples[60], samples[118], samples[119]))
let buttons = collect(controller.view).compactMap { $0 as? NSButton }
buttons.first { $0.title == "源码" }!.performClick(nil)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
let sourceView = collect(controller.view).compactMap { $0 as? NSTextView }.first { $0.enclosingScrollView?.isHidden == false }!
expect(sourceView.string.hasPrefix("## Heading"), "Source switch displays original Markdown")
expect(sourceView.textLayoutManager != nil, "Source also stays on TextKit 2")
buttons.first { $0.title == "预览" }!.performClick(nil)
expect(scroll.isHidden == false, "Preview switch restores rendered view")
print("PASS: controller reuse, deferred full render, source switch, scroll traversal")
