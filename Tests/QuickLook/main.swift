import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
setbuf(stdout, nil)
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

// Bare URLs must not absorb adjacent Chinese prose. Exercise rendered attributes as well
// as destinations: clipping only the blue style would leave a wrong clickable URL.
func renderedLinks(_ text: NSAttributedString) -> [(label: String, destination: String)] {
    var links: [(String, String)] = []
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        if let url = value as? URL {
            links.append(((text.string as NSString).substring(with: range), url.absoluteString))
        }
    }
    return links
}
let queryURL = "https://example.com/base/demo?table=one&view=two&record=three"
let linkSentence = "记录 (\(queryURL))，后续中文正文；请继续阅读。"
let linkedSentence = try MarkdownRenderer.render(linkSentence).attributedString
let sentenceLinks = renderedLinks(linkedSentence)
expect(sentenceLinks.count == 1 && sentenceLinks[0].label == queryURL && sentenceLinks[0].destination == queryURL,
       "Bare URL must stop before its enclosing parenthesis and Chinese prose")
expect(linkedSentence.string == linkSentence, "Link boundaries must not drop or duplicate prose")
let proseRange = (linkedSentence.string as NSString).range(of: "后续中文正文")
expect(linkedSentence.attribute(.link, at: proseRange.location, effectiveRange: nil) == nil,
       "Following prose must not be clickable")
expect((linkedSentence.attribute(.foregroundColor, at: proseRange.location, effectiveRange: nil) as? NSColor) == PreviewStyle.foreground,
       "Following prose must retain its normal text color")
for ending in [")", "),", "，", "。", "；", "：", "！", "？", "、", "）", "】", "》", "」", "』", "“", "”", "‘", "’", "\u{3000}", "\u{00a0}"] {
    for (label, destination) in [(queryURL, queryURL), ("www.example.com/path", "http://www.example.com/path")] {
        let input = label + ending + "后续正文"
        let output = try MarkdownRenderer.render(input).attributedString
        let links = renderedLinks(output)
        expect(links.count == 1 && links[0].label == label && links[0].destination == destination,
               "Bare URL boundary: \(ending)")
        expect(output.string == input, "Boundary punctuation and prose must remain visible")
    }
}
for url in ["https://example.com/wiki/Function_(mathematics)", "https://example.com/a_((b))?q=(c)",
            "https://example.com/中文/说明?q=你好&mode=完整#章节", "https://例子.测试/路径",
            "https://example.com/a%EF%BC%8Cb", "https://example.com/?a=1,2&b=3;4"] {
    let links = renderedLinks(try MarkdownRenderer.render("(\(url))，后续正文").attributedString)
    expect(links.count == 1 && links[0].label == url && links[0].destination == URL(string: url)!.absoluteString,
           "Preserve valid URL content: \(url)")
}
let explicitURL = "https://example.com/中文，路径?q=值；更多"
for input in ["[手动链接](\(explicitURL))，正文", "<\(explicitURL)>，正文",
              "[手动链接][ref]\n\n[ref]: \(explicitURL)"] {
    let links = renderedLinks(try MarkdownRenderer.render(input).attributedString)
    expect(links.count == 1 && links[0].destination == URL(string: explicitURL)!.absoluteString,
           "Explicit destinations may intentionally contain punctuation")
}
let codeLinks = try MarkdownRenderer.render("`\(queryURL)`\n\n```text\n\(queryURL)\n```").attributedString
expect(renderedLinks(codeLinks).isEmpty, "Code never becomes an automatic link")
let adjacentLinks = renderedLinks(try MarkdownRenderer.render("\(queryURL)，另见 https://example.org/b。正文").attributedString)
expect(adjacentLinks.count == 2 && adjacentLinks[1].destination == "https://example.org/b", "Adjacent links stay separate")
let gfmQuery = "www.example.com/search?q=(business))+ok"
let gfmQueryLinks = renderedLinks(try MarkdownRenderer.render(gfmQuery).attributedString)
expect(gfmQueryLinks.count == 1 && gfmQueryLinks[0].destination == "http://" + gfmQuery,
       "Preserve GFM queries with internal unmatched parentheses")
let emailLinks = renderedLinks(try MarkdownRenderer.render("help@example.com，联系邮箱").attributedString)
expect(emailLinks.count == 1 && emailLinks[0].destination == "mailto:help@example.com", "Email detection remains supported")
let tableLinks = renderedLinks(try MarkdownRenderer.render("| 参考 |\n| --- |\n| \(queryURL)，后续正文 |", width: 2000).attributedString)
expect(tableLinks.count == 1 && tableLinks[0].destination == queryURL, "Table autolinks use the same boundaries")
print("PASS: autolink boundaries, Unicode paths, queries, balanced parentheses, explicit links and code exclusions")

