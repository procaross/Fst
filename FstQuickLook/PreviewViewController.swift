import AppKit
import QuickLookUI

private final class PreviewEditorView: NSTextView {
    var appearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var sourceScrollView: NSScrollView?
    private var sourceTextView: PreviewEditorView?
    private let renderedScrollView = NSScrollView()
    private let renderedTextView = PreviewEditorView(usingTextLayoutManager: true)
    private let modeControl = NSSegmentedControl(labels: ["Rendered", "Source"], trackingMode: .selectOne, target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")

    private var highlighter: SyntaxHighlighter?
    private var request = 0
    private var isMarkdown = false
    private var sourceLoaded = false
    private var currentText = ""
    private var currentFilename = ""

    override func loadView() {
        configureRenderedView()

        modeControl.selectedSegment = 0
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(changePreviewMode(_:))
        modeControl.isHidden = true

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle

        let footer = NSStackView(views: [modeControl, note])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 640))
        for child in [renderedScrollView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            renderedScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            renderedScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderedScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderedScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])

        renderedTextView.appearanceChanged = { [weak self] in
            self?.renderedTextView.backgroundColor = .textBackgroundColor
        }
        showRendered()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        request += 1
        let current = request

        Task { @MainActor in
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try Performance.measure("Quick Look read") { try PreviewText.read(url) }
                }.value
                guard current == request else { handler(CocoaError(.userCancelled)); return }

                loadViewIfNeeded()
                currentText = preview.text
                currentFilename = url.lastPathComponent
                sourceLoaded = false
                isMarkdown = Self.isMarkdownFile(url)
                modeControl.isHidden = !isMarkdown
                note.stringValue = preview.truncated ? "Preview limited to the first 1 MiB." : url.lastPathComponent

                if isMarkdown {
                    let firstPaintText = Self.markdownFirstPaintPrefix(preview.text)
                    let rendered = try await Task.detached(priority: .userInitiated) {
                        try Performance.measure("Markdown native render") {
                            try MarkdownRenderer.render(firstPaintText)
                        }
                    }.value
                    guard current == request else { handler(CocoaError(.userCancelled)); return }

                    installRenderedResult(rendered, resetToTop: true)
                    modeControl.selectedSegment = 0
                    showRendered()
                    preferredContentSize = NSSize(width: 860, height: 640)
                    view.layoutSubtreeIfNeeded()
                    scrollRenderedToTop()
                    handler(nil)

                    // Syntax color is cosmetic, so Quick Look becomes interactive before this pass.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, current == self.request else { return }
                        // Quick Look may resize the hosted view after completion. Reset once more
                        // after that layout pass so a reused preview never opens mid-document.
                        self.scrollRenderedToTop()
                        self.highlightRenderedCodeBlocks(rendered.codeBlocks)
                    }

                    if firstPaintText.utf8.count < preview.text.utf8.count {
                        let fullText = preview.text
                        Task { @MainActor [weak self] in
                            do {
                                let full = try await Task.detached(priority: .userInitiated) {
                                    try Performance.measure("Markdown full render") {
                                        try MarkdownRenderer.render(fullText)
                                    }
                                }.value
                                guard let self, current == self.request else { return }
                                self.installRenderedResult(full, resetToTop: false)
                                self.highlightRenderedCodeBlocks(full.codeBlocks)
                            } catch {
                                // The already-visible first paint remains useful if the deferred
                                // full render fails or the request is replaced.
                            }
                        }
                    }
                } else {
                    loadSourceIfNeeded()
                    modeControl.selectedSegment = 1
                    showSource()
                    preferredContentSize = NSSize(width: 860, height: 640)
                    handler(nil)
                }
            } catch {
                handler(error)
            }
        }
    }

    @objc private func changePreviewMode(_ sender: NSSegmentedControl) {
        guard isMarkdown else { return }
        if sender.selectedSegment == 0 {
            showRendered()
        } else {
            loadSourceIfNeeded()
            showSource()
        }
    }

    private func configureRenderedView() {
        renderedScrollView.hasVerticalScroller = true
        renderedScrollView.hasHorizontalScroller = false
        renderedScrollView.autohidesScrollers = true
        renderedScrollView.documentView = renderedTextView

        renderedTextView.isEditable = false
        renderedTextView.isRichText = true
        renderedTextView.isSelectable = true
        renderedTextView.importsGraphics = false
        renderedTextView.usesFindBar = true
        renderedTextView.backgroundColor = .textBackgroundColor
        renderedTextView.textContainerInset = NSSize(width: 34, height: 28)
        renderedTextView.isHorizontallyResizable = false
        renderedTextView.isVerticallyResizable = true
        renderedTextView.autoresizingMask = [.width]
        renderedTextView.minSize = NSSize(width: 0, height: 0)
        renderedTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        renderedTextView.textContainer?.widthTracksTextView = true
        renderedTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        renderedTextView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    private func applySourceTheme() {
        guard let sourceTextView else { return }
        let theme = EditorTheme.current(for: sourceTextView.effectiveAppearance)
        sourceTextView.backgroundColor = theme.background
        sourceTextView.textColor = theme.foreground
        highlighter?.theme = theme
    }

    private func loadSourceIfNeeded() {
        guard !sourceLoaded else { return }
        installSourceViewIfNeeded()
        guard let sourceTextView else { return }
        sourceTextView.string = currentText
        highlighter?.setLanguage(filename: currentFilename)
        sourceTextView.scrollToBeginningOfDocument(nil)
        sourceLoaded = true
    }

    private func installSourceViewIfNeeded() {
        guard sourceTextView == nil else { return }

        let scrollView = NSScrollView()
        let textView = PreviewEditorView(usingTextLayoutManager: false)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = textView.maxSize
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.appearanceChanged = { [weak self] in self?.applySourceTheme() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView, positioned: .above, relativeTo: renderedScrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: renderedScrollView.bottomAnchor)
        ])

        sourceScrollView = scrollView
        sourceTextView = textView
        highlighter = SyntaxHighlighter(textView: textView)
        applySourceTheme()
    }

    private func showRendered() {
        renderedScrollView.isHidden = false
        sourceScrollView?.isHidden = true
    }

    private func installRenderedResult(_ result: MarkdownRenderResult, resetToTop: Bool) {
        let origin = renderedScrollView.contentView.bounds.origin
        renderedTextView.textStorage?.setAttributedString(result.attributedString)
        if resetToTop || origin.y <= 0 {
            scrollRenderedToTop()
        } else {
            renderedScrollView.contentView.scroll(to: origin)
            renderedScrollView.reflectScrolledClipView(renderedScrollView.contentView)
        }
    }

    private func scrollRenderedToTop() {
        // TextKit 2 lays out only the viewport. Asking an NSLayoutManager to lay out the
        // whole container turns a 1 MiB preview into hundreds of milliseconds of work.
        renderedTextView.setSelectedRange(NSRange(location: 0, length: 0))
        renderedTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        renderedScrollView.contentView.scroll(to: .zero)
        renderedScrollView.reflectScrolledClipView(renderedScrollView.contentView)
    }

    private func showSource() {
        renderedScrollView.isHidden = true
        sourceScrollView?.isHidden = false
    }

    private func highlightRenderedCodeBlocks(_ blocks: [MarkdownCodeBlock]) {
        guard let storage = renderedTextView.textStorage else { return }
        let theme = EditorTheme.current(for: renderedTextView.effectiveAppearance)
        let fullText = renderedTextView.string as NSString

        for block in blocks {
            guard block.range.location >= 0,
                  NSMaxRange(block.range) <= fullText.length,
                  block.range.length > 0,
                  let language = block.language,
                  !language.isEmpty else { continue }

            let source = fullText.substring(with: block.range) as NSString
            let mode = Language.detect("snippet.\(language.lowercased())")
            guard !mode.plain else { continue }

            var offset = 0
            var state = SyntaxLexer.State.normal
            while offset < source.length {
                let result = SyntaxLexer.scan(source, from: offset, state: state, language: mode)
                guard result.end > offset else { break }
                for token in result.tokens {
                    let color: NSColor
                    switch token.kind {
                    case .comment: color = theme.comment
                    case .string: color = theme.string
                    case .keyword: color = theme.keyword
                    case .number: color = theme.number
                    }
                    let range = NSRange(location: block.range.location + token.range.location,
                                        length: token.range.length)
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
                offset = result.end
                state = result.state
            }
        }
    }

    private static func markdownFirstPaintPrefix(_ markdown: String) -> String {
        let characterLimit = 32_768
        guard let cut = markdown.index(markdown.startIndex,
                                       offsetBy: characterLimit,
                                       limitedBy: markdown.endIndex),
              cut < markdown.endIndex else { return markdown }

        let prefix = markdown[..<cut]
        guard let newline = prefix.lastIndex(of: "\n") else { return String(prefix) }
        return String(prefix[...newline])
    }

    private static func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
