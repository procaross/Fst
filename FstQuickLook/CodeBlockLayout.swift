import AppKit

extension NSAttributedString.Key {
    static let previewCodeBlock = NSAttributedString.Key("FstCodeBlockEdges")
}

/// Decorations belong to layout fragments, so offscreen code never needs a view or a drawing pass.
final class CodeBlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let row = paragraph.attributedString.attribute(.previewTableRow, at: 0, effectiveRange: nil) as? MarkdownTableRow {
            let fragment = MarkdownTableFragment(textElement: textElement, range: textElement.elementRange)
            fragment.row = row
            return fragment
        }
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let edges = paragraph.attributedString.attribute(.previewCodeBlock, at: 0, effectiveRange: nil) as? Int {
            let fragment = CodeBlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
            fragment.edges = edges
            return fragment
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

private final class CodeBlockLayoutFragment: NSTextLayoutFragment {
    var edges = 0
    override var topMargin: CGFloat { edges & 1 != 0 ? 12 : 0 }
    override var bottomMargin: CGFloat { edges & 2 != 0 ? 12 : 0 }

    private var blockWidth: CGFloat { max(0, (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width) - layoutFragmentFrame.minX + 16 - 5) }
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: -16, y: 0, width: blockWidth, height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = CGRect(x: point.x - 16, y: point.y, width: blockWidth, height: layoutFragmentFrame.height)
        context.saveGState()
        context.setFillColor(PreviewStyle.subtle.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        // Adjacent paragraph fragments meet without gaps; only the outside corners are rounded.
        if edges & 1 == 0 { context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(6, rect.height))) }
        if edges & 2 == 0 { context.fill(CGRect(x: rect.minX, y: rect.maxY - min(6, rect.height), width: rect.width, height: min(6, rect.height))) }
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
