import AppKit
import Foundation
import Observation
import HostManagerCore

// MARK: - Small value types the views read

enum PrivilegeState: Equatable {
    case idle
    case requesting
    case ready
    case devMode
    case canceled
    case failed(String)
}

enum ApplyPhase: Equatable {
    case idle
    case applying
    case applied(Date)
    case failed(String)
}

/// What a banner is about, which decides whether a newer banner may replace it.
enum HintKind {
    case authorization
    case externalChange
    case applyError
    case ancestorOff
    case notice

    /// Kept until the user deals with it; a passing remark must not push it out.
    var isSticky: Bool {
        self == .authorization || self == .externalChange || self == .applyError
    }
}

struct HintAction {
    let title: String
    let handler: () -> Void
}

struct Hint: Identifiable {
    enum Style { case info, warning, error }

    let id = UUID()
    let kind: HintKind
    let style: Style
    let text: String
    var actions: [HintAction] = []
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let action: () -> Void
}

enum Sheet: Identifiable {
    case newGroup(parentID: UUID?)
    case rename(UUID)
    case history
    case settings
    case conflicts

    var id: String {
        switch self {
        case .newGroup(nil): return "new"
        case .newGroup(.some(let parent)): return "new-\(parent)"
        case .rename(let id): return "rename-\(id)"
        case .history: return "history"
        case .settings: return "settings"
        case .conflicts: return "conflicts"
        }
    }
}

// MARK: - The model

