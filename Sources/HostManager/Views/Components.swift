import AppKit
import SwiftUI

// MARK: - Building blocks shared by several views

/// The material macOS draws behind sidebars, so the rail and the group list look like the
/// sidebar of every other app.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A switch sized for a list row. "On" is the text color rather than the accent color: a
/// column of switches stays calm that way, in every accent color.
struct CompactToggle: View {
    let isOn: Bool
    var identifier = ""
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var knobColor: Color {
        if isOn { return Color(nsColor: .textBackgroundColor) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.62, alpha: 1) : .white })
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(Color.primary.opacity(isOn ? 0.92 : (isHovering && isEnabled ? 0.26 : 0.17)))
                Circle()
                    .fill(knobColor)
                    .shadow(color: .black.opacity(isOn ? 0 : 0.18), radius: 0.5, y: 0.5)
                    .padding(2)
            }
            .frame(width: 28, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.snappy(duration: 0.18), value: isOn)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(L10n.t("a11y.switch"))
        .accessibilityValue(Text(isOn ? L10n.t("a11y.on") : L10n.t("a11y.off")))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }
}

/// A square icon button with no border until the pointer rests on it.
struct IconButton: View {
    let identifier: String
    let symbol: String
    let tooltip: String
    var isActive = false
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(isHovering ? 0.9 : 0.55))
                .frame(width: 26, height: 23)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Theme.rowSelection : Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 && isEnabled }
        .help(tooltip)
        .accessibilityIdentifier(identifier)
    }
}

/// The strip above the editor that explains something and offers a way out.
struct BannerBar: View {
    let hint: Hint
    var onDismiss: (() -> Void)?

    private var tint: Color {
        switch hint.style {
        case .info: return Theme.accent
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }

    private var symbol: String {
        switch hint.style {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(hint.text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(hint.actions.enumerated()), id: \.offset) { index, action in
                Button(action.title, action: action.handler)
                    .controlSize(.small)
                    .accessibilityIdentifier("hint.action.\(index)")
            }
            if let onDismiss {
                IconButton(identifier: "hint.dismiss", symbol: "xmark", tooltip: L10n.t("action.dismiss"), action: onDismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.11).gradient)
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.22)).frame(height: 1)
        }
    }
}

/// The editor area's empty state: a short explanation and the obvious next step.
struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .padding(26)
        .frame(maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.editorBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .padding(30)
    }
}
