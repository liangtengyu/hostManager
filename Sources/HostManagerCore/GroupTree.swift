import Foundation

/// Reading and editing the group tree. Everything here is value semantics: callers mutate
/// a `[HostGroup]` they own and persist the result.
public enum GroupTree {
    /// Where a dragged group lands relative to the row it was dropped on.
    public enum DropPlacement: Equatable, Sendable {
        case before, after, inside
    }

    public struct Node: Identifiable, Equatable, Sendable {
        public let group: HostGroup
        public let depth: Int
        public let path: [Int]
        /// True when the group is switched on and so is every ancestor.
        public let isActive: Bool
        public var id: UUID { group.id }
    }

    /// Depth-first list of the groups that should be visible.
    ///
    /// Without `matching`, children only appear under expanded parents. With `matching`,
    /// a group is kept when it or any descendant matches, and ancestors are always expanded
    /// so the hits stay in context.
    public static func flatten(
        _ groups: [HostGroup],
        matching: ((HostGroup) -> Bool)? = nil
    ) -> [Node] {
        var nodes: [Node] = []
        walk(groups, depth: 0, basePath: [], ancestorsActive: true, matching: matching, into: &nodes)
        return nodes
    }

    private static func hasMatch(_ group: HostGroup, _ matching: (HostGroup) -> Bool) -> Bool {
        matching(group) || group.children.contains { hasMatch($0, matching) }
    }

    private static func walk(
        _ groups: [HostGroup],
        depth: Int,
        basePath: [Int],
        ancestorsActive: Bool,
        matching: ((HostGroup) -> Bool)?,
        into nodes: inout [Node]
    ) {
        for (index, group) in groups.enumerated() {
            if let matching, !hasMatch(group, matching) { continue }
            let active = ancestorsActive && (group.enabled || group.isSystem)
            nodes.append(Node(group: group, depth: depth, path: basePath + [index], isActive: active))
            // While searching, collapsed parents open up so their hits can be seen.
            if matching != nil || group.isExpanded {
                walk(group.children, depth: depth + 1, basePath: basePath + [index],
                     ancestorsActive: active, matching: matching, into: &nodes)
            }
        }
    }

    /// Every group in pre-order.
    public static func all(_ groups: [HostGroup]) -> [HostGroup] {
        flatten(groups).map(\.group)
    }

    public static func first(_ id: UUID, in groups: [HostGroup]) -> HostGroup? {
        for group in groups {
            if group.id == id { return group }
            if let found = first(id, in: group.children) { return found }
        }
        return nil
    }

    public static func contains(_ id: UUID, in groups: [HostGroup]) -> Bool {
        first(id, in: groups) != nil
    }

    /// Index path from the root, e.g. `[2, 0]` is the first child of the third top-level group.
    public static func path(to id: UUID, in groups: [HostGroup]) -> [Int]? {
        flatten(groups).first { $0.id == id }?.path
    }

    public static func depth(of id: UUID, in groups: [HostGroup]) -> Int {
        path(to: id, in: groups)?.count ?? 0
    }

    /// Root-first list of the groups the given group is nested under.
    public static func ancestors(of id: UUID, in groups: [HostGroup]) -> [HostGroup] {
        var chain: [HostGroup] = []
        func descend(_ siblings: [HostGroup]) -> Bool {
            for group in siblings {
                if group.id == id { return true }
                if descend(group.children) {
                    chain.append(group)
                    return true
                }
            }
            return false
        }
        _ = descend(groups)
        return chain.reversed()
    }

    public static func parent(of id: UUID, in groups: [HostGroup]) -> HostGroup? {
        ancestors(of: id, in: groups).last
    }

    public static func isDescendant(_ id: UUID, of ancestorID: UUID, in groups: [HostGroup]) -> Bool {
        guard id != ancestorID else { return false }
        return ancestors(of: id, in: groups).contains { $0.id == ancestorID }
    }

    /// Names from the root down to the group, joined with " / ".
    public static func namePath(of id: UUID, in groups: [HostGroup]) -> String {
        (ancestors(of: id, in: groups) + [first(id, in: groups)].compactMap { $0 })
            .map(\.name)
            .joined(separator: " / ")
    }

    @discardableResult
    public static func modify(
        _ id: UUID,
        in groups: inout [HostGroup],
        _ change: (inout HostGroup) -> Void
    ) -> Bool {
        for index in groups.indices {
            if groups[index].id == id {
                change(&groups[index])
                return true
            }
            if modify(id, in: &groups[index].children, change) { return true }
        }
        return false
    }

    /// Removes the group together with its children and returns it.
    @discardableResult
    public static func remove(_ id: UUID, from groups: inout [HostGroup]) -> HostGroup? {
        for index in groups.indices {
            if groups[index].id == id { return groups.remove(at: index) }
            if let removed = remove(id, from: &groups[index].children) { return removed }
        }
        return nil
    }

    /// Whether moving `draggedID` to `placement` relative to `targetID` changes anything.
    public static func canMove(
        _ draggedID: UUID,
        relativeTo targetID: UUID,
        placement: DropPlacement,
        in groups: [HostGroup]
    ) -> Bool {
        var copy = groups
        return move(draggedID, relativeTo: targetID, placement: placement, in: &copy)
    }

    /// Moves a group. Returns false (leaving `groups` untouched) when the move is illegal or
    /// would not change the tree: the system group stays first and nothing can land inside
    /// its own subtree.
    @discardableResult
    public static func move(
        _ draggedID: UUID,
        relativeTo targetID: UUID,
        placement: DropPlacement,
        in groups: inout [HostGroup]
    ) -> Bool {
        guard draggedID != targetID,
              let dragged = first(draggedID, in: groups), !dragged.isSystem,
              let target = first(targetID, in: groups),
              !(placement == .inside && target.isSystem),
              !isDescendant(targetID, of: draggedID, in: groups)
        else { return false }

        let before = groups
        guard let removed = remove(draggedID, from: &groups) else { groups = before; return false }

        if placement == .inside {
            guard modify(targetID, in: &groups, { $0.children.append(removed); $0.isExpanded = true }) else {
                groups = before; return false
            }
        } else {
            guard let path = path(to: targetID, in: groups),
                  first(targetID, in: groups)?.isSystem == false
            else { groups = before; return false }
            var insertion = path
            insertion[insertion.count - 1] += placement == .after ? 1 : 0
            insert(removed, at: insertion, into: &groups)
        }

        // Dropping a group right next to where it already was is a no-op; say so instead of
        // making the caller persist and re-apply an identical file.
        guard groups != before else { groups = before; return false }
        return true
    }

    private static func insert(_ group: HostGroup, at path: [Int], into siblings: inout [HostGroup]) {
        if path.count == 1, path[0] <= siblings.count {
            siblings.insert(group, at: path[0])
        } else if let head = path.first, head < siblings.count {
            insert(group, at: Array(path.dropFirst()), into: &siblings[head].children)
        } else {
            siblings.append(group)
        }
    }
}