/// Everything the window shows and everything the user can do to it. Main-actor only; the
/// one blocking job in the app (writing the hosts file) runs elsewhere and reports back.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let windowFrame = "windowFrame"
        static let sidebarHidden = "sidebarHidden"
        static let selectedGroup = "selectedGroup"
    }

    // Kept on disk
    var groups: [HostGroup] = []
    var settings: AppSettings
    @ObservationIgnored private(set) var lastApplied: LastApplied?

    // Session state
    var selectedID: UUID?
    /// Editor text that differs from the group's saved content, by group id.
    var drafts: [UUID: String] = [:]
    var searchText = ""
    var isSearchVisible = false
    /// Bumped whenever the search field should take the cursor.
    var searchFocusRequest = 0
    var isSidebarHidden: Bool
    var privilege: PrivilegeState = .idle
    var applyPhase: ApplyPhase = .idle
    var conflicts: [HostnameConflict] = []
    var hint: Hint?
    var confirmation: Confirmation?
    var sheet: Sheet?
    /// The group being dragged in the sidebar, for the drop delegates to pick up.
    var draggingID: UUID?

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: PrivilegedSession
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var applyQueued = false
    /// Set when a change could not reach the hosts file, so it is applied once it can be.
    @ObservationIgnored private var hasPendingChanges = false
    /// How many times the hosts file has been written in this session. The UI checks assert on it.
    @ObservationIgnored private(set) var writeCount = 0
    @ObservationIgnored private var hintDismissal: Task<Void, Never>?
    /// The row clicked last and when, to recognise a double click without relying on the
    /// gesture system's own timing.
    @ObservationIgnored private var lastClickedGroup: UUID?
    @ObservationIgnored private var lastClickedAt = Date.distantPast

    init(paths: Paths = Paths.resolve(), defaults: UserDefaults = .standard) {
        self.paths = paths
        self.defaults = defaults
        self.isSidebarHidden = defaults.bool(forKey: Keys.sidebarHidden)
        let logURL = paths.dataDirectory.appendingPathComponent("privilege.log")
        self.session = PrivilegedSession(hostsPath: paths.hostsPath, requiresAuthorization: !paths.isDevMode) { line in
            // Queue-level work calls this from any thread; the file is small and append-only.
            let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            if let data = text.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? FileManager.default.createDirectory(atPath: paths.dataDirectory.path, withIntermediateDirectories: true)
                    try? data.write(to: logURL)
                }
            }
        }
        self.settings = AppSettings()

        let systemName = L10n.t("group.system.name")
        if let document = try? Store.load(from: paths.storeURL) {
            groups = document.groups
            settings = document.settings
            lastApplied = document.lastApplied
        } else {
            // First launch: take in whatever is in the hosts file, unchanged, and add the samples.
            let hosts = Self.readHosts(at: paths.hostsURL) ?? ""
            groups = HostsImporter.initialGroups(
                fromHosts: hosts, systemGroupName: systemName, importedGroupName: L10n.t("group.imported.name")
            ) + SampleGroups.make()
            lastApplied = LastApplied(fileSHA256: Digest.sha256Hex(hosts), systemContent: groups[0].content, date: Date())
            try? Store.save(document, to: paths.storeURL)
        }
        if groups.first?.isSystem != true {
            groups.insert(HostGroup.system(content: "", name: systemName), at: 0)
        }
        selectedID = defaults.string(forKey: Keys.selectedGroup)
            .flatMap(UUID.init(uuidString:))
            .flatMap { GroupTree.contains($0, in: groups) ? $0 : nil }
            ?? groups.dropFirst().first?.id
            ?? HostGroup.systemID
    }

    private var document: StoreDocument {
        StoreDocument(groups: groups, settings: settings, lastApplied: lastApplied)
    }

    // MARK: Reading state

    var systemID: UUID { HostGroup.systemID }

    var systemGroup: HostGroup? { groups.first { $0.isSystem } }

    var selectedGroup: HostGroup? {
        selectedID.flatMap { GroupTree.first($0, in: groups) }
    }

    /// What the editor for a group shows: the unsaved text if there is one, else the saved text.
    func text(for id: UUID) -> String {
        drafts[id] ?? GroupTree.first(id, in: groups)?.content ?? ""
    }

    func hasUnsavedChanges(for id: UUID) -> Bool {
        guard let draft = drafts[id] else { return false }
        return draft != GroupTree.first(id, in: groups)?.content
    }

    var unsavedIDs: [UUID] {
        GroupTree.all(groups).map(\.id).filter { hasUnsavedChanges(for: $0) }
    }

    var hasUnsavedChanges: Bool { !unsavedIDs.isEmpty }

    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rows the sidebar shows right now.
    var visibleNodes: [GroupTree.Node] {
        let query = trimmedSearch
        return query.isEmpty
            ? GroupTree.flatten(groups)
            : GroupTree.flatten(groups, matching: { group in
                let text = self.drafts[group.id] ?? group.content
                return group.name.localizedCaseInsensitiveContains(query)
                    || text.localizedCaseInsensitiveContains(query)
            })
    }

    var canApply: Bool {
        switch privilege {
        case .ready, .devMode, .requesting: true
        case .idle, .canceled, .failed: false
        }
    }

    // MARK: Lifecycle

    /// Called once the window is up: notices outside changes to the hosts file and asks for
    /// the admin password.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshConflicts()
        if !paths.isDevMode, let lastApplied, let current = Self.readHosts(at: paths.hostsURL),
           Digest.sha256Hex(current) != lastApplied.fileSHA256 {
            hint = Hint(kind: .externalChange, style: .warning, text: L10n.t("notice.externalChange"), actions: [
                HintAction(title: L10n.t("action.import")) { [weak self] in self?.askToImportCurrentFile() },
                HintAction(title: L10n.t("action.ignore")) { [weak self] in
                    self?.lastApplied?.fileSHA256 = Digest.sha256Hex(current)
                    self?.hint = nil
                    self?.persist()
                },
            ])
        }
        // Asks for the admin password; in development mode it only opens the helper.
        requestPrivilege()
    }

    func requestPrivilege() {
        privilege = .requesting
        session.start { [weak self] result in
            Task { @MainActor in self?.handlePrivilege(result) }
        }
    }

    private func handlePrivilege(_ result: Result<Void, PrivilegeError>) {
        switch result {
        case .success:
            privilege = paths.isDevMode ? .devMode : .ready
            if let hint, hint.kind == .authorization { self.hint = nil }
            if hasPendingChanges {
                apply()
            }
        case .failure(.canceled):
            privilege = .canceled
            showAuthorizationHint(L10n.t("hint.canceled"))
        case .failure(let error):
            privilege = .failed(error.message)
            showAuthorizationHint(error.message)
        }
    }

    private func showAuthorizationHint(_ text: String) {
        hint = Hint(kind: .authorization, style: .warning, text: text, actions: [
            HintAction(title: L10n.t("action.authorize")) { [weak self] in self?.requestPrivilege() },
        ])
    }

    /// Called on quit: closes the privileged session so nothing outlives the app.
    func shutdown() {
        persist()
        hintDismissal?.cancel()
        session.shutdown()
    }

    // MARK: Selection and editing

    /// A click on a group row. Returns true when this click completes a double click.
    @discardableResult
    func clickGroup(_ id: UUID) -> Bool {
        let now = Date()
        let isDouble = lastClickedGroup == id && now.timeIntervalSince(lastClickedAt) < NSEvent.doubleClickInterval
        lastClickedGroup = isDouble ? nil : id
        lastClickedAt = now
        select(id)
        return isDouble
    }

    func select(_ id: UUID) {
        selectedID = id
        defaults.set(id.uuidString, forKey: Keys.selectedGroup)
        if let hint, hint.kind == .ancestorOff || hint.kind == .notice { self.hint = nil }
    }

    func updateDraft(_ text: String, for id: UUID) {
        guard GroupTree.contains(id, in: groups) else { return }
        drafts[id] = text == GroupTree.first(id, in: groups)?.content ? nil : text
    }

    /// Writes the draft back into its group and makes it live.
    func save(_ id: UUID) {
        guard let group = GroupTree.first(id, in: groups), hasUnsavedChanges(for: id) else {
            apply()
            return
        }
        // Removing the last `localhost` mapping takes name resolution down with it.
        if group.isSystem {
            let before = HostsFile.localhostStatus(in: group.content)
            let after = HostsFile.localhostStatus(in: drafts[id] ?? "")
            if !before.isMissing, after.isMissing {
                confirmation = Confirmation(
                    title: L10n.t("localhost.confirm.title"),
                    message: L10n.t("localhost.confirm.message"),
                    confirmTitle: L10n.t("localhost.confirm.proceed"),
                    isDestructive: true
                ) { [weak self] in
                    self?.commit(id)
                    self?.persist()
                    self?.apply()
                }
                return
            }
        }
        commit(id)
        persist()
        apply()
    }

    func saveSelected() {
        guard let selectedID else { return }
        save(selectedID)
    }

    /// Throws the editor text away and shows the saved content again.
    func revert(_ id: UUID) {
        drafts[id] = nil
    }

    private func commit(_ id: UUID) {
        guard let draft = drafts[id] else { return }
        _ = GroupTree.modify(id, in: &groups) { $0.content = HostsFile.stripMarkers(from: draft) }
        drafts[id] = nil
    }

    func commitAllDrafts() {
        for id in unsavedIDs { commit(id) }
        persist()
    }

    func discardAllDrafts() {
        drafts = [:]
    }

    // MARK: Switching groups on and off

    /// A switch takes effect at once. A group with unsaved edits takes those along, so what
    /// goes live is what the user is looking at.
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let group = GroupTree.first(id, in: groups), !group.isSystem, group.enabled != enabled else { return }
        commit(id)
        _ = GroupTree.modify(id, in: &groups) { $0.enabled = enabled }
        persist()
        if enabled, let blocker = GroupTree.ancestors(of: id, in: groups).first(where: { !$0.enabled }) {
            showTransient(Hint(kind: .ancestorOff, style: .info,
                               text: L10n.f("hint.ancestorOff", group.name, blocker.name), actions: [
                HintAction(title: L10n.t("action.enableAncestors")) { [weak self] in self?.enableAncestors(of: id) },
            ]))
        } else if let hint, hint.kind == .ancestorOff {
            self.hint = nil
        }
        apply()
    }

    func toggleSelected() {
        guard let group = selectedGroup, !group.isSystem else { return }
        setEnabled(group.id, !group.enabled)
    }

    private func enableAncestors(of id: UUID) {
        for ancestor in GroupTree.ancestors(of: id, in: groups) where !ancestor.enabled {
            _ = GroupTree.modify(ancestor.id, in: &groups) { $0.enabled = true }
        }
        hint = nil
        persist()
        apply()
    }

    func toggleExpanded(_ id: UUID) {
        _ = GroupTree.modify(id, in: &groups) { $0.isExpanded.toggle() }
        persist()
    }

    // MARK: The group tree

    @discardableResult
    func createGroup(named rawName: String, icon: String, under parentID: UUID?) -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = HostGroup(name: name, icon: icon, content: "# \(name)\n")
        if let parentID, let parent = GroupTree.first(parentID, in: groups), !parent.isSystem {
            _ = GroupTree.modify(parent.id, in: &groups) { $0.children.append(group); $0.isExpanded = true }
        } else {
            groups.append(group)
        }
        sheet = nil
        persist()
        select(group.id)
        return group.id
    }

    func rename(_ id: UUID, to rawName: String, icon: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, GroupTree.contains(id, in: groups) else { return }
        _ = GroupTree.modify(id, in: &groups) { $0.name = name; $0.icon = icon }
        sheet = nil
        persist()
        apply()
    }

    func requestDelete(_ id: UUID) {
        guard let group = GroupTree.first(id, in: groups), !group.isSystem else { return }
        let childCount = GroupTree.all(group.children).count
        confirmation = Confirmation(
            title: L10n.f("delete.title", group.name),
            message: childCount > 0 ? L10n.f("delete.message.children", childCount) : L10n.t("delete.message"),
            confirmTitle: L10n.t("action.delete"),
            isDestructive: true
        ) { [weak self] in self?.delete(id) }
    }

    func delete(_ id: UUID) {
        guard let doomed = GroupTree.first(id, in: groups), !doomed.isSystem else { return }
        let visible = GroupTree.flatten(groups)
        let index = visible.firstIndex { $0.id == id }
        let next = index.flatMap { index in index + 1 < visible.count ? visible[index + 1].id : nil }
            ?? index.flatMap { $0 > 0 ? visible[$0 - 1].id : nil }
            ?? systemID

        for removed in GroupTree.all([doomed]) { drafts[removed.id] = nil }
        _ = GroupTree.remove(id, from: &groups)
        if selectedID.map({ !GroupTree.contains($0, in: groups) }) == true { select(next) }
        persist()
        apply()
    }

    func move(draggedID: UUID, to targetID: UUID, placement: GroupTree.DropPlacement) {
        self.draggingID = nil
        if GroupTree.move(draggedID, relativeTo: targetID, placement: placement, in: &groups) {
            persist()
            apply()
        }
    }

    func canMove(draggedID: UUID, to targetID: UUID, placement: GroupTree.DropPlacement) -> Bool {
        GroupTree.canMove(draggedID, relativeTo: targetID, placement: placement, in: groups)
    }

    // MARK: The hosts file

    /// Rebuilds the hosts file from the groups and writes it.
    func apply() {
        guard hasStarted else { return }
        refreshConflicts()
        if isApplying {
            applyQueued = true
            return
        }
        isApplying = true
        applyPhase = .applying
        Task { @MainActor in
            repeat {
                applyQueued = false
                await performApply()
            } while applyQueued
            isApplying = false
        }
    }

    private func performApply() async {
        guard canApply else {
            hasPendingChanges = true
            applyPhase = .idle
            if privilege == .canceled { showAuthorizationHint(L10n.t("hint.unsaved")) }
            return
        }

        let current = Self.readHosts(at: paths.hostsURL)
        var systemContent = text(for: systemID)
        var notice: String?

        // Another program may have rewritten the file since the app last did. If it only
        // touched the part the app does not manage and the user has not edited that part
        // either, keep the outside change instead of quietly undoing it.
        //
        // Only for a file the app has written: a file that was merely imported on first
        // launch has no managed part yet, and all of it belongs to the imported groups.
        if let current, let known = lastApplied, known.wasWritten {
            let outside = HostsFile.parse(current).systemContent
            if outside != known.systemContent {
                if systemContent == known.systemContent {
                    systemContent = outside
                    _ = GroupTree.modify(systemID, in: &groups) { $0.content = outside }
                    drafts[systemID] = nil
                } else {
                    notice = L10n.t("notice.baseConflict")
                }
            }
        }

        let target = HostsFile.compose(systemContent: systemContent, groups: groups)
        let now = Date()
        if current == target {
            lastApplied = LastApplied(fileSHA256: Digest.sha256Hex(target), systemContent: systemContent, date: now,
                                      wasWritten: lastApplied?.wasWritten ?? false)
            applyPhase = .applied(now)
            persist()
            return
        }

        if settings.snapshotBeforeApply, let current, !current.isEmpty {
            do {
                try SnapshotStore.save(current, to: paths.historyDirectory)
                SnapshotStore.prune(in: paths.historyDirectory, keep: settings.snapshotLimit)
            } catch {
                // A failed backup is worth mentioning but must not stop the write.
                notice = L10n.t("notice.snapshotFailed")
            }
        }

        do {
            try await session.writeHosts(Data(target.utf8))
            if let written = Self.readHosts(at: paths.hostsURL), written != target {
                throw PrivilegeError.rejected("VERIFY")
            }
            if settings.flushDNSCache {
                try? await session.flushDNS()
            }
            lastApplied = LastApplied(fileSHA256: Digest.sha256Hex(target), systemContent: systemContent, date: Date(), wasWritten: true)
            writeCount += 1
            hasPendingChanges = false
            applyPhase = .applied(Date())
            if let hint, hint.kind == .applyError { self.hint = nil }
            if let notice { showTransient(Hint(kind: .notice, style: .warning, text: notice)) }
        } catch let error as PrivilegeError {
            switch error {
            case .canceled:
                privilege = .canceled
                applyPhase = .idle
                showAuthorizationHint(L10n.t("hint.unsaved"))
            case .helperStopped, .notRunning, .helperUnavailable, .timedOut:
                // The session is gone; ask for the password again and pick up where we left off.
                hasPendingChanges = true
                applyPhase = .idle
                requestPrivilege()
            default:
                hasPendingChanges = true
                applyPhase = .failed(error.message)
            }
        } catch {
            hasPendingChanges = true
            applyPhase = .failed(error.localizedDescription)
        }
        persist()
    }

    func retryApply() {
        if case .failed = privilege { requestPrivilege() } else { apply() }
    }

    func refreshConflicts() {
        conflicts = HostsFile.conflicts(
            systemContent: text(for: systemID),
            systemGroupName: systemGroup?.name ?? "",
            groups: groups
        )
    }

    /// Puts Apple's stock `localhost` lines into the system group and applies right away.
    func insertDefaultSystemEntries() {
        let existing = text(for: systemID).trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = existing.isEmpty
            ? HostsFile.defaultSystemContent
            : HostsFile.tidy(existing) + "\n\n" + HostsFile.defaultSystemContent
        _ = GroupTree.modify(systemID, in: &groups) { $0.content = merged }
        drafts[systemID] = nil
        persist()
        apply()
    }

    func askToImportCurrentFile() {
        confirmation = Confirmation(
            title: L10n.t("import.confirm.title"),
            message: L10n.t("import.confirm.message"),
            confirmTitle: L10n.t("action.import"),
            isDestructive: false
        ) { [weak self] in
            guard let self, let text = Self.readHosts(at: self.paths.hostsURL) else { return }
            self.performImport(text)
        }
    }

    /// Makes the groups describe the hosts file as it is right now. Nothing is written: after
    /// this the store and the file agree.
    private func performImport(_ text: String) {
        let changed = HostsImporter.merge(text, into: &groups, importedGroupName: L10n.t("group.imported.name"))
        for id in changed { drafts[id] = nil }
        lastApplied = LastApplied(
            fileSHA256: Digest.sha256Hex(text),
            systemContent: systemGroup?.content ?? "",
            date: Date()
        )
        hint = nil
        persist()
        refreshConflicts()
    }

    func restore(_ snapshot: Snapshot) {
        guard let text = SnapshotStore.content(of: snapshot) else { return }
        let changed = HostsImporter.merge(text, into: &groups, importedGroupName: L10n.t("group.imported.name"))
        for id in changed { drafts[id] = nil }
        sheet = nil
        persist()
        apply()
    }

    func requestRestore(_ snapshot: Snapshot) {
        confirmation = Confirmation(
            title: L10n.t("history.restore.title"),
            message: L10n.t("history.restore.message"),
            confirmTitle: L10n.t("action.restore"),
            isDestructive: false
        ) { [weak self] in self?.restore(snapshot) }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        persist()
    }

    func toggleSidebar() {
        isSidebarHidden.toggle()
        defaults.set(isSidebarHidden, forKey: Keys.sidebarHidden)
    }

    /// Opens the sidebar search and puts the cursor in its field.
    func focusSearch() {
        if isSidebarHidden { toggleSidebar() }
        isSearchVisible = true
        searchFocusRequest += 1
    }

    /// Starts a new group nested under the selected one.
    func beginNewChildGroup() {
        let parent = selectedGroup
        sheet = .newGroup(parentID: parent?.isSystem == false ? parent?.id : nil)
    }

    /// Used on quit: applies whatever is still outstanding and returns once that is done,
    /// successfully or not. Nothing further could be done about a failure at that point.
    func finishPendingWork() async {
        guard hasStarted else { return }
        while isApplying { try? await Task.sleep(for: .milliseconds(50)) }
        refreshConflicts()
        await performApply()
    }

    var savedWindowFrame: NSRect? {
        defaults.string(forKey: Keys.windowFrame).map(NSRectFromString)
    }

    func rememberWindowFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: Keys.windowFrame)
    }

    // MARK: Banners

    func dismissHint() {
        hint = nil
    }

    private func showTransient(_ new: Hint) {
        show(new)
        hintDismissal?.cancel()
        hintDismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let hint = self.hint, hint.id == new.id else { return }
            self.hint = nil
        }
    }

    private func show(_ new: Hint) {
        if let current = hint, current.kind.isSticky, !new.kind.isSticky { return }
        hint = new
    }

    // MARK: Persistence

    private func persist() {
        do {
            try Store.save(document, to: paths.storeURL)
        } catch {
            show(Hint(kind: .notice, style: .error, text: L10n.f("error.saveSettings", error.localizedDescription)))
        }
    }

    private static func readHosts(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension PrivilegedSession {
    func writeHosts(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writeHosts(data) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    func flushDNS() async throws {
        try await withCheckedThrowingContinuation { continuation in
            flushDNS { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }
}
