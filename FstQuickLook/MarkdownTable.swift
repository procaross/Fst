import AppKit
import CoreText

extension NSAttributedString.Key {
    static let previewTableRow = NSAttributedString.Key("FstTableRow")
}

/// Immutable decoration metadata. Table contents remain real selectable TextKit 2 text.
final class MarkdownTableRow: NSObject {
    let widths: [CGFloat]
    let header: Bool
    let last: Bool
    init(widths: [CGFloat], header: Bool, last: Bool) {
        self.widths = widths; self.header = header; self.last = last
    }
}

enum MarkdownTable {
    private static let padding: CGFloat = 12
    private static let font = NSFont.systemFont(ofSize: 15)

    /// Wrap each cell on the worker, then use native tab stops for column alignment.
    /// Each row is one layout fragment, so scrolling does not lay out the entire table.
    static func render(rows: [[NSAttributedString]], alignments: [NSTextAlignment], width: CGFloat, indent: CGFloat) -> NSAttributedString {
        guard !rows.isEmpty, !alignments.isEmpty else { return NSAttributedString() }
        let count = alignments.count
        // Limit the intrinsic-width sample so a huge table does not delay first paint.
        var desired = [CGFloat](repeating: 64, count: count)
        for row in rows.prefix(64) {
            for column in 0..<count {
                let text = row[column]
                let sampleRange = (text.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(text.length, 512)))
                let sample = text.attributedSubstring(from: sampleRange)
                let line = CTLineCreateWithAttributedString(measurementText(sample))
                desired[column] = max(desired[column], min(360, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + padding * 2 + 4))
            }
        }
        let total = desired.reduce(0, +)
        // Keep compact labels/numbers intact; let long descriptions absorb most wrapping.
        var minimums = desired.enumerated().map { min($0.element, alignments[$0.offset] == .right ? 128 : 96) }
        let minimumTotal = minimums.reduce(0, +)
        if minimumTotal > width { minimums = minimums.map { $0 * width / minimumTotal } }
        let flexible = desired.enumerated().map { max(0, $0.element - minimums[$0.offset]) }
        let flexTotal = flexible.reduce(0, +)
        let extra = max(0, width - minimums.reduce(0, +))
        let widths = desired.enumerated().map { index, value -> CGFloat in
            if total <= width { return value + (width - total) / CGFloat(count) }
            return minimums[index] + (flexTotal > 0 ? extra * flexible[index] / flexTotal : 0)
        }
        let cellPadding = min(padding, (minimums.min() ?? 48) / 4)
        var x = indent
        let tabs = widths.enumerated().map { column, columnWidth -> NSTextTab in
            defer { x += columnWidth }
            let alignment = alignments[column]
            let location = alignment == .right ? x + columnWidth - cellPadding :
                alignment == .center ? x + columnWidth / 2 : x + cellPadding
            return NSTextTab(textAlignment: alignment, location: location)
        }
        let output = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            let wrapped = (0..<count).map { wrap(row[$0], width: max(1, widths[$0] - cellPadding * 2 - 2)) }
            let lines = wrapped.map(\.count).max() ?? 1
            let start = output.length
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PreviewStyle.foreground]
            for line in 0..<lines {
                for column in 0..<count {
                    output.append(NSAttributedString(string: "\t", attributes: attrs))
                    if line < wrapped[column].count { output.append(wrapped[column][line]) }
                }
                // A line separator preserves a single paragraph/decoration per table row.
                output.append(NSAttributedString(string: line + 1 == lines ? "\n" : "\u{2028}", attributes: attrs))
            }
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.tabStops = tabs
            style.defaultTabInterval = width + 1
            style.lineBreakMode = .byClipping
            style.lineHeightMultiple = 1.2
            let range = NSRange(location: start, length: output.length - start)
            output.addAttributes([.paragraphStyle: style,
                                  .previewTableRow: MarkdownTableRow(widths: widths, header: rowIndex == 0, last: rowIndex == rows.count - 1)], range: range)
        }
        return output
    }

    private static func wrap(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        guard text.length > 0 else { return [NSAttributedString()] }
        let normalized = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let original = value as? NSTextAttachment, original.bounds.width > width else { return }
            let attachment = NSTextAttachment()
            attachment.image = original.image
            let scale = width / original.bounds.width
            attachment.bounds = original.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
            normalized.addAttribute(.attachment, value: attachment, range: range)
        }
        // Tabs/newlines inside a cell must not become another column/row.
        for index in stride(from: normalized.length - 1, through: 0, by: -1) {
            let char = (normalized.string as NSString).character(at: index)
            if char == 9 { normalized.replaceCharacters(in: NSRange(location: index, length: 1), with: " ") }
        }
        let typesetter = CTTypesetterCreateWithAttributedString(measurementText(normalized))
        let string = normalized.string as NSString
        var offset = 0
        var result: [NSAttributedString] = []
        while offset < normalized.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
            if count == 0 { count = string.rangeOfComposedCharacterSequence(at: offset).length }
            var visible = count
            while visible > 0, [10, 13, 0x2028].contains(string.character(at: offset + visible - 1)) { visible -= 1 }
            result.append(normalized.attributedSubstring(from: NSRange(location: offset, length: visible)))
            offset += count
        }
        return result
    }

    /// Core Text needs explicit metrics for AppKit formula attachments when wrapping cells.
    private static func measurementText(_ text: NSAttributedString) -> NSAttributedString {
        let measured = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let metrics = Unmanaged.passRetained(AttachmentMetrics(attachment.bounds))
            var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
                dealloc: { Unmanaged<AttachmentMetrics>.fromOpaque($0).release() },
                getAscent: { Unmanaged<AttachmentMetrics>.fromOpaque($0).takeUnretainedValue().ascent },
                getDescent: { Unmanaged<AttachmentMetrics>.fromOpaque($0).takeUnretainedValue().descent },
                getWidth: { Unmanaged<AttachmentMetrics>.fromOpaque($0).takeUnretainedValue().width })
            if let delegate = CTRunDelegateCreate(&callbacks, metrics.toOpaque()) {
                measured.addAttribute(NSAttributedString.Key(kCTRunDelegateAttributeName as String), value: delegate, range: range)
            } else { metrics.release() }
        }
        return measured
    }

    private final class AttachmentMetrics {
        let width: CGFloat, ascent: CGFloat, descent: CGFloat
        init(_ bounds: CGRect) { width = bounds.width; ascent = bounds.maxY; descent = max(0, -bounds.minY) }
    }
}

final class MarkdownTableFragment: NSTextLayoutFragment {
    var row: MarkdownTableRow!
    override var topMargin: CGFloat { 7 }
    override var bottomMargin: CGFloat { 7 }
    private var tableBounds: CGRect { CGRect(x: 0, y: 0, width: row.widths.reduce(0, +), height: layoutFragmentFrame.height) }
    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(tableBounds.insetBy(dx: -1, dy: -1)) }
    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = tableBounds.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        context.setFillColor((row.header ? PreviewStyle.subtle : PreviewStyle.background).cgColor)
        context.fill(rect)
        context.setStrokeColor(PreviewStyle.border.cgColor)
        context.setLineWidth(0.5)
        // One horizontal stroke per shared edge; keep the outside border complete.
        context.move(to: CGPoint(x: rect.minX, y: rect.minY)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if row.last {
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        var x = rect.minX
        for width in row.widths + [0] {
            context.move(to: CGPoint(x: x, y: rect.minY)); context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += width
        }
        context.strokePath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