let tableMarkdown = #"""
| Name | Center | Value |
| :--- | :---: | ---: |
| **中文** and `a\|b` | [link](https://example.com) | 42 |
| A longer description that wraps without losing any words | | 123.45 |
| $x^2$ | ~~old~~ | |
"""#
let table = try MarkdownRenderer.render(tableMarkdown, width: 600)
expect(table.hasTables, "GFM table should be recognized")
expect(table.attributedString.string.contains("a|b"), "Escaped pipe inside code stays in one cell")
expect(!table.attributedString.string.contains(":---"), "Delimiter row must not appear as text")
var tableRows: [MarkdownTableRow] = []
table.attributedString.enumerateAttribute(.previewTableRow, in: NSRange(location: 0, length: table.attributedString.length)) { value, _, _ in
    if let row = value as? MarkdownTableRow { tableRows.append(row) }
}
expect(tableRows.count == 4 && tableRows[0].header && tableRows[3].last, "Header and all body rows render, including empty cells")
expect(abs(tableRows[0].widths.reduce(0, +) - 600) < 0.1, "Columns occupy available width")
let tableStyle = table.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
expect(tableStyle.tabStops.map(\.alignment) == [.left, .center, .right], "GFM column alignments survive")
let linkRange = (table.attributedString.string as NSString).range(of: "link")
expect(table.attributedString.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil, "Table links stay interactive")
let narrowTable = try MarkdownRenderer.render(tableMarkdown, width: 300).attributedString
expect(narrowTable.string.filter { $0 == "\u{2028}" }.count > table.attributedString.string.filter { $0 == "\u{2028}" }.count,
       "Narrow tables wrap cells instead of overflowing")
let fencedTable = try MarkdownRenderer.render("```\n" + tableMarkdown + "\n```")
expect(!fencedTable.hasTables, "Code fences never turn into tables")
let list = try MarkdownRenderer.render("- Parent\n  - Nested\n    1. Third\n- Sibling\n\n- [x] Done\n- [ ] Pending").attributedString
func listIndent(_ word: String) -> CGFloat {
    let range = (list.string as NSString).range(of: word)
    return (list.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as! NSParagraphStyle).headIndent
}
expect(listIndent("Parent") == listIndent("Sibling") && listIndent("Nested") > listIndent("Parent") && listIndent("Third") > listIndent("Nested"),
       "Parent list styling must not flatten nested lists")
expect(list.string.contains("☑") && list.string.contains("☐"), "GFM task lists display checkboxes")
print("PASS: GFM tables, alignment, wrapping, inline styles, nested/task lists")

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

// Reflow the installed controller at a narrow width and exercise a long table.
let tableFile = directory.appendingPathComponent("table.md")
let tableFixture = try String(contentsOfFile: "Tests/QuickLook/tables.md", encoding: .utf8)
try tableFixture.write(to: tableFile, atomically: true, encoding: .utf8)
done = false
controller.preparePreviewOfFile(at: tableFile) { error in previewError = error; done = true }
while !done { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
expect(previewError == nil, "Controller accepts a table document")
let beforeResize = rendered.string
// NSWindow follows a content controller's preferred size in this harness.
controller.preferredContentSize = NSSize(width: 460, height: 740)
window.setContentSize(NSSize(width: 460, height: 740))
controller.view.layoutSubtreeIfNeeded()
window.displayIfNeeded()
let resizeDeadline = Date(timeIntervalSinceNow: 5)
while rendered.string == beforeResize && Date() < resizeDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
expect(rendered.string != beforeResize, "Window resize must reflow table cells")
expect(rendered.string.contains("12.5 MB") && rendered.string.contains("25.0%"), "Compact numeric columns should stay intact at narrow widths")
expect(rendered.textLayoutManager != nil, "Table reflow must retain TextKit 2")
window.displayIfNeeded()
if let output = ProcessInfo.processInfo.environment["FST_TABLE_CAPTURE"], let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
}
let longTable = "| Name | Value | Description |\n| :--- | ---: | :--- |\n" + (0..<2_000).map { "| Row \($0) | \($0) | 中文说明 and a description that wraps at narrow widths |\n" }.joined()
let tableStart = ProcessInfo.processInfo.systemUptime
let longRendered = try MarkdownRenderer.render(longTable, width: 386)
print(String(format: "2,000 table rows render: %.2f ms", (ProcessInfo.processInfo.systemUptime - tableStart) * 1_000))
NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
rendered.textStorage?.setAttributedString(longRendered.attributedString)
rendered.textLayoutManager?.textViewportLayoutController.layoutViewport()
window.displayIfNeeded()
samples.removeAll()
for step in 0..<120 {
    let began = ProcessInfo.processInfo.systemUptime
    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 70)))
    scroll.reflectScrolledClipView(scroll.contentView)
    rendered.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    samples.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
}
samples.sort()
print(String(format: "Native table scroll: p50 %.2f ms; p99 %.2f ms; max %.2f ms", samples[60], samples[118], samples[119]))
expect(rendered.string.contains("1999"), "Large tables keep the last row")
print("PASS: table resize, large-table viewport layout and scroll traversal")
