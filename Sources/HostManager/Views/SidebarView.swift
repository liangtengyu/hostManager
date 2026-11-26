import AppKit
import SwiftUI
import HostManagerCore

/// Where a group being dragged is about to land.
struct DropHint: Equatable {
    let targetID: UUID
    let placement: GroupTree.DropPlacement
}

/// The group list. Plain views in a scroll view rather than a List: the rows are few, and it
/// takes full control of the look (the tinted selection, the switch on every row) and of
/// dragging groups onto and into each other.
@MainActor
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var dropHint: DropHint?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearchVisible {
                SidebarSearchField(onEscape: exitSearch)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visibleNodes) { node in
                        SidebarRow(node: node, dropHint: $dropHint) { isListFocused = true }
                    }
                    if model.visibleNodes.isEmpty {
                        Text(L10n.t("sidebar.noMatches"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(1) }
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .onKeyPress(.return) {
                guard let group = model.selectedGroup else { return .ignored }
                if group.hasChildren {
                    model.toggleExpanded(group.id)
                } else if !group.isSystem {
                    model.sheet = .rename(group.id)
                }
                return .handled
            }
            .onKeyPress(.delete) {
                guard let group = model.selectedGroup, !group.isSystem else { return .ignored }
                model.requestDelete(group.id)
                return .handled
            }
        }
        .animation(.snappy(duration: 0.2), value: model.visibleNodes.map(\.id))
        .onChange(of: model.isSearchVisible) { _, visible in
            if !visible { model.searchText = "" }
        }
    }

    private func moveSelection(_ step: Int) -> KeyPress.Result {
        let nodes = model.visibleNodes
        guard let current = nodes.firstIndex(where: { $0.id == model.selectedID }) else { return .ignored }
        let next = min(max(current + step, nodes.startIndex), nodes.index(before: nodes.endIndex))
        guard next != current else { return .handled }
        model.select(nodes[next].id)
        return .handled
    }

    private func exitSearch() {
        model.searchText = ""
        withAnimation(.snappy(duration: 0.2)) { model.isSearchVisible = false }
    }
}

// MARK: - Search

@MainActor
struct SidebarSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.t("sidebar.searchPrompt"), text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isFocused)
                .onSubmit(chooseFirstMatch)
                .onExitCommand(perform: onEscape)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("action.clear"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(isFocused ? 0.3 : 0.1)))
        .onAppear { isFocused = true }
        .onChange(of: model.isSearchVisible) { _, visible in if visible { isFocused = true } }
        .onChange(of: model.searchFocusRequest) { isFocused = true }
    }

    private func chooseFirstMatch() {
        if let first = model.visibleNodes.first { model.select(first.id) }
    }
}

// MARK: - Rows

