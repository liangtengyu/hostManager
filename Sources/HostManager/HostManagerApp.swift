import AppKit
import SwiftUI
import HostManagerCore

@main
struct HostManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .frame(minWidth: 680, minHeight: 420)
        }
        .defaultSize(width: 920, height: 540)
        .windowResizability(.contentMinSize)
        .commands { HostManagerCommands(model: appDelegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var menuObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a helper that has just died must come back as an error, not end the app.
        signal(SIGPIPE, SIG_IGN)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI builds the menu bar lazily. Prune it once it exists and again whenever a
        // menu opens, in case it gets rebuilt.
        Task { @MainActor in StockMenu.removeFindSubmenu() }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { StockMenu.removeFindSubmenu() } }
    }

    /// A tool, not a daemon: closing the window is quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved edits that reached this point belong to a window that is already gone
        // (closing the window asks first; see WindowCloseGuard). Keep them rather than lose them.
        guard model.hasUnsavedChanges else { return .terminateNow }
        guard let window = NSApp.windows.first(where: { !$0.isSheet && $0.isVisible }) else {
            model.commitAllDrafts()
            return .terminateNow
        }
        QuitGuard.confirmUnsavedChanges(model: model, on: window) { ok in
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
