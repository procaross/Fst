import AppKit

/// Immutable ownership transfer from a worker to the main thread.
struct PreviewContent: @unchecked Sendable {
    let text: NSAttributedString
    init(_ text: NSAttributedString) { self.text = text.copy() as! NSAttributedString }
}

/// GitHub / Primer Light. Quick Look has its own palette, independent of editor preferences.
enum PreviewStyle {
    static let background = NSColor.white
    static let foreground = color(0x1f2328)
    static let muted = color(0x59636e)
    static let subtle = color(0xf6f8fa)
    static let border = color(0xd1d9e0)
    static let link = color(0x0969da)
    static let inlineCode = color(0x818b98).withAlphaComponent(0.12)
    static let theme = EditorTheme(background: background, foreground: foreground,
                                   comment: muted, string: color(0x0a3069),
                                   keyword: color(0xcf222e), number: color(0x0550ae))

    static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// Only called on a worker; the finished string is installed in one text-storage edit.
    static func highlight(_ output: NSMutableAttributedString, range: NSRange, language: String) {
        let mode = Language.detect(language)
        guard !mode.plain, range.length > 0 else { return }
        let source = (output.string as NSString).substring(with: range) as NSString
        var offset = 0
        var state = SyntaxLexer.State.normal
        while offset < source.length {
            let batch = SyntaxLexer.scan(source, from: offset, state: state, language: mode)
            guard batch.end > offset else { break }
            for token in batch.tokens {
                let color: NSColor
                switch token.kind {
                case .comment: color = theme.comment
                case .string: color = theme.string
                case .keyword: color = theme.keyword
                case .number: color = theme.number
                }
                output.addAttribute(.foregroundColor, value: color,
                                    range: NSRange(location: range.location + token.range.location, length: token.range.length))
            }
            offset = batch.end
            state = batch.state
        }
    }

    static func source(_ text: String, filename: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.defaultTabInterval = 32
        paragraph.tabStops = []
        let output = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: foreground, .paragraphStyle: paragraph
        ])
        highlight(output, range: NSRange(location: 0, length: output.length), language: filename)
        return output
    }
}
