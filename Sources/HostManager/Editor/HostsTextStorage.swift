import AppKit
import HostManagerCore

/// The editor's text, colored as it changes.
///
/// Only the paragraphs touched by an edit are re-colored (in `processEditing`, the hook
/// TextKit calls at the end of every editing batch), so typing stays cheap however long the
/// file is. A paragraph gets its font, its token colors and, while searching, a highlight on
/// every match.
final class HostsTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString(string: "")
    private var isRecoloring = false

    var codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { if codeFont != oldValue { recolorAll() } }
    }
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { recolorAll() } }
    }
    /// Lines the system will not understand, whatever part of the text was last edited.
    private(set) var invalidLineCount = 0

    // NSTextStorage is a class cluster: these are the methods a subclass has to provide.

    override var string: String { backing.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        // `range` is reported as it was before the replacement; how much it grew or shrank
        // is what `changeInLength` is for. Reporting the new length here as well would count
        // the change twice and hand TextKit a range that runs past the end of the text.
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    private var everything: NSRange { NSRange(location: 0, length: length) }

    /// Replaces the whole text in one editing batch. The caller resets the selection and undo
    /// history around it, since the old text is gone either way.
    func replaceAll(with text: String) {
        beginEditing()
        replaceCharacters(in: everything, with: text)
        endEditing()
    }

    override func processEditing() {
        // Attribute changes made here are folded into the editing session that caused them.
        // That can re-enter this method; the second pass has nothing left to do.
        guard !isRecoloring else {
            super.processEditing()
            return
        }
        isRecoloring = true
        defer { isRecoloring = false }
        if editedMask.contains(.editedCharacters) {
            recountInvalidLines()
        }
        let text = string as NSString
        if text.length > 0 {
            recolor(text.paragraphRange(for: NSIntersectionRange(editedRange, everything)))
        }
        super.processEditing()
    }

    private func recolorAll() {
        guard length > 0 else { return }
        beginEditing()
        recolor(everything)
        endEditing()
    }

    /// Recolors a range. Must run inside an editing session (which `processEditing` is), so
    /// the changes are reported to the layout managers as part of that same edit.
    private func recolor(_ range: NSRange) {
        let text = string as NSString
        let whole = text.paragraphRange(for: NSIntersectionRange(range, everything))
        guard whole.length > 0 else { return }

        addAttribute(.font, value: codeFont, range: whole)
        removeAttribute(.backgroundColor, range: whole)
        removeAttribute(.underlineStyle, range: whole)

        enumerateLines(in: whole) { lineRange, line in
            for token in HostsSyntax.tokens(for: line) {
                let tokenRange = NSRange(location: lineRange.location + token.range.location, length: token.range.length)
                switch token.kind {
                case .comment:
                    self.addAttribute(.foregroundColor, value: Theme.Syntax.comment, range: tokenRange)
                case .address:
                    self.addAttribute(.foregroundColor, value: Theme.Syntax.address, range: tokenRange)
                case .hostname:
                    self.addAttribute(.foregroundColor, value: Theme.Syntax.hostname, range: tokenRange)
                case .invalid:
                    self.setAttributes([
                        .font: self.codeFont,
                        .foregroundColor: Theme.Syntax.invalid,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: Theme.Syntax.invalid,
                    ], range: tokenRange)
                }
            }
            if !self.searchQuery.isEmpty {
                self.highlightMatches(of: self.searchQuery, in: line, at: lineRange.location)
            }
        }
    }

    private func recountInvalidLines() {
        var count = 0
        enumerateLines(in: everything) { _, line in
            if case .invalid = HostsSyntax.classify(line) { count += 1 }
        }
        invalidLineCount = count
    }

    /// Calls `body` with the range and text of every line in `range`.
    private func enumerateLines(in range: NSRange, _ body: (NSRange, String) -> Void) {
        let text = string as NSString
        var start = range.location
        let end = NSMaxRange(range)
        while start < end {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: start, length: end - start))
            let lineEnd = newline.location == NSNotFound ? end : newline.location
            body(NSRange(location: start, length: lineEnd - start), text.substring(with: NSRange(location: start, length: lineEnd - start)))
            if newline.location == NSNotFound || newline.location + 1 >= end { break }
            start = newline.location + 1
        }
    }

    private func highlightMatches(of needle: String, in line: String, at offset: Int) {
        let haystack = line as NSString
        var location = 0
        while location < haystack.length {
            let found = haystack.range(of: needle, options: [.caseInsensitive],
                                       range: NSRange(location: location, length: haystack.length - location))
            guard found.location != NSNotFound else { break }
            addAttribute(.backgroundColor, value: Theme.Syntax.searchMatch,
                         range: NSRange(location: offset + found.location, length: found.length))
            location = found.location + found.length
        }
    }
}

/// The editing surface. Adds a band behind the line with the cursor and keeps the Tab key
/// inside the text instead of moving focus to the next control.
final class HostsTextView: NSTextView {
    override init(frame: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frame, textContainer: container)
        NotificationCenter.default.addObserver(self, selector: #selector(redrawBackground),
                                               name: NSTextView.didChangeSelectionNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(redrawBackground),
                                               name: NSTextStorage.didProcessEditingNotification, object: container?.layoutManager?.textStorage)
    }

    required init?(coder: NSCoder) { fatalError("HostsTextView is created in code") }

    @objc private func redrawBackground() { needsDisplay = true }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let layoutManager, (string as NSString).length > 0 else { return }

        let length = (string as NSString).length
        let selection = selectedRange()
        let inset = textContainerInset.height
        Theme.Syntax.currentLine.setFill()

        // A caret highlights its line; a selection highlights every line it touches.
        if selection.length == 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: selection.location)
            let rect = lineFragmentRect(forGlyphAt: glyph)
            NSRect(x: 0, y: rect.minY + inset, width: bounds.width, height: rect.height).fill()
        } else {
            let characters = NSRange(location: selection.location, length: min(selection.length, length - selection.location))
            let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            var lineRects: [NSRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                lineRects.append(rect)
            }
            for rect in lineRects {
                NSRect(x: 0, y: rect.minY + inset, width: bounds.width, height: rect.height).fill()
            }
        }
    }

    /// The caret can sit one past the last glyph, on the empty line after a final newline.
    /// TextKit reports that "extra" line fragment, or nothing at all; then take the line above.
    private func lineFragmentRect(forGlyphAt glyph: Int) -> NSRect {
        guard let layoutManager else { return .zero }
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if rect.height > 0 || glyph == 0 { return rect }
        let above = layoutManager.lineFragmentRect(forGlyphAt: glyph - 1, effectiveRange: nil)
        return NSRect(x: 0, y: above.maxY, width: above.width, height: above.height)
    }
}
