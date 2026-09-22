import AppKit
import libcmark

struct MarkdownCodeBlock {
    let range: NSRange
    let language: String?
}

// The worker finishes all mutation before publishing this immutable result.
struct MarkdownRenderResult: @unchecked Sendable {
    let attributedString: NSAttributedString
    let codeBlocks: [MarkdownCodeBlock]
    let hasTables: Bool
}

enum MarkdownRenderer {
    enum RenderError: Error { case parseFailed }

    // Swift initializes this once, including when preview workers parse concurrently.
    private static let registerExtensions: Void = cmark_gfm_core_extensions_ensure_registered()

    static func render(_ markdown: String, width: CGFloat = 786) throws -> MarkdownRenderResult {
        _ = registerExtensions
        let math = MarkdownMath(markdown)
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw RenderError.parseFailed }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        math.text.withCString { buffer in
            cmark_parser_feed(parser, buffer, strlen(buffer))
        }
        guard let root = cmark_parser_finish(parser) else { throw RenderError.parseFailed }
        defer { cmark_node_free(root) }

        let builder = Builder(formulas: math.formulas, width: width)
        builder.renderChildren(of: root, quoteDepth: 0)
        builder.trimTrailingWhitespace()
        return MarkdownRenderResult(attributedString: builder.output.copy() as! NSAttributedString,
                                    codeBlocks: builder.codeBlocks, hasTables: builder.hasTables)
    }

    private final class Builder {
        let output = NSMutableAttributedString()
        var codeBlocks: [MarkdownCodeBlock] = []
        var hasTables = false
        let formulas: [MarkdownMath.Formula]
        let width: CGFloat
        var listIndent: CGFloat = 0

        init(formulas: [MarkdownMath.Formula], width: CGFloat) { self.formulas = formulas; self.width = width }

        private let bodyFont = NSFont.systemFont(ofSize: 15)
        private let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

        func renderChildren(of parent: OpaquePointer, quoteDepth: Int) {
            var node = cmark_node_first_child(parent)
            while let current = node {
                renderBlock(current, quoteDepth: quoteDepth)
                node = cmark_node_next(current)
            }
        }

        func trimTrailingWhitespace() {
            while output.length > 0 {
                let last = (output.string as NSString).character(at: output.length - 1)
                guard last == 10 || last == 13 else { break }
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        private func renderBlock(_ node: OpaquePointer, quoteDepth: Int) {
            if cString(cmark_node_get_type_string(node)) == "table" {
                renderTable(node, quoteDepth: quoteDepth)
                return
            }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_DOCUMENT:
                renderChildren(of: node, quoteDepth: quoteDepth)

            case CMARK_NODE_HEADING:
                ensureBlockBoundary()
                let start = output.length
                let level = max(1, min(6, Int(cmark_node_get_heading_level(node))))
                let sizes: [CGFloat] = [30, 24, 20, 17, 15.5, 15]
                let font = NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold)
                renderInlineChildren(of: node, attributes: baseAttributes(font: font))
                append("\n", attributes: baseAttributes(font: font))
                applyParagraphStyle(from: start, quoteDepth: quoteDepth,
                                    before: level <= 2 ? 13 : 9,
                                    after: level <= 2 ? 8 : 5,
                                    lineHeightMultiple: 1.05)

            case CMARK_NODE_PARAGRAPH:
                ensureBlockBoundary()
                let start = output.length
                renderInlineChildren(of: node, attributes: baseAttributes(quoteDepth: quoteDepth))
                if !(output.string as NSString).hasSuffix("\n") { append("\n", attributes: baseAttributes(quoteDepth: quoteDepth)) }
                let range = NSRange(location: start, length: output.length - start)
                let existing = output.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
                if existing?.alignment != .center {
                    applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 0, after: 8)
                } else {
                    output.addAttribute(.paragraphStyle, value: existing!, range: range)
                }

            case CMARK_NODE_BLOCK_QUOTE:
                ensureBlockBoundary()
                // Apply muted color to quote prose when creating it, not to the whole
                // subtree: headings, links and syntax-colored code keep their own colors.
                renderChildren(of: node, quoteDepth: quoteDepth + 1)

            case CMARK_NODE_LIST:
                renderList(node, quoteDepth: quoteDepth)

            case CMARK_NODE_CODE_BLOCK:
                ensureBlockBoundary()
                let start = output.length
                let literal = cString(cmark_node_get_literal(node))
                let code = literal.hasSuffix("\n") ? String(literal.dropLast()) : literal
                let info = cString(cmark_node_get_fence_info(node)).trimmingCharacters(in: .whitespacesAndNewlines)
                let language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                if ["math", "latex"].contains(language?.lowercased() ?? ""),
                   appendFormula(latex: code, original: code, display: true) { break }
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeFont, .foregroundColor: PreviewStyle.foreground
                ]
                append(code.isEmpty ? " " : code, attributes: codeAttrs)
                let codeRange = NSRange(location: start, length: output.length - start)
                append("\n", attributes: codeAttrs)
                applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 0, after: 0,
                                    lineHeightMultiple: 1.25, extraIndent: 16)
                let blockEnd = output.length
                let text = output.string as NSString
                var line = start
                while line < blockEnd {
                    let range = text.paragraphRange(for: NSRange(location: line, length: 0))
                    let edges = (line == start ? 1 : 0) | (NSMaxRange(range) >= blockEnd ? 2 : 0)
                    output.addAttribute(.previewCodeBlock, value: edges, range: range)
                    line = NSMaxRange(range)
                }
                codeBlocks.append(MarkdownCodeBlock(range: codeRange, language: language))
                if let language { PreviewStyle.highlight(output, range: codeRange, language: "snippet.\(language)") }
                append("\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])

            case CMARK_NODE_THEMATIC_BREAK:
                ensureBlockBoundary()
                let start = output.length
                append("────────────────────────────\n",
                       attributes: [.font: bodyFont, .foregroundColor: PreviewStyle.border])
                applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 8, after: 8)

            case CMARK_NODE_HTML_BLOCK:
                // Raw HTML is intentionally ignored in the native Quick Look path.
                break

            default:
                renderInline(node, attributes: baseAttributes(quoteDepth: quoteDepth))
            }
        }

        private func renderList(_ list: OpaquePointer, quoteDepth: Int) {
            ensureBlockBoundary()
            let ordered = cmark_node_get_list_type(list) == CMARK_ORDERED_LIST
            var number = max(1, Int(cmark_node_get_list_start(list)))
            var item = cmark_node_first_child(list)
            while let current = item {
                guard cmark_node_get_type(current) == CMARK_NODE_ITEM else {
                    item = cmark_node_next(current)
                    continue
                }
                var start = output.length
                let task = cString(cmark_node_get_type_string(current)) == "tasklist"
                let marker = task ? (cmark_gfm_extensions_get_tasklist_item_checked(current) ? "☑\t" : "☐\t") : (ordered ? "\(number).\t" : "•\t")
                append(marker, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                             .foregroundColor: quoteDepth > 0 ? PreviewStyle.muted : PreviewStyle.foreground])

                var child = cmark_node_first_child(current)
                var renderedPrimary = false
                let indent = CGFloat(quoteDepth * 18) + listIndent
                let markerWidth = max(24, (String(marker.dropLast()) as NSString).size(withAttributes: [.font: bodyFont]).width + 4)
                func finishParagraph() {
                    guard output.length > start else { return }
                    if !(output.string as NSString).hasSuffix("\n") { append("\n", attributes: baseAttributes()) }
                    let style = paragraphStyle(quoteDepth: quoteDepth, before: 0, after: 4)
                    style.firstLineHeadIndent = renderedPrimary ? indent + markerWidth : indent
                    style.headIndent = indent + markerWidth
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
                    output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
                    start = output.length
                    renderedPrimary = true
                }
                while let currentChild = child {
                    if cmark_node_get_type(currentChild) == CMARK_NODE_PARAGRAPH {
                        renderInlineChildren(of: currentChild, attributes: baseAttributes(quoteDepth: quoteDepth))
                        finishParagraph()
                    } else {
                        finishParagraph()
                        listIndent += markerWidth
                        renderBlock(currentChild, quoteDepth: quoteDepth)
                        listIndent -= markerWidth
                        start = output.length
                    }
                    child = cmark_node_next(currentChild)
                }

                finishParagraph()
                number += 1
                item = cmark_node_next(current)
            }
        }

        private func renderTable(_ node: OpaquePointer, quoteDepth: Int) {
            ensureBlockBoundary()
            let columns = Int(cmark_gfm_extensions_get_table_columns(node))
            guard columns > 0 else { return }
            hasTables = true
            let rawAlignments = cmark_gfm_extensions_get_table_alignments(node)
            let alignments: [NSTextAlignment] = (0..<columns).map {
                switch rawAlignments?[$0] { case 99: return .center; case 114: return .right; default: return .left }
            }
            var rows: [[NSAttributedString]] = []
            var row = cmark_node_first_child(node)
            while let current = row {
                var cells: [NSAttributedString] = []
                var cell = cmark_node_first_child(current)
                while let currentCell = cell {
                    let builder = Builder(formulas: formulas, width: width)
                    let font = NSFont.systemFont(ofSize: 15, weight: rows.isEmpty ? .semibold : .regular)
                    builder.renderInlineChildren(of: currentCell, attributes: baseAttributes(font: font))
                    cells.append(builder.output.copy() as! NSAttributedString)
                    cell = cmark_node_next(currentCell)
                }
                while cells.count < columns { cells.append(NSAttributedString(string: "")) }
                rows.append(Array(cells.prefix(columns)))
                row = cmark_node_next(current)
            }
            let indent = CGFloat(quoteDepth * 18) + listIndent
            output.append(MarkdownTable.render(rows: rows, alignments: alignments, width: max(100, width - indent), indent: indent))
            append("\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])
        }

        private func renderInlineChildren(of parent: OpaquePointer,
                                          attributes: [NSAttributedString.Key: Any]) {
            var node = cmark_node_first_child(parent)
            while let current = node {
                renderInline(current, attributes: attributes)
                node = cmark_node_next(current)
            }
        }

        private func renderInline(_ node: OpaquePointer,
                                  attributes: [NSAttributedString.Key: Any]) {
            if cString(cmark_node_get_type_string(node)) == "strikethrough" {
                var attrs = attributes
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                renderInlineChildren(of: node, attributes: attrs)
                return
            }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT:
                appendMathText(cString(cmark_node_get_literal(node)), attributes: attributes)

            case CMARK_NODE_SOFTBREAK:
                append(" ", attributes: attributes)

            case CMARK_NODE_LINEBREAK:
                append("\n", attributes: attributes)

            case CMARK_NODE_CODE:
                var attrs = attributes
                attrs[.font] = codeFont
                attrs[.foregroundColor] = PreviewStyle.foreground
                attrs[.backgroundColor] = PreviewStyle.inlineCode
                append(cString(cmark_node_get_literal(node)), attributes: attrs)

            case CMARK_NODE_EMPH:
                var attrs = attributes
                attrs[.font] = font(from: attributes, adding: .italic)
                renderInlineChildren(of: node, attributes: attrs)

            case CMARK_NODE_STRONG:
                var attrs = attributes
                attrs[.font] = font(from: attributes, adding: .bold)
                renderInlineChildren(of: node, attributes: attrs)

            case CMARK_NODE_LINK:
                var attrs = attributes
                let urlText = cString(cmark_node_get_url(node))
                if let url = URL(string: urlText) { attrs[.link] = url }
                attrs[.foregroundColor] = PreviewStyle.link
                renderInlineChildren(of: node, attributes: attrs)

            case CMARK_NODE_IMAGE:
                var attrs = attributes
                let target = cString(cmark_node_get_url(node))
                if let url = URL(string: target) { attrs[.link] = url }
                attrs[.foregroundColor] = PreviewStyle.muted
                append("[image: \(plainText(of: node).isEmpty ? target : plainText(of: node))]", attributes: attrs)

            case CMARK_NODE_HTML_INLINE:
                let html = cString(cmark_node_get_literal(node)).lowercased()
                if html.hasPrefix("<br") { append("\n", attributes: attributes) }

            default:
                renderInlineChildren(of: node, attributes: attributes)
            }
        }

        private func appendMathText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            guard !formulas.isEmpty, text.contains(MarkdownMath.markerStart) else {
                append(text, attributes: attributes); return
            }
            var remainder = text[...]
            while let start = remainder.range(of: MarkdownMath.markerStart),
                  let end = remainder[start.upperBound...].range(of: MarkdownMath.markerEnd),
                  let index = Int(remainder[start.upperBound..<end.lowerBound]), formulas.indices.contains(index) {
                append(String(remainder[..<start.lowerBound]), attributes: attributes)
                let formula = formulas[index]
                if !appendFormula(latex: formula.latex, original: formula.original, display: formula.display) {
                    append(formula.original, attributes: attributes)
                }
                remainder = remainder[end.upperBound...]
            }
            append(String(remainder), attributes: attributes)
        }

        @discardableResult
        private func appendFormula(latex: String, original: String, display: Bool) -> Bool {
            guard let math = MathRenderer.attachment(latex: latex, display: display) else { return false }
            if display { ensureBlockBoundary() }
            let start = output.length
            output.append(math)
            if display {
                append("\n", attributes: baseAttributes())
                let style = paragraphStyle(quoteDepth: 0, before: 12, after: 12)
                style.alignment = .center
                output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
            }
            return true
        }

        private func plainText(of parent: OpaquePointer) -> String {
            var result = ""
            var node = cmark_node_first_child(parent)
            while let current = node {
                if cmark_node_get_type(current) == CMARK_NODE_TEXT || cmark_node_get_type(current) == CMARK_NODE_CODE {
                    result += cString(cmark_node_get_literal(current))
                } else {
                    result += plainText(of: current)
                }
                node = cmark_node_next(current)
            }
            return result
        }

        private func baseAttributes(font: NSFont? = nil, quoteDepth: Int = 0) -> [NSAttributedString.Key: Any] {
            [.font: font ?? bodyFont, .foregroundColor: quoteDepth > 0 ? PreviewStyle.muted : PreviewStyle.foreground]
        }

        private func font(from attributes: [NSAttributedString.Key: Any],
                          adding trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
            let base = attributes[.font] as? NSFont ?? bodyFont
            let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(trait))
            return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        }

        private func ensureBlockBoundary() {
            guard output.length > 0 else { return }
            if !(output.string as NSString).hasSuffix("\n") {
                append("\n", attributes: baseAttributes())
            }
        }

        private func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            guard !text.isEmpty else { return }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        private func applyParagraphStyle(from start: Int, quoteDepth: Int,
                                         before: CGFloat, after: CGFloat,
                                         lineHeightMultiple: CGFloat = 1.12,
                                         extraIndent: CGFloat = 0) {
            guard output.length > start else { return }
            let style = paragraphStyle(quoteDepth: quoteDepth, before: before, after: after,
                                       lineHeightMultiple: lineHeightMultiple,
                                       extraIndent: extraIndent)
            output.addAttribute(.paragraphStyle, value: style,
                                range: NSRange(location: start, length: output.length - start))
        }

        private func paragraphStyle(quoteDepth: Int, before: CGFloat, after: CGFloat,
                                    lineHeightMultiple: CGFloat = 1.12,
                                    extraIndent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = lineHeightMultiple
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            let indent = CGFloat(quoteDepth * 18) + extraIndent + listIndent
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            if quoteDepth > 0 { style.tailIndent = -8 }
            return style
        }

        private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
            pointer.map { String(cString: $0) } ?? ""
        }
    }
}
