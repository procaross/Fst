import AppKit
import SwiftMath

/// Extract before CommonMark consumes LaTeX backslashes, underscores and asterisks.
struct MarkdownMath {
    struct Formula {
        let latex: String
        let original: String
        let display: Bool
    }
    let text: String
    let formulas: [Formula]
    static let markerStart = "\u{e000}FSTMATH"
    static let markerEnd = "\u{e001}"

    init(_ markdown: String) {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else {
            text = markdown; formulas = []; return
        }
        let input = markdown as NSString
        var result = ""
        var found: [Formula] = []
        var index = 0
        var copied = 0
        var lineStart = true
        var fence: (character: unichar, count: Int)?
        func char(_ i: Int) -> unichar { i < input.length ? input.character(at: i) : 0 }
        func run(_ i: Int, _ c: unichar) -> Int {
            var end = i
            while end < input.length && char(end) == c { end += 1 }
            return end - i
        }
        func whitespace(_ c: unichar) -> Bool { c == 0 || c == 32 || c == 9 || c == 10 || c == 13 }
        while index < input.length {
            if lineStart {
                let line = input.lineRange(for: NSRange(location: index, length: 0))
                var content = index
                while content < NSMaxRange(line) && (char(content) == 32 || char(content) == 9 || char(content) == 62) { content += 1 }
                let c = char(content)
                if let active = fence {
                    if c == active.character && run(content, c) >= active.count { fence = nil }
                    index = NSMaxRange(line); continue
                }
                if (c == 96 || c == 126) && run(content, c) >= 3 {
                    fence = (c, run(content, c)); index = NSMaxRange(line); continue
                }
                if content - index >= 4 && char(index) == 32 || char(index) == 9 {
                    index = NSMaxRange(line); continue
                }
                lineStart = false
            }
            let c = char(index)
            if c == 10 { lineStart = true; index += 1; continue }
            if c == 96 {
                let count = run(index, c)
                var end = index + count
                while end < input.length {
                    if char(end) == c {
                        let closing = run(end, c)
                        if closing == count { index = end + count; break }
                        end += closing
                    } else { end += 1 }
                }
                if end < input.length { continue }
                index += count; continue
            }
            let slashMath = c == 92 && (char(index + 1) == 40 || char(index + 1) == 91)
            if c == 92 && !slashMath { index += min(2, input.length - index); continue }
            guard c == 36 || slashMath, found.count < 256 else { index += 1; continue }
            let display = slashMath ? char(index + 1) == 91 : char(index + 1) == 36
            let delimiterLength = slashMath || display ? 2 : 1
            let start = index + delimiterLength
            if !display && whitespace(char(start)) { index += delimiterLength; continue }
            var end = start
            var closing: Int?
            var rejectedCurrencyEnd: Int?
            let maximum = min(input.length, start + 8_192)
            while end < maximum {
                if !display && (char(end) == 10 || char(end) == 96) { break }
                if slashMath {
                    if char(end) == 92 && char(end + 1) == (display ? 93 : 41) { closing = end; break }
                } else if char(end) == 36 {
                    if display && char(end + 1) == 36 { closing = end; break }
                    if !display && (48...57).contains(char(end + 1)) { rejectedCurrencyEnd = end; break }
                    if !display && !whitespace(char(end - 1)) {
                        closing = end; break
                    }
                }
                if char(end) == 92 { end += 2 } else { end += 1 }
            }
            guard let end = closing, end > start else { index = rejectedCurrencyEnd.map { $0 + 1 } ?? (index + delimiterLength); continue }
            let finish = end + delimiterLength
            result += input.substring(with: NSRange(location: copied, length: index - copied))
            result += Self.markerStart + String(found.count) + Self.markerEnd
            found.append(Formula(latex: input.substring(with: NSRange(location: start, length: end - start)),
                                 original: input.substring(with: NSRange(location: index, length: finish - index)), display: display))
            index = finish
            copied = finish
        }
        result += input.substring(from: copied)
        text = result
        formulas = found
    }
}

enum MathRenderer {
    private final class Cached: NSObject {
        let image: NSImage
        let descent: CGFloat
        init(_ image: NSImage, _ descent: CGFloat) { self.image = image; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.totalCostLimit = 16 * 1_048_576
        cache.countLimit = 256
        return cache
    }()
    // SwiftMath has some mutable shared font/atom caches. Serialize just formula creation.
    private static let lock = NSLock()

    static func attachment(latex: String, display: Bool) -> NSAttributedString? {
        guard latex.utf16.count <= 8_192 else { return nil }
        var depth = 0
        for c in latex {
            if c == "{" { depth += 1; if depth > 64 { return nil } }
            if c == "}" { depth -= 1 }
        }
        lock.lock()
        defer { lock.unlock() }
        let key = "\(display):\(latex)" as NSString
        let rendered: Cached
        if let cached = cache.object(forKey: key) {
            rendered = cached
        } else {
            var math = MathImage(latex: latex, fontSize: display ? 19 : 16,
                                 textColor: PreviewStyle.foreground, labelMode: display ? .display : .text)
            let (error, image, metrics) = math.asImage()
            guard error == nil, let image, let metrics,
                  image.size.width > 0, image.size.height > 0,
                  image.size.width < 10_000, image.size.height < 2_000 else { return nil }
            // Cache a Retina bitmap, so scrolling only composites an image, never re-typesets math.
            let scale = min(1, 740 / image.size.width)
            let size = NSSize(width: ceil(image.size.width * scale), height: ceil(image.size.height * scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            let cachedImage = NSImage(size: size)
            cachedImage.addRepresentation(bitmap)
            rendered = Cached(cachedImage, metrics.descent * scale)
            cache.setObject(rendered, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = NSRect(x: 0, y: -rendered.descent, width: rendered.image.size.width, height: rendered.image.size.height)
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttribute(.toolTip, value: latex, range: NSRange(location: 0, length: output.length))
        return output
    }
}
