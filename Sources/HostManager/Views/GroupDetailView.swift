import AppKit
import SwiftUI
import HostManagerCore

/// The right-hand pane: the selected group's hosts text, ready to edit.
@MainActor
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var cursor = (line: 1, column: 1)
    @State private var issueCount = 0

    var body: some View {
        if let group = model.selectedGroup {
            // Read once here so the view is re-evaluated whenever this group's text changes.
            let currentText = model.text(for: group.id)
            VStack(spacing: 0) {
                if let hint = model.hint {
                    BannerBar(hint: hint, onDismiss: model.dismissHint)
                }
                if group.isSystem, HostsFile.localhostStatus(in: currentText).isMissing {
                    BannerBar(hint: Hint(kind: .notice, style: .warning, text: L10n.t("hint.localhostMissing"), actions: [
                        HintAction(title: L10n.t("action.insertDefault")) { [weak model] in model?.insertDefaultSystemEntries() },
                    ]), onDismiss: nil)
                }
                editor(for: group)
                Divider()
                GroupStatusBar(group: group, text: currentText, cursor: cursor, issueCount: issueCount)
            }
            .animation(.snappy(duration: 0.2), value: model.hint?.id)
        } else {
            ContentUnavailableView(
                L10n.t("empty.title"),
                systemImage: "doc.text",
                description: Text(L10n.t("empty.message"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.editorBackground)
        }
    }

    private func editor(for group: HostGroup) -> some View {
        HostsEditorView(
            text: Binding(
                get: { [weak model] in model?.text(for: group.id) ?? "" },
                set: { [weak model] in model?.updateDraft($0, for: group.id) }
            ),
            fontSize: model.settings.fontSize,
            wrapsLines: model.settings.wrapLongLines,
            searchQuery: model.trimmedSearch,
            onCursorChange: { cursor = ($0, $1) },
            onIssueCountChange: { issueCount = $0 }
        )
        // One editor per group, so undo history and scroll position never leak between them.
        .id(group.id)
    }
}

/// The line under the editor: size and cursor position on the left as in a code editor,
/// everything about applying on the right.
@MainActor
struct GroupStatusBar: View {
    @Environment(AppModel.self) private var model
    let group: HostGroup
    let text: String
    let cursor: (line: Int, column: Int)
    let issueCount: Int

    private var isDirty: Bool { model.hasUnsavedChanges(for: group.id) }

    /// Whether the group's text is part of the hosts file right now.
    private var isLive: Bool {
        group.isSystem || GroupTree.flatten(model.groups).first { $0.id == group.id }?.isActive == true
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(stats)
            Text(L10n.f("status.cursor", cursor.line, cursor.column))
                .monospacedDigit()
            Spacer(minLength: 8)
            if !model.conflicts.isEmpty {
                Button { model.sheet = .conflicts } label: {
                    Label(L10n.f("status.conflicts", model.conflicts.count), systemImage: "exclamationmark.triangle")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .help(L10n.t("status.conflicts.help"))
                .accessibilityIdentifier("status.conflicts")
            }
            if issueCount > 0 {
                Label(L10n.f("status.invalidLines", issueCount), systemImage: "warningmark")
                    .foregroundStyle(.orange)
                    .help(L10n.t("status.invalidLines.help"))
            }
            applyState
            if isDirty {
                Button(L10n.t("action.revert")) { model.revert(group.id) }
                    .accessibilityIdentifier("status.revert")
                    .controlSize(.small)
                Button(L10n.t("action.save")) { model.save(group.id) }
                    .accessibilityIdentifier("status.save")
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(.bordered)
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Theme.editorBackground)
    }

    private var stats: String {
        let bytes = text.utf8.count
        let size = bytes < 1024 ? L10n.f("status.bytes", bytes) : L10n.f("status.kilobytes", Double(bytes) / 1024)
        return L10n.f("status.stats", text.components(separatedBy: "\n").count, size)
    }

    @ViewBuilder private var applyState: some View {
        switch model.applyPhase {
        case .idle:
            EmptyView()
        case .applying:
            if model.privilege == .requesting {
                Text(L10n.t("status.waitingForAuth"))
            } else {
                ProgressView().controlSize(.small)
                Text(L10n.t("status.applying"))
            }
        case .applied(let date):
            Label(L10n.f("status.applied", Self.clock.string(from: date)), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(L10n.f("status.applied.help", model.paths.hostsPath))
        case .failed(let message):
            Label(L10n.t("status.failed"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
            Button(L10n.t("action.retry")) { model.retryApply() }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
