import Foundation

/// Bringing an existing hosts file into the group tree: on the very first launch, when the
/// user asks for it after another program rewrote the file, and when restoring a snapshot.
public enum HostsImporter {
    /// Groups for a store that does not exist yet.
    ///
    /// A file that already carries our markers (the store was lost) is taken apart block by
    /// block. A plain file is split into Apple's stock lines and everything else, which
    /// becomes a switched-on group of its own, so nothing the user had stops working.
    public static func initialGroups(
        fromHosts text: String,
        systemGroupName: String,
        importedGroupName: String
    ) -> [HostGroup] {
        let parsed = HostsFile.parse(text)
        var groups = [HostGroup.system(content: parsed.systemContent, name: systemGroupName)]

        if parsed.blocks.isEmpty {
            let (system, remaining) = HostsFile.splitUnmanaged(text)
            groups[0].content = system
            if !remaining.isEmpty {
                groups.append(HostGroup(name: importedGroupName, enabled: true, content: remaining))
            }
        } else {
            groups += parsed.blocks.map { block in
                HostGroup(name: displayName(for: block.name, fallback: "Hosts"), enabled: true, content: block.content)
            }
        }
        return groups
    }

    /// Makes the tree describe `text` exactly as it is: groups found in the file take the
    /// file's content and are switched on, the others are switched off, and anything the
    /// file holds that no group claims is added. Returns the ids of the groups that changed.
    @discardableResult
    public static func merge(
        _ text: String,
        into groups: inout [HostGroup],
        importedGroupName: String
    ) -> Set<UUID> {
        let before = groups
        let parsed = HostsFile.parse(text)
        let systemName = groups.first(where: { $0.isSystem })?.name ?? "System Hosts"
        ensureSystemGroup(in: &groups, named: systemName)
        groups[0].content = parsed.systemContent

        if parsed.blocks.isEmpty {
            // Never written by the app (or rewritten wholesale): treat it like a first import.
            for index in groups.indices where !groups[index].isSystem {
                groups[index].enabled = false
            }
            let remaining = HostsFile.splitUnmanaged(text).remaining
            if !remaining.isEmpty {
                groups.append(HostGroup(name: importedGroupName, enabled: true, content: remaining))
            }
        } else {
            for group in GroupTree.all(groups) where !group.isSystem {
                if let block = parsed.blocks.first(where: { $0.id == group.shortID }) {
                    _ = GroupTree.modify(group.id, in: &groups) { $0.content = block.content; $0.enabled = true }
                } else {
                    _ = GroupTree.modify(group.id, in: &groups) { $0.enabled = false }
                }
            }
            let known = Set(GroupTree.all(groups).map(\.shortID))
            groups += parsed.blocks.filter { !known.contains($0.id) }.map { block in
                HostGroup(name: displayName(for: block.name, fallback: "Hosts"), enabled: true, content: block.content)
            }
        }

        var changed = Set<UUID>()
        for (old, new) in zip(GroupTree.all(before), GroupTree.all(groups)) where old != new {
            changed.insert(old.id)
        }
        let oldIDs = Set(GroupTree.all(before).map(\.id))
        changed.formUnion(GroupTree.all(groups).map(\.id).filter { !oldIDs.contains($0) })
        return changed
    }

    private static func ensureSystemGroup(in groups: inout [HostGroup], named name: String) {
        if let index = groups.firstIndex(where: { $0.isSystem }) {
            if index != 0 { groups.swapAt(0, index) }
        } else {
            groups.insert(HostGroup.system(content: "", name: name), at: 0)
        }
    }

    /// The marker carries the full path ("Project / Web"); a group only needs its own name.
    private static func displayName(for markerName: String, fallback: String) -> String {
        let last = markerName.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return last.nilIfEmpty ?? fallback
    }
}
