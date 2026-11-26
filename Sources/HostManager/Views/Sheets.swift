import AppKit
import SwiftUI
import HostManagerCore

/// Creates a group, or renames an existing one and picks its icon.
@MainActor
struct GroupEditorSheet: View {
    enum Mode {
        case create(parent: HostGroup?)
        case rename(HostGroup)
    }

    @Environment(AppModel.self) private var model
    let mode: Mode
    @State private var name: String
    @State private var icon: String
    @FocusState private var nameFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        _name = State(initialValue: Self.initialName(for: mode))
        _icon = State(initialValue: Self.initialIcon(for: mode))
    }

    private static func initialName(for mode: Mode) -> String {
        if case .rename(let group) = mode { return group.name }
        return ""
    }

    private static func initialIcon(for mode: Mode) -> String {
        if case .rename(let group) = mode { return group.icon }
        return ""
    }

    private var isRenaming: Bool {
        if case .rename = mode { return true }
        return false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRenaming ? L10n.t("sheet.rename") : L10n.t("sheet.create"))
                .font(.system(size: 15, weight: .semibold))
            TextField(L10n.t("sheet.namePlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($nameFocused)
                .onSubmit(submit)
            if case .create(.some(let parent)) = mode {
                Text(L10n.f("sheet.below", parent.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.t("sheet.icon"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            IconPicker(selection: $icon)
            HStack {
                Spacer()
                Button(L10n.t("action.cancel")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isRenaming ? L10n.t("action.save") : L10n.t("action.create"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 384)
        .onExitCommand { model.sheet = nil }
        .onAppear { nameFocused = true }
    }

    private func submit() {
        switch mode {
        case .create(let parent):
            model.createGroup(named: name, icon: icon, under: parent?.id)
        case .rename(let group):
            model.rename(group.id, to: name, icon: icon)
        }
    }
}

/// A handful of SF Symbols. Empty selection means "pick one automatically".
@MainActor
struct IconPicker: View {
    @Binding var selection: String

    /// Verified against the running system, so a symbol a given macOS lacks simply is not offered.
    private static let symbols: [String] = [
        "", "doc.text", "folder", "globe", "display", "server.rack", "hammer", "bug", "shippingbox",
        "paintpalette", "network", "lock.shield", "terminal", "wrench.and.screwdriver", "building.2",
        "externaldrive", "airplane", "gamecontroller", "cup.and.saucer", "music.note",
    ].filter { $0.isEmpty || NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 10), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button { selection = symbol } label: {
                    Image(systemName: symbol.isEmpty ? "wand.and.stars" : symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(symbol.isEmpty ? Color.purple : Color.primary)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == symbol ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(symbol.isEmpty ? L10n.t("sheet.icon.auto") : "")
            }
        }
    }
}

/// Every copy of the hosts file taken before an apply, with a preview and a way back.
@MainActor
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshots: [Snapshot] = []
    @State private var selected: Snapshot?
    @State private var pendingRestore: Snapshot?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if snapshots.isEmpty {
                    ContentUnavailableView(
                        L10n.t("history.empty"),
                        systemImage: "clock",
                        description: Text(L10n.t("history.empty.message"))
                    )
                } else {
                    List(snapshots, selection: $selected) { snapshot in
                        HistoryRow(snapshot: snapshot, older: older(than: snapshot))
                            .tag(snapshot)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                if let selected, let text = SnapshotStore.content(of: selected) {
                    HostsEditorView(text: .constant(text), fontSize: 12, isEditable: false)
                        .id(selected.id)
                } else {
                    ContentUnavailableView(
                        L10n.t("history.pick"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(L10n.t("history.pick.message"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.editorBackground)
                }
                Divider()
                HStack {
                    Button(L10n.t("action.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.historyDirectory])
                    }
                    Spacer()
                    Text(L10n.t("history.explain"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button(L10n.t("action.restore")) { pendingRestore = selected }
                        .disabled(selected == nil)
                }
                .controlSize(.small)
                .padding(12)
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .onExitCommand { model.sheet = nil }
        .onAppear(perform: reload)
        .alert(L10n.t("history.restore.title"), isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        ), presenting: pendingRestore) { snapshot in
            Button(L10n.t("action.restore"), action: { model.restore(snapshot) })
            Button(L10n.t("action.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.t("history.restore.message"))
        }
    }

    private func reload() {
        snapshots = SnapshotStore.list(in: model.paths.historyDirectory)
        if selected == nil { selected = snapshots.first }
    }

    /// The snapshot taken before this one, which is what it is compared against.
    private func older(than snapshot: Snapshot) -> Snapshot? {
        guard let index = snapshots.firstIndex(of: snapshot), index + 1 < snapshots.count else { return nil }
        return snapshots[index + 1]
    }
}

private struct HistoryRow: View {
    let snapshot: Snapshot
    let older: Snapshot?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.formatter.string(from: snapshot.date))
                .font(.system(size: 12.5))
                .monospacedDigit()
            HStack(spacing: 6) {
                if let text = SnapshotStore.content(of: snapshot) {
                    Text(L10n.f("status.lines", text.components(separatedBy: "\n").count))
                }
                if let change = change {
                    Text(L10n.f("history.diff", change.added, change.removed))
                        .foregroundStyle(change.added > 0 || change.removed > 0 ? Color.primary : Color.secondary)
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// Lines this snapshot has that the previous one did not, and the other way round.
    private var change: (added: Int, removed: Int)? {
        guard let older, let before = older.lines, let after = snapshot.lines else { return nil }
        let beforeSet = Set(before)
        let afterSet = Set(after)
        return (afterSet.subtracting(beforeSet).count, beforeSet.subtracting(afterSet).count)
    }
}

private extension Snapshot {
    var lines: [String]? { SnapshotStore.content(of: self)?.components(separatedBy: "\n") }
}

/// Hostnames that more than one active group points at different addresses.
@MainActor
struct ConflictsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("conflicts.title")).font(.system(size: 15, weight: .semibold))
                Text(L10n.t("conflicts.message")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conflict.hostname)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            ForEach(Array(conflict.mappings.enumerated()), id: \.offset) { index, mapping in
                                HStack(spacing: 8) {
                                    Image(systemName: index == 0 ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(index == 0 ? Color.green : Color.secondary)
                                        .font(.system(size: 11))
                                    Text(mapping.address)
                                        .font(.system(.callout, design: .monospaced))
                                    Text(mapping.groupName)
                                        .foregroundStyle(.secondary)
                                    if index == 0 {
                                        Text(L10n.t("conflicts.wins"))
                                            .font(.system(size: 10, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.green.opacity(0.15)))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 14)
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("action.done")) { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 360)
        .onExitCommand { model.sheet = nil }
    }
}

@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("settings.title"))
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            Form {
                Section {
                    Toggle(L10n.t("settings.flush"), isOn: setting(\.flushDNSCache))
                    Text(L10n.t("settings.flush.help"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section(L10n.t("settings.editor")) {
                    Stepper(value: setting(\.fontSize), in: 10...18, step: 1) {
                        HStack {
                            Text(L10n.t("settings.fontSize"))
                            Spacer()
                            Text(verbatim: "\(Int(model.settings.fontSize))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(L10n.t("settings.wrap"), isOn: setting(\.wrapLongLines))
                }
                Section(L10n.t("settings.backups")) {
                    Toggle(L10n.t("settings.snapshot"), isOn: setting(\.snapshotBeforeApply))
                    Picker(L10n.t("settings.limit"), selection: setting(\.snapshotLimit)) {
                        ForEach([20, 50, 100, 0], id: \.self) { limit in
                            Text(limit == 0 ? L10n.t("settings.limit.all") : String(limit)).tag(limit)
                        }
                    }
                }
                Section {
                    HStack(alignment: .top) {
                        Text(L10n.f("settings.data", model.paths.dataDirectory.path))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer()
                        Button(L10n.t("action.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.dataDirectory])
                        }
                    }
                    if model.paths.isDevMode {
                        Text(L10n.f("settings.devMode", model.paths.hostsPath))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("action.done")) { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
                }
            .padding(16)
        }
        .frame(width: 470, height: 470)
        .onExitCommand { model.sheet = nil }
    }

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}
