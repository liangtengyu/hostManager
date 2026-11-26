import AppKit
import SwiftUI
import HostManagerCore

/// Finds the NSWindow hosting a SwiftUI view, for the few things that need the real window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> Observer {
        let view = Observer()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: Observer, context: Context) {}

    final class Observer: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// The whole window: an icon rail, the group list and the editor of the selected group.
///
/// The title bar is transparent and the content runs underneath it, so the sidebar material
/// reaches the top of the window the way it does in Finder or Notes. The strip under the
/// title bar is reserved by hand and holds the two controls that belong next to the
/// traffic lights.
@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    @State private var windowObservers: [NSObjectProtocol] = []
    @State private var closeGuard: WindowCloseGuard?

    private let railWidth: CGFloat = 36
    private let sidebarWidth: CGFloat = 236

    var body: some View {
        GeometryReader { proxy in
            let titleBarHeight = proxy.safeAreaInsets.top
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    column(width: railWidth, titleBarHeight: titleBarHeight) { RailView() }
                    if !model.isSidebarHidden {
                        column(width: sidebarWidth, titleBarHeight: titleBarHeight) { SidebarView() }
                            .transition(.move(edge: .leading))
                    }
                    VStack(spacing: 0) {
                        Color.clear.frame(height: titleBarHeight)
                        GroupDetailView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.editorBackground)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    }
                }

                TitlebarControls()
                    .padding(.leading, 82)
                    .frame(height: titleBarHeight, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
            .animation(.snappy(duration: 0.22), value: model.isSidebarHidden)
        }
        .background(WindowReader { attach($0) })
        .onAppear { model.start() }
        .onChange(of: model.selectedID) { if let window { updateWindow(window) } }
        .onChange(of: model.hasUnsavedChanges) { if let window { updateWindow(window) } }
        .onChange(of: model.groups) { if let window { updateWindow(window) } }
        .sheet(item: Binding(get: { model.sheet }, set: { model.sheet = $0 })) { sheet in
            SheetRouter(sheet: sheet)
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(
            get: { model.confirmation != nil },
            set: { if !$0 { model.confirmation = nil } }
        ), presenting: model.confirmation) { confirmation in
            Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil, action: confirmation.action)
            Button(L10n.t("action.cancel"), role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private func column(width: CGFloat, titleBarHeight: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: titleBarHeight)
            content()
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }

    // MARK: Window

    private func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Not during a view update.
        DispatchQueue.main.async { self.configure(window) }
    }

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        closeGuard = WindowCloseGuard(model: model, previous: window.delegate)
        window.delegate = closeGuard
        if let frame = model.savedWindowFrame {
            window.setFrame(window.constrainFrameRect(frame, to: nil), display: false)
        }
        let center = NotificationCenter.default
        let model = self.model
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                // Posted on the main queue; `assumeIsolated` only tells the compiler so.
                MainActor.assumeIsolated {
                    if let window { model.rememberWindowFrame(window.frame) }
                }
            })
        }
        updateWindow(window)
    }

    private func updateWindow(_ window: NSWindow) {
        window.title = model.selectedGroup?.name ?? "HostManager"
        // Puts the "unsaved" dot in the window's close button, like a document.
        window.isDocumentEdited = model.hasUnsavedChanges
    }
}

/// The two controls that sit in the title bar next to the traffic lights.
@MainActor
struct TitlebarControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            IconButton(identifier: "titlebar.sidebar", symbol: "sidebar.leading", tooltip: L10n.t("rail.sidebar"), isActive: !model.isSidebarHidden) {
                model.toggleSidebar()
            }
            IconButton(identifier: "titlebar.new", symbol: "plus", tooltip: L10n.t("menu.newGroup")) {
                model.sheet = .newGroup(parentID: nil)
            }
        }
    }
}

/// The narrow strip on the far left: the app's handful of commands.
@MainActor
struct RailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 7) {
            IconButton(identifier: "rail.sidebar", symbol: "line.3.horizontal", tooltip: L10n.t("rail.sidebar"), isActive: !model.isSidebarHidden) {
                model.toggleSidebar()
            }
            IconButton(identifier: "rail.search", symbol: "magnifyingglass", tooltip: L10n.t("rail.search"), isActive: model.isSearchVisible) {
                withAnimation(.snappy(duration: 0.2)) { model.isSearchVisible.toggle() }
            }
            IconButton(identifier: "rail.history", symbol: "clock.arrow.circlepath", tooltip: L10n.t("rail.history")) {
                model.sheet = .history
            }
            Spacer(minLength: 0)
            IconButton(identifier: "rail.delete", symbol: "trash", tooltip: L10n.t("rail.delete"),
                       isEnabled: model.selectedGroup?.isSystem == false) {
                if let id = model.selectedID { model.requestDelete(id) }
            }
            IconButton(identifier: "rail.settings", symbol: "gearshape", tooltip: L10n.t("settings.title")) {
                model.sheet = .settings
            }
        }
        .padding(.vertical, 8)
    }
}

/// Opens whichever sheet is pending.
@MainActor
struct SheetRouter: View {
    @Environment(AppModel.self) private var model
    let sheet: Sheet

    var body: some View {
        switch sheet {
        case .newGroup(let parentID):
            GroupEditorSheet(mode: .create(parent: parentID.flatMap { GroupTree.first($0, in: model.groups) }))
        case .rename(let id):
            if let group = GroupTree.first(id, in: model.groups) {
                GroupEditorSheet(mode: .rename(group))
            } else {
                ContentUnavailableView(L10n.t("empty.title"), systemImage: "doc.text")
            }
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .conflicts:
            ConflictsView()
        }
    }
}
