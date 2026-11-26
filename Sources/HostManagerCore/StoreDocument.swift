import CryptoKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var flushDNSCache: Bool = true
    public var snapshotBeforeApply: Bool = true
    /// How many snapshots to keep; 0 keeps all of them.
    public var snapshotLimit: Int = 50
    public var fontSize: Double = 13
    public var wrapLongLines: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case flushDNSCache, snapshotBeforeApply, snapshotLimit, fontSize, wrapLongLines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flushDNSCache = try container.decodeIfPresent(Bool.self, forKey: .flushDNSCache) ?? true
        snapshotBeforeApply = try container.decodeIfPresent(Bool.self, forKey: .snapshotBeforeApply) ?? true
        snapshotLimit = try container.decodeIfPresent(Int.self, forKey: .snapshotLimit) ?? 50
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        wrapLongLines = try container.decodeIfPresent(Bool.self, forKey: .wrapLongLines) ?? false
    }
}

/// What the app last left in the hosts file. Comparing against it tells a later launch
/// whether something else has rewritten the file since.
public struct LastApplied: Codable, Equatable, Sendable {
    public var fileSHA256: String
    /// The unmanaged part of that file, i.e. the system group's content at the time.
    public var systemContent: String
    public var date: Date
    /// False right after a first import, when the file was only read. Until the app has
    /// written the file once, its unmarked content is not "the system group's part".
    public var wasWritten: Bool

    public init(fileSHA256: String, systemContent: String, date: Date, wasWritten: Bool = false) {
        self.fileSHA256 = fileSHA256
        self.systemContent = systemContent
        self.date = date
        self.wasWritten = wasWritten
    }

    private enum CodingKeys: String, CodingKey { case fileSHA256, systemContent, date, wasWritten }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileSHA256 = try container.decode(String.self, forKey: .fileSHA256)
        systemContent = try container.decodeIfPresent(String.self, forKey: .systemContent) ?? ""
        date = try container.decode(Date.self, forKey: .date)
        wasWritten = try container.decodeIfPresent(Bool.self, forKey: .wasWritten) ?? false
    }
}

public struct StoreDocument: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var groups: [HostGroup]
    public var settings: AppSettings
    public var lastApplied: LastApplied?

    public init(groups: [HostGroup], settings: AppSettings = AppSettings(), lastApplied: LastApplied? = nil) {
        self.groups = groups
        self.settings = settings
        self.lastApplied = lastApplied
    }

    public var systemGroup: HostGroup? { groups.first { $0.isSystem } }

    private enum CodingKeys: String, CodingKey { case version, groups, settings, lastApplied }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        groups = try container.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        lastApplied = try container.decodeIfPresent(LastApplied.self, forKey: .lastApplied)
    }
}

/// Where the app keeps its state and which hosts file it manages.
public struct Paths: Sendable {
    public let dataDirectory: URL
    public let hostsPath: String
    /// True when `HOSTMANAGER_HOSTS_PATH` pointed the app at a scratch file. Used for testing:
    /// nothing touches `/etc/hosts` and nothing asks for the admin password.
    public let isDevMode: Bool

    public var hostsURL: URL { URL(fileURLWithPath: hostsPath) }
    public var storeURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var historyDirectory: URL { dataDirectory.appendingPathComponent("History", isDirectory: true) }

    public static func resolve(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        func value(_ key: String) -> String? {
            environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let hostsPath = value("HOSTMANAGER_HOSTS_PATH") {
            let directory = value("HOSTMANAGER_DATA_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("hostmanager-dev", isDirectory: true)
            return Paths(dataDirectory: directory, hostsPath: hostsPath, isDevMode: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return Paths(
            dataDirectory: support.appendingPathComponent("HostManager", isDirectory: true),
            hostsPath: "/etc/hosts",
            isDevMode: false
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum Digest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}

/// Loads and saves the JSON document behind the app. Writing uses `Data.write(.atomic)`,
/// so a crash mid-save leaves the previous file intact.
public enum Store {
    public static func load(from url: URL) throws -> StoreDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StoreDocument.self, from: data)
    }

    public static func save(_ document: StoreDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
