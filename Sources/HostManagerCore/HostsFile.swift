import Foundation

/// A block of the hosts file that belongs to one group, bounded by our markers.
public struct ManagedBlock: Equatable, Sendable {
    /// The short id from the marker, or empty when the marker carries none.
    public let id: String
    /// The group path written in the marker, e.g. "Project Environments / Website Preview".
    public let name: String
    public let content: String

    public init(id: String, name: String, content: String) {
        self.id = id
        self.name = name
        self.content = content
    }
}

public struct ParsedHostsFile: Equatable, Sendable {
    /// Everything outside our markers, i.e. what the built-in system group holds.
    public var systemContent: String
    public var blocks: [ManagedBlock]
}

public struct HostnameMapping: Hashable, Sendable {
    public let groupID: UUID
    public let groupName: String
    public let address: String
}

/// One hostname that active groups point at different addresses. The first mapping in file
/// order is the one the system resolves.
public struct HostnameConflict: Identifiable, Equatable, Sendable {
    public let hostname: String
    public let mappings: [HostnameMapping]
    public var id: String { hostname }
}

/// Turning groups back into a hosts file and reading one apart again.
///
/// The file is laid out as: the system group's content first, then one marked block per
/// active group that has content, e.g.
///
///     # >>> HostManager: Local Development [3f2a9c1b] >>>
///     127.0.0.1	app.example.test
///     # <<< HostManager: Local Development [3f2a9c1b] <<<
///
/// Disabled groups are simply absent, so switching one off and applying makes the file
/// look exactly as if the group had never existed.
public enum HostsFile {
    public static let beginPrefix = "# >>> HostManager: "
    public static let beginSuffix = " >>>"
    public static let endPrefix = "# <<< HostManager: "
    public static let endSuffix = " <<<"

    public struct Marker: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public static func compose(systemContent: String, groups: [HostGroup]) -> String {
        var sections: [String] = []
        let system = tidy(systemContent)
        if !system.isEmpty { sections.append(system) }

        for node in GroupTree.flatten(groups) where node.isActive && !node.group.isSystem {
            let body = tidy(stripMarkers(from: node.group.content))
            guard !body.isEmpty else { continue }
            let label = "\(GroupTree.namePath(of: node.group.id, in: groups)) [\(node.group.shortID)]"
            sections.append("\(beginPrefix)\(label)\(beginSuffix)\n\(body)\n\(endPrefix)\(label)\(endSuffix)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    public static func parse(_ text: String) -> ParsedHostsFile {
        var systemLines: [String] = []
        var blocks: [ManagedBlock] = []
        var open: Marker?
        var openLines: [String] = []

        func closeOpenBlock() {
            if let marker = open {
                blocks.append(ManagedBlock(id: marker.id, name: marker.name, content: tidy(openLines)))
            }
            open = nil
            openLines = []
        }

        text.enumerateLines { rawLine, _ in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let begin = marker(in: line, prefix: beginPrefix, suffix: beginSuffix) {
                closeOpenBlock()
                open = begin
                return
            }
            if let end = marker(in: line, prefix: endPrefix, suffix: endSuffix),
               let current = open, end.id.isEmpty || current.id.isEmpty || end.id == current.id {
                closeOpenBlock()
                return
            }
            if open != nil { openLines.append(line) } else { systemLines.append(line) }
        }
        closeOpenBlock()

        return ParsedHostsFile(systemContent: tidy(systemLines), blocks: blocks)
    }

    /// Removes marker lines that were pasted into a group's text, so they cannot cut the
    /// block short the next time the file is parsed. Everything else is left exactly as typed.
    public static func stripMarkers(from content: String) -> String {
        let kept = content.components(separatedBy: "\n").filter { line in
            marker(in: line, prefix: beginPrefix, suffix: beginSuffix) == nil
                && marker(in: line, prefix: endPrefix, suffix: endSuffix) == nil
        }
        return kept.joined(separator: "\n")
    }

    private static func marker(in line: String, prefix: String, suffix: String) -> Marker? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let inner = line.dropFirst(prefix.count).dropLast(suffix.count)
            .trimmingCharacters(in: .whitespaces)
        if inner.hasSuffix("]"), let bracket = inner.lastIndex(of: "["), bracket > inner.startIndex {
            let id = inner[inner.index(after: bracket)..<inner.index(before: inner.endIndex)]
            if !id.isEmpty, id.allSatisfy(\.isHexDigit) {
                return Marker(id: id.lowercased(), name: inner[..<bracket].trimmingCharacters(in: .whitespaces))
            }
        }
        return Marker(id: "", name: inner)
    }

