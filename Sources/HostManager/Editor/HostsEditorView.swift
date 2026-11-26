import AppKit
import SwiftUI
import HostManagerCore

// MARK: - Line numbers

/// Draws the editor's line numbers and keeps them aligned with its scrolling. Clicking a
/// number selects that line.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    /// Character offset at which each line starts; its count is the number of lines.
    private var lineStarts: [Int] = [0]
    private var matchingLines: Set<Int> = []

    var font: NSFont = .monospacedSystemFont(ofSize: 11.5, weight: .regular) {
        didSet { invalidate() }
    }
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { invalidate() } }
    }
    /// Wide enough for the longest number, so the text never shifts when lines are added.
    private(set) var requiredWidth: CGFloat = 44

    override var isFlipped: Bool { true }

    func track(_ textView: NSTextView, in scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: .main) { [weak self] _ in
                self?.invalidate()
            },
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            },
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            },
        ]
        invalidate()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func invalidate() {
        guard let textView else { return }
        let text = textView.string as NSString
        var starts: [Int] = []
        var location = 0
        while true {
            starts.append(location)
            guard location < text.length else { break }
            let remaining = NSRange(location: location, length: text.length - location)
            let newline = text.range(of: "\n", options: [], range: remaining)
            if newline.location == NSNotFound { break }
            location = newline.location + 1
        }
        lineStarts = starts

        matchingLines = []
        if !searchQuery.isEmpty {
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] - 1 : text.length
                let line = text.substring(with: NSRange(location: start, length: max(0, end - start)))
                if line.range(of: searchQuery, options: .caseInsensitive) != nil {
                    matchingLines.insert(index)
                }
            }
        }

        let digits = max(2, String(starts.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(CGFloat(digits) * digitWidth) + 34
        if abs(width - requiredWidth) > 0.5 {
            requiredWidth = width
            superview?.needsLayout = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        guard let textView, let layoutManager = textView.layoutManager, let scrollView else { return }
        let inset = textView.textContainerInset.height
        let scroll = scrollView.contentView.bounds.minY
        let selection = textView.selectedRange()
        let current = lineIndexes(touchedBy: selection)

        var previousRect = NSRect.zero
        for (index, start) in lineStarts.enumerated() {
            var rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            if rect.height == 0 { rect = previousRect.isEmpty ? NSRect(x: 0, y: 0, width: 10, height: textView.defaultParagraphStyle?.minimumLineHeight ?? 16) : previousRect.offsetBy(dx: 0, dy: previousRect.height) }
            previousRect = rect
            let y = rect.minY + inset - scroll
            if y > bounds.height { break }
            if y + rect.height < 0 { continue }

            let isCurrent = current?.contains(index) == true
            let number = NSAttributedString(string: String(index + 1), attributes: [
                .font: font,
                .foregroundColor: isCurrent ? Theme.Syntax.currentLineNumber : Theme.Syntax.lineNumber,
            ])
            let size = number.size()
            number.draw(at: NSPoint(x: bounds.width - 14 - size.width, y: y + (rect.height - size.height) / 2))

            if matchingLines.contains(index) {
                Theme.accent.nsColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7, y: y + (rect.height - 5) / 2, width: 5, height: 5)).fill()
            }
        }
    }

    private func lineIndexes(touchedBy selection: NSRange) -> ClosedRange<Int>? {
        guard let first = lineStarts.lastIndex(where: { $0 <= selection.location }) else { return nil }
        var last = first
        if selection.length > 0 {
            last = lineStarts.lastIndex(where: { $0 < NSMaxRange(selection) }) ?? first
        }
        return first...last
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer,
              let window else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let scrolled = point.y + (scrollView?.contentView.bounds.minY ?? 0) - textView.textContainerInset.height
        var glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: scrolled), in: textContainer, fractionOfDistanceThroughGlyph: nil)
        glyph = min(glyph, max(0, layoutManager.numberOfGlyphs - 1))
        let character = min(layoutManager.characterIndexForGlyph(at: glyph), max(0, (textView.string as NSString).length - 1))
        var line = (textView.string as NSString).lineRange(for: NSRange(location: character, length: 0))
        if line.length > 0, line.location + line.length > character, (textView.string as NSString).character(at: NSMaxRange(line) - 1) == 0x0A {
            line.length -= 1   // keep the line break out of the selection
        }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(line)
    }
}

