import AppKit
import SwiftUI
import HostManagerCore

/// The menu bar.
struct HostManagerCommands: Commands {
    let model: AppModel

    /// `Commands.body` is not main-actor isolated in this SDK; SwiftUI still only evaluates
    /// it on the main thread, so say so rather than loosen the model.
    nonisolated var body: some Commands {
        MainActor.assumeIsolated { content }
    }

    @CommandsBuilder
    @MainActor private var content: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("menu.newGroup")) { model.sheet = .newGroup(parentID: nil) }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("menu.newChild")) { model.beginNewChildGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.selectedGroup == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("action.save")) { model.saveSelected() }
                .keyboardShortcut("s", modifiers: .command)
        }
        // This SDK has no placement for the Edit menu's Find submenu, so ⌘F is claimed here
        // and the stock submenu is removed from the menu after launch (see StockMenu).
        CommandGroup(after: .sidebar) {
            Button(L10n.t("rail.search")) { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button(L10n.t("rail.history")) { model.sheet = .history }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button(L10n.t("settings.title")) { model.sheet = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(L10n.t("menu.group")) {
            Button(L10n.t("menu.toggle")) { model.toggleSelected() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedGroup?.isSystem != false)
            Divider()
            Button(L10n.t("menu.rename")) {
                if let id = model.selectedID { model.sheet = .rename(id) }
            }
            .disabled(model.selectedGroup?.isSystem != false)
            Button(L10n.t("menu.delete")) {
                if let id = model.selectedID { model.requestDelete(id) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedGroup?.isSystem != false)
        }
    }
}

/// Adjustments to the menu bar SwiftUI builds on its own.
enum StockMenu {
    /// The stock Edit menu comes with a Find submenu whose items do nothing here (searching
    /// lives in the sidebar) and whose ⌘F and ⌘E collide with this app's shortcuts.
    ///
    /// SwiftUI builds the menu bar lazily and may rebuild it, so this is cheap to call often.
    @MainActor
    static func removeFindSubmenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let menu = topItem.submenu else { continue }
            // The Edit menu is the one that holds Undo.
            let holdsUndo = menu.items.contains { $0.action == Selector(("undo:")) }
            guard holdsUndo else { continue }
            for item in menu.items {
                if let submenu = item.submenu, submenu.items.contains(where: usesCommandE) {
                    menu.removeItem(item)
                }
            }
        }
    }

    /// "Use Selection for Find" (⌘E) is what gives the Find submenu away, whatever the language.
    private static func usesCommandE(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "e" && item.keyEquivalentModifierMask == .command
    }
}