    /// Collapses runs of blank lines to one and drops blank lines at both ends.
    public static func tidy(_ text: String) -> String {
        tidy(text.components(separatedBy: "\n"))
    }

    public static func tidy(_ lines: [String]) -> String {
        var kept: [String] = []
        var pendingBlank = false
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                if !kept.isEmpty { pendingBlank = true }
            } else {
                if pendingBlank {
                    kept.append("")
                    pendingBlank = false
                }
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - First contact with an unmanaged file

    /// What a fresh macOS ships in `/etc/hosts`.
    public static let defaultSystemContent = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    """

    private static let defaultComments: Set<String> = [
        "##",
        "#",
        "# host database",
        "# localhost is used to configure the loopback interface",
        "# when the system is booting. do not change this entry.",
    ]
    private static let systemAddresses: Set<String> = [
        "127.0.0.1", "::1", "255.255.255.255", "0:0:0:0:0:0:0:1", "fe80::1%lo0",
    ]
    private static let systemHostnames: Set<String> = ["localhost", "broadcasthost"]

    /// Whether the line is part of Apple's stock hosts file, so a first import can tell
    /// "belongs to the system" from "something the user added".
    public static func isDefaultSystemLine(_ line: String) -> Bool {
        let normalized = line.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        if normalized.isEmpty { return false }
        if defaultComments.contains(normalized) { return true }
        guard case .entry(let address, let hostnames) = HostsSyntax.classify(line), !hostnames.isEmpty else { return false }
        return systemAddresses.contains(address.lowercased())
            && hostnames.allSatisfy { systemHostnames.contains($0.lowercased()) }
    }

    /// Splits a hosts file that has never been managed into Apple's stock lines and the rest.
    public static func splitUnmanaged(_ text: String) -> (system: String, remaining: String) {
        var system: [String] = []
        var remaining: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isDefaultSystemLine(line) { system.append(line) } else { remaining.append(line) }
        }
        return (tidy(system), tidy(remaining))
    }

    public enum LocalhostStatus: Equatable, Sendable {
        case ipv4AndIPv6
        case ipv4Only
        case ipv6Only
        case missing

        public var isComplete: Bool { self == .ipv4AndIPv6 }
        public var isMissing: Bool { self == .missing }
    }

    /// Which `localhost` mappings a text contains. Without them nothing on the machine can
    /// resolve the name `localhost`.
    public static func localhostStatus(in content: String) -> LocalhostStatus {
        var ipv4 = false
        var ipv6 = false
        for line in content.components(separatedBy: "\n") {
            guard case .entry(let address, let hostnames) = HostsSyntax.classify(line),
                  hostnames.contains(where: { $0.lowercased() == "localhost" }) else { continue }
            if address.contains(":") { ipv6 = true } else { ipv4 = true }
        }
        switch (ipv4, ipv6) {
        case (true, true): return .ipv4AndIPv6
        case (true, false): return .ipv4Only
        case (false, true): return .ipv6Only
        case (false, false): return .missing
        }
    }

    // MARK: - Consistency checks across groups

    /// Hostnames that active groups (the system group included) map to more than one address.
    /// Mappings are listed in file order, so `mappings.first` is the one that wins.
    public static func conflicts(
        systemContent: String,
        systemGroupName: String,
        groups: [HostGroup]
    ) -> [HostnameConflict] {
        var table: [String: [HostnameMapping]] = [:]
        var order: [String] = []

        func record(_ content: String, groupID: UUID, groupName: String) {
            for line in content.components(separatedBy: "\n") {
                guard case .entry(let address, let hostnames) = HostsSyntax.classify(line) else { continue }
                for hostname in hostnames {
                    let key = hostname.lowercased()
                    if table[key] == nil { order.append(key) }
                    table[key, default: []].append(HostnameMapping(groupID: groupID, groupName: groupName, address: address))
                }
            }
        }

        record(systemContent, groupID: HostGroup.systemID, groupName: systemGroupName)
        for node in GroupTree.flatten(groups) where node.isActive && !node.group.isSystem {
            record(node.group.content, groupID: node.group.id, groupName: node.group.name)
        }

        return order.compactMap { hostname in
            guard let mappings = table[hostname] else { return nil }
            var seen: Set<HostnameMapping> = []
            let unique = mappings.filter { seen.insert($0).inserted }
            guard Set(unique.map { $0.address.lowercased() }).count > 1 else { return nil }
            return HostnameConflict(hostname: hostname, mappings: unique)
        }
    }
}
