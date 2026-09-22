import AppKit
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let renderedScrollView = NSScrollView()
    private let renderedTextView = NSTextView(usingTextLayoutManager: true)
    private var sourceScrollView: NSScrollView?
    private var sourceTextView: NSTextView?
    private let codeLayout = CodeBlockLayoutDelegate()
    private let previewButton = NSButton(title: "预览", target: nil, action: nil)
    private let sourceButton = NSButton(title: "源码", target: nil, action: nil)
    private let footer = NSView()
    private let separator = NSView()
    private let note = NSTextField(labelWithString: "")
    private var footerHeight: NSLayoutConstraint!
    private var request = 0
    private var modeRequest = 0
    private var isMarkdown = false
    private var showingSource = false
    private var sourceLoaded = false
    private var sourceLoading = false
    private var currentText = ""
    private var currentFilename = ""
    private var isLiveScrolling = false
    private var warmupGeneration = 0
    private var warmupOffset = 0
    private var pendingRendered: NSAttributedString?
    private var pendingSource: NSAttributedString?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 640))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = PreviewStyle.background.cgColor
        configure(renderedTextView, in: renderedScrollView, inset: NSSize(width: 32, height: 24))
        renderedTextView.textLayoutManager?.delegate = codeLayout
        renderedTextView.linkTextAttributes = [.foregroundColor: PreviewStyle.link,
                                               .underlineStyle: NSUnderlineStyle.single.rawValue]
        footer.wantsLayer = true
        footer.layer?.backgroundColor = PreviewStyle.background.cgColor
        separator.wantsLayer = true
        separator.layer?.backgroundColor = PreviewStyle.border.withAlphaComponent(0.6).cgColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = PreviewStyle.muted
        note.lineBreakMode = .byTruncatingTail
        for button in [previewButton, sourceButton] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.target = self
            button.action = #selector(changeMode(_:))
            button.setAccessibilityLabel(button.title)
        }
        previewButton.toolTip = "查看渲染后的 Markdown"
        sourceButton.toolTip = "查看 Markdown 源码"
        for child in [renderedScrollView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        for child in [separator, previewButton, sourceButton, note] {
            child.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(child)
        }
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            renderedScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            renderedScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderedScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderedScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footerHeight,
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            previewButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            previewButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            previewButton.widthAnchor.constraint(equalToConstant: 48),
            previewButton.heightAnchor.constraint(equalToConstant: 24),
            sourceButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 4),
            sourceButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            sourceButton.widthAnchor.constraint(equalToConstant: 48),
            sourceButton.heightAnchor.constraint(equalToConstant: 24),
            note.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: sourceButton.trailingAnchor, constant: 12),
            note.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configure(_ text: NSTextView, in scroll: NSScrollView, inset: NSSize) {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = PreviewStyle.background
        scroll.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.importsGraphics = false
        text.usesFindBar = true
        text.backgroundColor = PreviewStyle.background
        text.textColor = PreviewStyle.foreground
        text.textContainerInset = inset
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textLayoutManager?.limitsLayoutForSuspiciousContents = true
        for (name, selector) in [(NSScrollView.willStartLiveScrollNotification, #selector(scrollWillStart(_:))),
                                  (NSScrollView.didEndLiveScrollNotification, #selector(scrollDidEnd(_:)))] {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: scroll)
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        request += 1
        modeRequest += 1
        sourceButton.isEnabled = true
        let current = request
        isLiveScrolling = false
        cancelWarmup()
        pendingRendered = nil
        pendingSource = nil
        sourceLoaded = false
        sourceLoading = false
        Task { @MainActor in
            do {
                let (text, truncated, limit) = try await Task.detached(priority: .userInitiated) {
                    let json = url.pathExtension.lowercased() == "json"
                    let limit = json ? JSONPreview.byteLimit : 1_048_576
                    let preview = try Performance.measure("Quick Look read") { try PreviewText.read(url, limit: limit) }
                    if json {
                        let result = Performance.measure("JSON format") { JSONPreview.format(preview.text, truncated: preview.truncated) }
                        return (result.text, result.truncated, limit)
                    }
                    return (preview.text, preview.truncated, limit)
                }.value
                guard current == request else { handler(CocoaError(.userCancelled)); return }
                loadViewIfNeeded()
                currentText = text
                currentFilename = url.lastPathComponent
                isMarkdown = ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased())
                note.stringValue = truncated ? "仅显示前 \(limit / 1_048_576) MiB" : ""
                note.isHidden = !truncated
                previewButton.isHidden = !isMarkdown
                sourceButton.isHidden = !isMarkdown
                footer.isHidden = !isMarkdown && !truncated
                footerHeight.constant = footer.isHidden ? 0 : 36
                preferredContentSize = NSSize(width: 860, height: 640)
                if isMarkdown {
                    let prefix = Self.firstPaintPrefix(text)
                    let rendered = try await Task.detached(priority: .userInitiated) {
                        try Performance.measure("Markdown first paint render") { try MarkdownRenderer.render(prefix) }
                    }.value
                    guard current == request else { handler(CocoaError(.userCancelled)); return }
                    install(rendered.attributedString, in: renderedTextView, scroll: renderedScrollView, resetToTop: true)
                    showSource(false)
                    view.layoutSubtreeIfNeeded()
                    scrollToTop(renderedTextView, in: renderedScrollView)
                    handler(nil)
                    resetAfterPresentation(renderedTextView, in: renderedScrollView, request: current)
                    if prefix.utf8.count < text.utf8.count {
                        renderFullMarkdown(text, request: current)
                    } else { startWarmup() }
                } else {
                    try await loadSource(request: current)
                    guard current == request else { handler(CocoaError(.userCancelled)); return }
                    showSource(true)
                    handler(nil)
                    resetAfterPresentation(sourceTextView!, in: sourceScrollView!, request: current)
                }
            } catch { handler(error) }
        }
    }

    private func renderFullMarkdown(_ text: String, request current: Int) {
        Task { @MainActor [weak self] in
            guard let full = try? await Task.detached(priority: .utility, operation: {
                try Performance.measure("Markdown full render") { try MarkdownRenderer.render(text) }
            }).value, let self, current == self.request else { return }
            if self.isLiveScrolling { self.pendingRendered = full.attributedString }
            else {
                self.install(full.attributedString, in: self.renderedTextView, scroll: self.renderedScrollView)
                if !self.showingSource { self.startWarmup() }
            }
        }
    }

    private func loadSource(request current: Int) async throws {
        guard !sourceLoaded, !sourceLoading else { return }
        sourceLoading = true
        sourceButton.isEnabled = false
        let text = currentText
        let filename = currentFilename
        let prefix = Self.firstPaintPrefix(text)
        let first = await Task.detached(priority: .userInitiated) { PreviewContent(PreviewStyle.source(prefix, filename: filename)) }.value.text
        guard current == request else { throw CocoaError(.userCancelled) }
        installSourceView()
        install(first, in: sourceTextView!, scroll: sourceScrollView!, resetToTop: true)
        sourceLoaded = true
        sourceLoading = false
        sourceButton.isEnabled = true
        if prefix.utf8.count < text.utf8.count {
            Task { @MainActor [weak self] in
                let full = await Task.detached(priority: .utility) {
                    Performance.measure("Source full highlight") { PreviewContent(PreviewStyle.source(text, filename: filename)) }
                }.value.text
                guard let self, current == self.request, let view = self.sourceTextView, let scroll = self.sourceScrollView else { return }
                if self.isLiveScrolling { self.pendingSource = full }
                else {
                    self.install(full, in: view, scroll: scroll)
                    if self.showingSource { self.startWarmup() }
                }
            }
        }
    }

    private func installSourceView() {
        guard sourceTextView == nil else { return }
        let text = NSTextView(usingTextLayoutManager: true)
        let scroll = NSScrollView()
        configure(text, in: scroll, inset: NSSize(width: 20, height: 20))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll, positioned: .above, relativeTo: renderedScrollView)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: renderedScrollView.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: renderedScrollView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: renderedScrollView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: renderedScrollView.bottomAnchor)
        ])
        sourceTextView = text
        sourceScrollView = scroll
    }

    @objc private func changeMode(_ sender: NSButton) {
        guard isMarkdown else { return }
        modeRequest += 1
        let mode = modeRequest
        if sender === previewButton { showSource(false); return }
        let current = request
        let firstSourcePaint = !sourceLoaded
        Task { @MainActor in
            try? await loadSource(request: current)
            if current == request, mode == modeRequest {
                showSource(true)
                if firstSourcePaint, let text = sourceTextView, let scroll = sourceScrollView {
                    resetAfterPresentation(text, in: scroll, request: current)
                }
            }
        }
    }

    private func showSource(_ source: Bool) {
        cancelWarmup()
        showingSource = source
        renderedScrollView.isHidden = source
        sourceScrollView?.isHidden = !source
        for (button, selected) in [(previewButton, !source), (sourceButton, source)] {
            button.layer?.backgroundColor = (selected ? PreviewStyle.subtle : PreviewStyle.background).cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? PreviewStyle.foreground : PreviewStyle.muted
            ])
            button.setAccessibilityValue(selected ? "已选择" : "")
        }
        startWarmup()
    }

    private func install(_ text: NSAttributedString, in textView: NSTextView, scroll: NSScrollView, resetToTop: Bool = false) {
        let origin = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(text)
        if resetToTop || origin.y <= 0 { scrollToTop(textView, in: scroll) }
        else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func resetAfterPresentation(_ text: NSTextView, in scroll: NSScrollView, request current: Int) {
        // Quick Look can resize its remote view after completion or after revealing Source.
        DispatchQueue.main.async { [weak self] in
            guard let self, current == self.request, !self.isLiveScrolling,
                  self.activeTextView === text else { return }
            self.view.layoutSubtreeIfNeeded()
            self.scrollToTop(text, in: scroll)
        }
    }

    private func scrollToTop(_ text: NSTextView, in scroll: NSScrollView) {
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func scrollWillStart(_ notification: Notification) {
        isLiveScrolling = true
        cancelWarmup()
    }

    @objc private func scrollDidEnd(_ notification: Notification) {
        isLiveScrolling = false
        if let pending = pendingRendered {
            pendingRendered = nil
            install(pending, in: renderedTextView, scroll: renderedScrollView)
        }
        if let pending = pendingSource, let text = sourceTextView, let scroll = sourceScrollView {
            pendingSource = nil
            install(pending, in: text, scroll: scroll)
        }
        startWarmup()
    }

    private var activeTextView: NSTextView { showingSource ? (sourceTextView ?? renderedTextView) : renderedTextView }
    private func cancelWarmup() { warmupGeneration += 1 }

    private func startWarmup() {
        guard !isLiveScrolling, let layout = activeTextView.textLayoutManager,
              let content = layout.textContentManager else { return }
        warmupGeneration += 1
        warmupOffset = layout.textViewportLayoutController.viewportRange.map {
            content.offset(from: content.documentRange.location, to: $0.endLocation)
        } ?? 0
        scheduleWarmup(warmupGeneration)
    }

    private func scheduleWarmup(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
            self?.warmup(generation)
        }
    }

    private func warmup(_ generation: Int) {
        guard generation == warmupGeneration, !isLiveScrolling,
              let layout = activeTextView.textLayoutManager, let content = layout.textContentManager else { return }
        let document = content.documentRange
        let total = content.offset(from: document.location, to: document.endLocation)
        guard warmupOffset < total else { return }
        let endOffset = min(total, warmupOffset + 2_048)
        guard let start = content.location(document.location, offsetBy: warmupOffset),
              let end = content.location(document.location, offsetBy: endOffset),
              let range = NSTextRange(location: start, end: end) else { return }
        layout.ensureLayout(for: range)
        warmupOffset = endOffset
        if endOffset < total { scheduleWarmup(generation) }
    }

    private static func firstPaintPrefix(_ text: String) -> String {
        guard let cut = text.index(text.startIndex, offsetBy: 32_768, limitedBy: text.endIndex), cut < text.endIndex else { return text }
        let prefix = text[..<cut]
        guard let newline = prefix.lastIndex(of: "\n") else { return String(prefix) }
        return String(prefix[...newline])
    }
}