@MainActor
struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let node: GroupTree.Node
    @Binding var dropHint: DropHint?
    let onFocusRequest: () -> Void
    @State private var isHovering = false

    private static let rowHeight: CGFloat = 28

    private var isSelected: Bool { model.selectedID == node.id }
    /// Switched on, but an ancestor is not: nothing in it is live until that changes.
    private var isDimmed: Bool { node.group.enabled && !node.isActive }

    private var symbol: String {
        if !node.group.icon.isEmpty { return node.group.icon }
        return node.group.hasChildren ? "folder" : "doc.text"
    }

    var body: some View {
        HStack(spacing: 6) {
            disclosure
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 16)
            Text(node.group.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            if model.hasUnsavedChanges(for: node.id) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
            }
            Spacer(minLength: 2)
            if !node.group.isSystem {
                CompactToggle(isOn: node.group.enabled, identifier: "toggle.\(node.group.shortID)") {
                    model.setEnabled(node.id, !node.group.enabled)
                }
            }
        }
        .foregroundStyle(isSelected ? Theme.accent : Color.primary)
        .opacity(isDimmed ? 0.5 : 1)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.rowSelection : (isHovering ? Theme.rowHover : Color.clear))
        )
        .overlay { dropIndicator }
        .padding(.leading, CGFloat(node.depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture {
            onFocusRequest()
            // Two clicks on the same row in quick succession, recognised here rather than by
            // a two-tap gesture so that it behaves the same however the clicks arrive.
            if model.clickGroup(node.id) { handleDoubleClick() }
        }
        // A named container, so the row's name does not replace its children's identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group.\(node.group.shortID)")
        .onHover { isHovering = $0 }
        .contextMenu { menuItems }
        .onDrag {
            model.draggingID = node.id
            return NSItemProvider(object: node.id.uuidString as NSString)
        }
        .onDrop(of: [.utf8PlainText], delegate: GroupDropDelegate(
            model: model, target: node, rowHeight: Self.rowHeight, hint: $dropHint
        ))
    }

    @ViewBuilder private var disclosure: some View {
        if node.group.hasChildren {
            Button {
                onFocusRequest()
                model.select(node.id)
                model.toggleExpanded(node.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .rotationEffect(.degrees(node.group.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(node.group.isExpanded ? L10n.t("a11y.collapse") : L10n.t("a11y.expand"))
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    /// Shows where the dragged group would land before it is let go.
    @ViewBuilder private var dropIndicator: some View {
        if let dropHint, dropHint.targetID == node.id {
            switch dropHint.placement {
            case .before:
                Rectangle().fill(Theme.accent).frame(height: 2).frame(maxHeight: .infinity, alignment: .top)
            case .after:
                Rectangle().fill(Theme.accent).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
            case .inside:
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
    }

    private func handleDoubleClick() {
        if node.group.hasChildren {
            model.toggleExpanded(node.id)
        } else if !node.group.isSystem {
            model.sheet = .rename(node.id)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if node.group.isSystem {
            Button(L10n.t("menu.newGroup")) {
                model.select(node.id)
                model.sheet = .newGroup(parentID: nil)
            }
            Button(L10n.t("action.insertDefault")) { model.insertDefaultSystemEntries() }
        } else {
            Button(L10n.t("menu.newChild")) {
                model.select(node.id)
                model.sheet = .newGroup(parentID: node.id)
            }
            Divider()
            Button(L10n.t("menu.rename")) {
                model.select(node.id)
                model.sheet = .rename(node.id)
            }
            if node.group.hasChildren {
                Button(node.group.isExpanded ? L10n.t("a11y.collapse") : L10n.t("a11y.expand")) {
                    model.toggleExpanded(node.id)
                }
            }
            Divider()
            Button(L10n.t("menu.delete")) {
                model.select(node.id)
                model.requestDelete(node.id)
            }
        }
    }
}

/// Turns pointer position into an insertion point and asks the model whether the move is legal.
struct GroupDropDelegate: DropDelegate {
    let model: AppModel
    let target: GroupTree.Node
    let rowHeight: CGFloat
    @Binding var hint: DropHint?

    func dropEntered(info: DropInfo) { refresh(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        refresh(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hint?.targetID == target.id { hint = nil }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = model.draggingID else { return false }
        return model.canMove(draggedID: dragged, to: target.id, placement: placement(for: info))
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = model.draggingID, validateDrop(info: info) else { return false }
        hint = nil
        model.move(draggedID: dragged, to: target.id, placement: placement(for: info))
        return true
    }

    /// Along the edges a drop goes before or after the row; over the middle of the row it
    /// goes into the group. The system group stays first, so around it everything is "after".
    private func placement(for info: DropInfo) -> GroupTree.DropPlacement {
        guard !target.group.isSystem else { return .after }
        let y = info.location.y / rowHeight
        if y < 0.28 { return .before }
        if y > 0.72 { return .after }
        return .inside
    }

    private func refresh(_ info: DropInfo) {
        let legal = validateDrop(info: info)
        if legal {
            hint = DropHint(targetID: target.id, placement: placement(for: info))
        } else if hint?.targetID == target.id {
            hint = nil
        }
    }
}
