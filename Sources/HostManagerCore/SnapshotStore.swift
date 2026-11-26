import Foundation

public struct Snapshot: Identifiable, Hashable, Sendable {
    public let fileName: String
    public let date: Date
    public let url: URL
    public var id: String { fileName }
}

/// Copies of the hosts file taken just before each apply, so any change can be undone.
/// Each snapshot is a plain `.hosts` file named after the moment it was taken.
public enum SnapshotStore {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    /// Newest first.
    public static func list(in directory: URL) -> [Snapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> Snapshot? in
            guard url.pathExtension == "hosts",
                  let date = formatter.date(from: baseName(of: url)) else { return nil }
            return Snapshot(fileName: url.lastPathComponent, date: date, url: url)
        }.sorted { $0.date == $1.date ? $0.fileName < $1.fileName : $0.date > $1.date }
    }

    @discardableResult
    public static func save(_ text: String, to directory: URL, at date: Date = Date()) throws -> Snapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = formatter.string(from: date)
        var fileName = "\(base).hosts"
        var suffix = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            fileName = "\(base)-\(suffix).hosts"
            suffix += 1
        }
        let url = directory.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: url, options: .atomic)
        return Snapshot(fileName: fileName, date: date, url: url)
    }

    /// Deletes the oldest snapshots beyond `limit`. Does nothing when limit is 0 or less.
    public static func prune(in directory: URL, keep limit: Int) {
        guard limit > 0 else { return }
        for snapshot in list(in: directory).dropFirst(limit) {
            try? FileManager.default.removeItem(at: snapshot.url)
        }
    }

    public static func content(of snapshot: Snapshot) -> String? {
        try? String(contentsOf: snapshot.url, encoding: .utf8)
    }

    /// `2026-11-26_10-30-00-2` (a same-second snapshot gets a counter) becomes
    /// `2026-11-26_10-30-00`.
    private static func baseName(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 19 else { return name }
        let suffix = name.dropFirst(19)
        return suffix.first == "-" && suffix.dropFirst().allSatisfy(\.isNumber) ? String(name.prefix(19)) : name
    }
}