// MARK: - The editor

/// A scrollable text view with a line-number gutter. Reports changes through the closures
/// so SwiftUI never has to know about TextKit.
final class EditorContainerView: NSView, NSTextViewDelegate {
    let storage = HostsTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer: NSTextContainer
    let textView: HostsTextView
    private let scrollView = NSScrollView()
    private let gutter = LineNumberGutter()

    var onTextChange: ((String) -> Void)?
    var onCursorChange: ((Int, Int) -> Void)?
    var onIssueCountChange: ((Int) -> Void)?
    private(set) var fontSize: CGFloat = 0
    private(set) var wrapsLines = false

    init() {
        textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textView = HostsTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: .zero)

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        textView.delegate = self
        textView.setAccessibilityIdentifier("editor")
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = .textBackgroundColor
        // A hosts file is code: no smart quotes, spelling marks or link detection.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        addSubview(scrollView)
        addSubview(gutter)
        gutter.track(textView, in: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("EditorContainerView is created in code") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        let width = gutter.requiredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        storage.codeFont = font
        gutter.font = NSFont.monospacedSystemFont(ofSize: max(10, size - 1.5), weight: .regular)
        var typing = textView.typingAttributes
        typing[.font] = font
        typing[.foregroundColor] = NSColor.textColor
        textView.typingAttributes = typing
    }

    func setWraps(_ wraps: Bool) {
        wrapsLines = wraps
        let width = wraps ? max(bounds.width - gutter.requiredWidth, 100) : CGFloat.greatestFiniteMagnitude
        textContainer.widthTracksTextView = wraps
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = !wraps
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = !wraps
        textView.needsDisplay = true
        needsLayout = true
    }

    func replaceText(with text: String) {
        storage.replaceAll(with: text)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        gutter.invalidate()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onTextChange?(textView.string)
        onIssueCountChange?(storage.invalidLineCount)
        reportCursor()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportCursor()
    }

    /// Returns true when the editor handled the key itself; false lets the text view do its
    /// usual thing.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // New lines start with the indentation of the line above.
            let text = textView.string as NSString
            let caret = NSRange(location: textView.selectedRange().location, length: 0)
            let line = text.substring(with: text.lineRange(for: caret))
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab belongs to the text, not to keyboard navigation between controls.
            textView.insertText("\t", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }

    private func reportCursor() {
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        let prefix = text.substring(to: location)
        let line = prefix.components(separatedBy: "\n")
        onCursorChange?(line.count, (line.last ?? "").utf16.count + 1)
    }
}

// MARK: - SwiftUI wrapper

struct HostsEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var wrapsLines = false
    var searchQuery = ""
    var isEditable = true
    /// 1-based line and column of the cursor.
    var onCursorChange: ((Int, Int) -> Void)?
    /// How many lines the system will not understand.
    var onIssueCountChange: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        context.coordinator.parent = self
        view.setFontSize(fontSize)
        view.setWraps(wrapsLines)
        view.storage.searchQuery = searchQuery
        view.textView.isEditable = isEditable
        view.replaceText(with: text)
        view.onTextChange = { [coordinator = context.coordinator] string in
            coordinator.parent?.text = string
        }
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        context.coordinator.parent = self
        view.onCursorChange = onCursorChange
        view.onIssueCountChange = onIssueCountChange
        view.textView.isEditable = isEditable
        view.storage.searchQuery = searchQuery
        if view.fontSize != fontSize { view.setFontSize(fontSize) }
        if view.wrapsLines != wrapsLines { view.setWraps(wrapsLines) }
        // Text typed in the view has already reached the binding, so this only fires for
        // changes made elsewhere (another group selected, a snapshot restored).
        if view.textView.string != text { view.replaceText(with: text) }
    }

    static func dismantleNSView(_ view: EditorContainerView, coordinator: Coordinator) {
        // The undo stack belongs to the window; left alone it would paste another group's
        // text into this one.
        view.textView.undoManager?.removeAllActions()
    }

    final class Coordinator {
        var parent: HostsEditorView?
    }
}
