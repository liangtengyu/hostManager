import AppKit
import SwiftUI

/// The app's colors. Chrome follows the system (accent color included); only the three
/// syntax colors are the app's own, picked to read well on both editor backgrounds.
enum Theme {
    static let accent = Color.accentColor
    static let rowSelection = Color.accentColor.opacity(0.16)
    static let rowHover = Color.primary.opacity(0.05)
    static let editorBackground = Color(nsColor: .textBackgroundColor)

    enum Syntax {
        static let comment = dynamic(
            light: (0.80, 0.27, 0.44),
            dark: (0.89, 0.54, 0.66)
        )
        static let address = dynamic(
            light: (0.47, 0.30, 0.80),
            dark: (0.77, 0.69, 1.00)
        )
        static let hostname = dynamic(
            light: (0.10, 0.37, 0.78),
            dark: (0.59, 0.76, 1.00)
        )
        static let invalid = NSColor.systemRed
        /// A faint band behind the line with the cursor.
        static let currentLine = NSColor.labelColor.withAlphaComponent(0.045)
        static let searchMatch = NSColor.systemYellow.withAlphaComponent(0.38)
        static let lineNumber = NSColor.tertiaryLabelColor
        static let currentLineNumber = NSColor.secondaryLabelColor
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: values.0, green: values.1, blue: values.2, alpha: 1)
        }
    }
}

extension Color {
    /// The same color for AppKit drawing.
    var nsColor: NSColor { NSColor(self) }
}
