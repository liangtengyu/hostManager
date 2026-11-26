import AppKit

/// Asking what to do with unsaved edits before the window closes or the app quits.
enum QuitGuard {
    /// Asks what to do with unsaved edits, unless there are none. `proceed` is called with
    /// true once it is fine to go on (after saving, if that was chosen) and false if the user
    /// cancelled.
    ///
    /// The question is a sheet, not a blocking modal loop: the window stays responsive and
    /// the answer arrives in a completion, which is also what `applicationShouldTerminate`
    /// wants when it answers `.terminateLater`.
    @MainActor
    static func confirmUnsavedChanges(model: AppModel, on window: NSWindow, proceed: @escaping @MainActor (Bool) -> Void) {
        guard model.hasUnsavedChanges else {
            proceed(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("quit.title")
        alert.informativeText = L10n.t("quit.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("quit.save"))
        alert.addButton(withTitle: L10n.t("quit.discard"))
        alert.addButton(withTitle: L10n.t("quit.cancel"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                model.commitAllDrafts()
                Task { @MainActor in
                    await model.finishPendingWork()
                    proceed(true)
                }
            case .alertSecondButtonReturn:
                model.discardAllDrafts()
                proceed(true)
            default:
                proceed(false)
            }
        }
    }
}

/// Stands in for the window's delegate to get a say before the window closes. The app quits
/// when its window closes, and by the time AppKit asks about quitting the window, and with it
/// the edits, would already be gone; so the question is asked here instead.
///
/// Everything else is passed on to SwiftUI's own delegate.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private weak var previous: NSWindowDelegate?

    init(model: AppModel, previous: NSWindowDelegate?) {
        self.model = model
        self.previous = previous
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.hasUnsavedChanges else { return true }
        QuitGuard.confirmUnsavedChanges(model: model, on: sender) { proceed in
            // `close()` does not ask again, so this cannot loop.
            if proceed { sender.close() }
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || previous?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        previous
    }
}
