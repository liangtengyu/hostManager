import Foundation

public enum GroupKind: String, Codable, Equatable, Sendable {
    /// The built-in block that mirrors the unmanaged part of the hosts file. Always active.
    case system
    case user
}

public struct HostGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: GroupKind
    public var name: String
    /// SF Symbol name. Empty picks one automatically (folder for parents, document otherwise).
    public var icon: String
    public var enabled: Bool
    /// The group's own hosts text, without the surrounding file markers.
    public var content: String
    public var isExpanded: Bool
    public var children: [HostGroup]

    public init(
        id: UUID = UUID(),
        kind: GroupKind = .user,
        name: String,
        icon: String = "",
        enabled: Bool = false,
        content: String = "",
        isExpanded: Bool = true,
        children: [HostGroup] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.icon = icon
        self.enabled = enabled
        self.content = content
        self.isExpanded = isExpanded
        self.children = children
    }

    /// Stable identity of the built-in system group, so the store and the markers in the
    /// hosts file keep pointing at it across launches.
    public static let systemID = UUID(uuidString: "5A2B7D31-0C6E-4B8F-9A51-000000000001")!

    public static func system(content: String, name: String) -> HostGroup {
        HostGroup(id: systemID, kind: .system, name: name, icon: "display", enabled: true, content: content)
    }

    public var isSystem: Bool { kind == .system }
    public var hasChildren: Bool { !children.isEmpty }

    /// Short, human-typable form of the id that travels inside the file markers.
    public var shortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, icon, enabled, content, isExpanded, children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(GroupKind.self, forKey: .kind) ?? .user
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        children = try container.decodeIfPresent([HostGroup].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(content, forKey: .content)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(children, forKey: .children)
    }
}
