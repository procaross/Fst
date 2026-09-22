import AppKit
import Down
import QuickLookUI
import WebKit

private final class PreviewEditorView: NSTextView {
    var appearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let sourceScrollView = NSScrollView()
    private let sourceTextView = PreviewEditorView()
    private let renderedView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let modeControl = NSSegmentedControl(labels: ["Rendered", "Source"], trackingMode: .selectOne, target: nil, action: nil)
    private let note = NSTextField(labelWithString: "")
    private var highlighter: SyntaxHighlighter!
    private var request = 0
    private var isMarkdown = false

    override func loadView() {
        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.hasHorizontalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceTextView.isEditable = false
        sourceTextView.isRichText = false
        sourceTextView.isSelectable = true
        sourceTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        sourceTextView.textContainerInset = NSSize(width: 16, height: 16)
        sourceTextView.isHorizontallyResizable = true
        sourceTextView.isVerticallyResizable = true
        sourceTextView.autoresizingMask = [.width]
        sourceTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceTextView.textContainer?.widthTracksTextView = false
        sourceTextView.textContainer?.containerSize = sourceTextView.maxSize
        sourceTextView.layoutManager?.allowsNonContiguousLayout = true
        sourceScrollView.documentView = sourceTextView

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
        for child in [sourceScrollView, renderedView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            sourceScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            sourceScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sourceScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            renderedView.topAnchor.constraint(equalTo: view.topAnchor),
            renderedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderedView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
        highlighter = SyntaxHighlighter(textView: sourceTextView)
        sourceTextView.appearanceChanged = { [weak self] in self?.applyTheme() }
        applyTheme()
        showSource()
    }

    private func applyTheme() {
        let theme = EditorTheme.current(for: view.effectiveAppearance)
        sourceTextView.backgroundColor = theme.background
        sourceTextView.textColor = theme.foreground
        highlighter.theme = theme
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        request += 1
        let current = request
        Task { @MainActor in
            do {
                let preview = try await Task.detached(priority: .userInitiated) { try PreviewText.read(url) }.value
                guard current == request else { handler(CocoaError(.userCancelled)); return }
                loadViewIfNeeded()

                sourceTextView.string = preview.text
                highlighter.setLanguage(filename: url.lastPathComponent)
                isMarkdown = Self.isMarkdownFile(url)
                modeControl.isHidden = !isMarkdown
                note.stringValue = preview.truncated ? "Preview limited to the first 1 MiB." : url.lastPathComponent

                if isMarkdown {
                    let html = try await Task.detached(priority: .userInitiated) {
                        try Self.renderMarkdown(preview.text, title: url.lastPathComponent)
                    }.value
                    guard current == request else { handler(CocoaError(.userCancelled)); return }
                    renderedView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
                    modeControl.selectedSegment = 0
                    showRendered()
                } else {
                    modeControl.selectedSegment = 1
                    showSource()
                }

                preferredContentSize = NSSize(width: 860, height: 640)
                handler(nil)
            } catch {
                handler(error)
            }
        }
    }

    @objc private func changePreviewMode(_ sender: NSSegmentedControl) {
        guard isMarkdown else { return }
        sender.selectedSegment == 0 ? showRendered() : showSource()
    }

    private func showRendered() {
        renderedView.isHidden = false
        sourceScrollView.isHidden = true
    }

    private func showSource() {
        renderedView.isHidden = true
        sourceScrollView.isHidden = false
    }

    private static func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private static func renderMarkdown(_ text: String, title: String) throws -> String {
        let body = try Down(markdownString: text).toHTML(.safe)
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(safeTitle)</title>
          <style>
            :root { color-scheme: light dark; }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 32px 42px 56px;
              color: #1f2328;
              background: #ffffff;
              font: 15px/1.58 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            }
            article { max-width: 920px; margin: 0 auto; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .55em; }
            h1 { font-size: 2em; border-bottom: 1px solid #d8dee4; padding-bottom: .28em; }
            h2 { font-size: 1.5em; border-bottom: 1px solid #d8dee4; padding-bottom: .25em; }
            h3 { font-size: 1.25em; }
            p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
            a { color: #0969da; text-decoration: none; }
            a:hover { text-decoration: underline; }
            img { max-width: 100%; height: auto; }
            code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
            code { background: rgba(175,184,193,.20); padding: .15em .35em; border-radius: 5px; font-size: .92em; }
            pre { background: #f6f8fa; padding: 16px; overflow: auto; border-radius: 8px; }
            pre code { background: transparent; padding: 0; }
            blockquote { border-left: 4px solid #d0d7de; padding-left: 1em; color: #59636e; }
            table { border-collapse: collapse; width: 100%; overflow: auto; display: block; }
            th, td { border: 1px solid #d0d7de; padding: 6px 13px; }
            tr:nth-child(2n) { background: #f6f8fa; }
            hr { border: 0; border-top: 1px solid #d8dee4; margin: 24px 0; }
            @media (prefers-color-scheme: dark) {
              body { color: #f0f3f6; background: #0d1117; }
              h1, h2, hr { border-color: #30363d; }
              a { color: #58a6ff; }
              code { background: rgba(110,118,129,.25); }
              pre, tr:nth-child(2n) { background: #161b22; }
              blockquote { border-color: #3d444d; color: #9198a1; }
              th, td { border-color: #3d444d; }
            }
          </style>
        </head>
        <body><article>\(body)</article></body>
        </html>
        """
    }
}
