import Foundation

public enum HostsTokenKind: Equatable, Sendable {
    case comment
    case address
    case hostname
    case invalid
}

public struct HostsToken: Equatable, Sendable {
    /// Range inside the line, in UTF-16 units (ready to use as an `NSRange`).
    public let range: NSRange
    public let kind: HostsTokenKind
}

public enum HostsLineIssue: Equatable, Sendable {
    /// The first word is not an IP address.
    case notAnAddress
    /// An address with nothing to map it to.
    case missingHostname
    /// An alias with characters a hostname cannot contain (wildcards, ports, ...).
    case invalidHostname
    /// A second address where a hostname was expected.
    case extraAddress
}

public enum HostsLine: Equatable, Sendable {
    case empty
    case comment
    case entry(address: String, hostnames: [String])
    case invalid(HostsLineIssue)

    public var issue: HostsLineIssue? {
        if case .invalid(let issue) = self { return issue }
        return nil
    }

    public var hostnames: [String] {
        if case .entry(_, let hostnames) = self { return hostnames }
        return []
    }
}

/// The hosts(5) line grammar: enough to color a line and to tell whether the system will
/// understand it. Deliberately strict about things hosts files are commonly mistaken for
/// (wildcards, ports) and lenient about notation (`127.1` still counts as an address).
public enum HostsSyntax {
    public static func tokens(for line: String) -> [HostsToken] {
        let units = Array(line.utf16)
        let count = units.count
        guard count > 0 else { return [] }

        // Everything from the first "#" onwards is a comment, wherever it appears.
        let commentStart = units.firstIndex(of: 0x23) ?? count
        var result: [HostsToken] = []
        var index = 0
        var wordIndex = 0
        while index < commentStart {
            guard !isSpace(units[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < commentStart && !isSpace(units[end]) { end += 1 }
            let word = Array(units[index..<end])
            let kind: HostsTokenKind
            if wordIndex == 0 {
                kind = isAddress(word) ? .address : .invalid
            } else {
                kind = isHostname(word) && !isAddress(word) ? .hostname : .invalid
            }
            result.append(HostsToken(range: NSRange(location: index, length: end - index), kind: kind))
            wordIndex += 1
            index = end
        }
        if commentStart < count {
            result.append(HostsToken(range: NSRange(location: commentStart, length: count - commentStart), kind: .comment))
        }
        return result
    }

    public static func classify(_ line: String) -> HostsLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !trimmed.hasPrefix("#") else { return .comment }

        let words = tokens(for: line).filter { $0.kind != .comment }
        guard let first = words.first else { return .empty }
        if first.kind == .invalid { return .invalid(.notAnAddress) }
        if words.count == 1 { return .invalid(.missingHostname) }

        let lineUnits = Array(line.utf16)
        for word in words.dropFirst() where word.kind == .invalid {
            let isSecondAddress = isAddress(Array(lineUnits[word.range.location..<NSMaxRange(word.range)]))
            return .invalid(isSecondAddress ? .extraAddress : .invalidHostname)
        }
        let firstWord = lineUnits[first.range.location..<NSMaxRange(first.range)]
        let hostnames = words.dropFirst().map { word in
            String(decoding: lineUnits[word.range.location..<NSMaxRange(word.range)], as: UTF16.self)
        }
        return .entry(address: String(decoding: firstWord, as: UTF16.self), hostnames: hostnames)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0B || unit == 0x0C || unit == 0x0D
    }

    public static func isAddress(_ word: [UInt16]) -> Bool {
        guard !word.isEmpty else { return false }
        // A colon or a zone suffix means IPv6.
        if word.contains(0x3A) || word.contains(0x25) { return looksLikeIPv6(word) }
        return looksLikeIPv4(word)
    }

    private static func looksLikeIPv4(_ word: [UInt16]) -> Bool {
        var octet = 0
        var digits = 0
        var octets = 0
        for unit in word {
            if unit == 0x2E {  // "."
                guard digits > 0, octet <= 255 else { return false }
                octets += 1
                octet = 0
                digits = 0
            } else if (0x30...0x39).contains(unit) {
                octet = octet * 10 + Int(unit - 0x30)
                guard octet <= 255 else { return false }
                digits += 1
            } else {
                return false
            }
        }
        guard digits > 0, octet <= 255 else { return false }
        octets += 1
        return (2...4).contains(octets)
    }

    private static func looksLikeIPv6(_ word: [UInt16]) -> Bool {
        var colons = 0
        var colonRun = 0
        var hexDigits = 0
        var zone: [UInt16] = []
        for unit in word {
            if !zone.isEmpty || unit == 0x25 {  // "%lo0" scope id: everything after it is the zone
                zone.append(unit)
                continue
            }
            if isHexDigit(unit) {
                hexDigits += 1
                colonRun = 0
            } else if unit == 0x3A {
                colons += 1
                colonRun += 1
                if colonRun > 2 { return false }
            } else if unit != 0x2E {  // "." only for an embedded IPv4 tail
                return false
            } else {
                colonRun = 0
            }
        }
        let zoneIsValid = zone.isEmpty
            || (zone.count > 1
                && zone.dropFirst().allSatisfy { isAsciiLetterOrDigit($0) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E })
        return colons >= 2 && hexDigits > 0 && zoneIsValid
    }

    public static func isHostname(_ word: [UInt16]) -> Bool {
        guard let first = word.first, let last = word.last else { return false }
        guard isHostnameLead(first) else { return false }
        guard isHostnameLead(last) || last == 0x2E else { return false }  // trailing dot is legal
        return word.allSatisfy { isHostnameLead($0) || $0 == 0x2D || $0 == 0x2E }   // and so are hyphens
    }

    private static func isHostnameLead(_ unit: UInt16) -> Bool {
        isAsciiLetterOrDigit(unit) || unit == 0x5F
    }

    private static func isAsciiLetterOrDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit)
    }
}
