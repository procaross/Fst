import AppKit
import libcmark

struct MarkdownCodeBlock {
    let range: NSRange
    let language: String?
}

struct MarkdownRenderResult {
    let attributedString: NSAttributedString
    let codeBlocks: [MarkdownCodeBlock]
}

enum MarkdownRenderer {
    enum RenderError: Error { case parseFailed }

    static func render(_ markdown: String) throws -> MarkdownRenderResult {
        var root: UnsafeMutablePointer<cmark_node>?
        markdown.withCString { buffer in
            root = cmark_parse_document(buffer, strlen(buffer), CMARK_OPT_SAFE)
        }
        guard let root else { throw RenderError.parseFailed }
        defer { cmark_node_free(root) }

        let builder = Builder()
        builder.renderChildren(of: root, quoteDepth: 0)
        builder.trimTrailingWhitespace()
        return MarkdownRenderResult(attributedString: builder.output.copy() as! NSAttributedString,
                                    codeBlocks: builder.codeBlocks)
    }

    private final class Builder {
        let output = NSMutableAttributedString()
        var codeBlocks: [MarkdownCodeBlock] = []

        private let bodyFont = NSFont.systemFont(ofSize: 15)
        private let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

        func renderChildren(of parent: UnsafeMutablePointer<cmark_node>, quoteDepth: Int) {
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

        private func renderBlock(_ node: UnsafeMutablePointer<cmark_node>, quoteDepth: Int) {
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
                renderInlineChildren(of: node, attributes: baseAttributes())
                append("\n", attributes: baseAttributes())
                applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 0, after: 8)

            case CMARK_NODE_BLOCK_QUOTE:
                ensureBlockBoundary()
                let start = output.length
                renderChildren(of: node, quoteDepth: quoteDepth + 1)
                if output.length > start {
                    output.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                        range: NSRange(location: start, length: output.length - start))
                }

            case CMARK_NODE_LIST:
                renderList(node, quoteDepth: quoteDepth)

            case CMARK_NODE_CODE_BLOCK:
                ensureBlockBoundary()
                let start = output.length
                let literal = cString(cmark_node_get_literal(node))
                let code = literal.hasSuffix("\n") ? String(literal.dropLast()) : literal
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.17)
                ]
                append(code, attributes: codeAttrs)
                let codeRange = NSRange(location: start, length: output.length - start)
                append("\n", attributes: codeAttrs)
                applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 4, after: 9,
                                    lineHeightMultiple: 1.08, extraIndent: 12)
                let info = cString(cmark_node_get_fence_info(node)).trimmingCharacters(in: .whitespacesAndNewlines)
                codeBlocks.append(MarkdownCodeBlock(range: codeRange,
                                                    language: info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)))

            case CMARK_NODE_THEMATIC_BREAK:
                ensureBlockBoundary()
                let start = output.length
                append("────────────────────────────\n",
                       attributes: [.font: bodyFont, .foregroundColor: NSColor.separatorColor])
                applyParagraphStyle(from: start, quoteDepth: quoteDepth, before: 8, after: 8)

            case CMARK_NODE_HTML_BLOCK:
                // Raw HTML is intentionally ignored in the native Quick Look path.
                break

            default:
                renderInline(node, attributes: baseAttributes())
            }
        }

        private func renderList(_ list: UnsafeMutablePointer<cmark_node>, quoteDepth: Int) {
            ensureBlockBoundary()
            let ordered = cmark_node_get_list_type(list) == CMARK_ORDERED_LIST
            var number = max(1, Int(cmark_node_get_list_start(list)))
            var item = cmark_node_first_child(list)
            while let current = item {
                guard cmark_node_get_type(current) == CMARK_NODE_ITEM else {
                    item = cmark_node_next(current)
                    continue
                }
                let start = output.length
                let marker = ordered ? "\(number).\t" : "•\t"
                append(marker, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                             .foregroundColor: NSColor.labelColor])

                var child = cmark_node_first_child(current)
                var renderedPrimary = false
                while let currentChild = child {
                    if cmark_node_get_type(currentChild) == CMARK_NODE_PARAGRAPH {
                        if renderedPrimary { append("\n", attributes: baseAttributes()) }
                        renderInlineChildren(of: currentChild, attributes: baseAttributes())
                        renderedPrimary = true
                    } else if cmark_node_get_type(currentChild) == CMARK_NODE_LIST {
                        append("\n", attributes: baseAttributes())
                        renderList(currentChild, quoteDepth: quoteDepth)
                    } else {
                        renderBlock(currentChild, quoteDepth: quoteDepth)
                    }
                    child = cmark_node_next(currentChild)
                }

                if output.length == 0 || !(output.string as NSString).hasSuffix("\n") {
                    append("\n", attributes: baseAttributes())
                }
                let style = paragraphStyle(quoteDepth: quoteDepth, before: 0, after: 4)
                let indent = CGFloat(quoteDepth * 18)
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 24
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                output.addAttribute(.paragraphStyle, value: style,
                                    range: NSRange(location: start, length: output.length - start))
                number += 1
                item = cmark_node_next(current)
            }
        }

        private func renderInlineChildren(of parent: UnsafeMutablePointer<cmark_node>,
                                          attributes: [NSAttributedString.Key: Any]) {
            var node = cmark_node_first_child(parent)
            while let current = node {
                renderInline(current, attributes: attributes)
                node = cmark_node_next(current)
            }
        }

        private func renderInline(_ node: UnsafeMutablePointer<cmark_node>,
                                  attributes: [NSAttributedString.Key: Any]) {
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT:
                append(cString(cmark_node_get_literal(node)), attributes: attributes)

            case CMARK_NODE_SOFTBREAK:
                append("\n", attributes: attributes)

            case CMARK_NODE_LINEBREAK:
                append("\n", attributes: attributes)

            case CMARK_NODE_CODE:
                var attrs = attributes
                attrs[.font] = codeFont
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
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
                attrs[.foregroundColor] = NSColor.linkColor
                renderInlineChildren(of: node, attributes: attrs)

            case CMARK_NODE_IMAGE:
                var attrs = attributes
                let target = cString(cmark_node_get_url(node))
                if let url = URL(string: target) { attrs[.link] = url }
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                append("[image: \(plainText(of: node).isEmpty ? target : plainText(of: node))]", attributes: attrs)

            case CMARK_NODE_HTML_INLINE:
                let html = cString(cmark_node_get_literal(node)).lowercased()
                if html.hasPrefix("<br") { append("\n", attributes: attributes) }

            default:
                renderInlineChildren(of: node, attributes: attributes)
            }
        }

        private func plainText(of parent: UnsafeMutablePointer<cmark_node>) -> String {
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

        private func baseAttributes(font: NSFont? = nil) -> [NSAttributedString.Key: Any] {
            [.font: font ?? bodyFont, .foregroundColor: NSColor.labelColor]
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
            let indent = CGFloat(quoteDepth * 18) + extraIndent
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
