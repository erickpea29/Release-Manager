import Foundation

/// A release version string: Semantic Versioning 2.0.0 when it parses as such, otherwise a custom label.
/// Custom labels sort after every semantic version.
public enum ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    case semantic(SemanticVersion)
    case custom(String)

    public static let maximumCustomLength = 64

    public init(parsing text: String) throws(ValidationError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semantic = SemanticVersion(trimmed) {
            self = .semantic(semantic)
        } else if !trimmed.isEmpty, trimmed.count <= Self.maximumCustomLength,
            !trimmed.contains(where: \.isNewline)
        {
            self = .custom(trimmed)
        } else {
            throw .invalidVersion(text)
        }
    }

    public var description: String {
        switch self {
        case .semantic(let version): version.description
        case .custom(let label): label
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.semantic(let a), .semantic(let b)): a < b
        case (.semantic, .custom): true
        case (.custom, .semantic): false
        case (.custom(let a), .custom(let b)): a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

/// Semantic Versioning 2.0.0. Equality and ordering follow precedence rules, so build metadata is ignored.
/// A leading `v` (common in tag names) is accepted and dropped.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum Identifier: Sendable, Hashable, Comparable, CustomStringConvertible {
        case numeric(Int)
        case alphanumeric(String)

        public static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let a), .numeric(let b)): a < b
            case (.numeric, .alphanumeric): true
            case (.alphanumeric, .numeric): false
            case (.alphanumeric(let a), .alphanumeric(let b)): a < b
            }
        }

        public var description: String {
            switch self {
            case .numeric(let value): String(value)
            case .alphanumeric(let value): value
            }
        }
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [Identifier]
    public let build: [String]

    public init?(_ text: String) {
        var core = Substring(text)
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }

        var build: [String] = []
        if let plus = core.firstIndex(of: "+") {
            build = core[core.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false).map(
                String.init)
            guard build.allSatisfy(Self.isValidIdentifier) else { return nil }
            core = core[..<plus]
        }

        var prerelease: [Identifier] = []
        if let hyphen = core.firstIndex(of: "-") {
            let parts = core[core.index(after: hyphen)...].split(separator: ".", omittingEmptySubsequences: false)
            for part in parts {
                guard Self.isValidIdentifier(part) else { return nil }
                if part.allSatisfy(\.isASCIIDigit) {
                    guard let number = Self.numericIdentifier(part) else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.alphanumeric(String(part)))
                }
            }
            core = core[..<hyphen]
        }

        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map(Self.numericIdentifier)
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2] else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { text += "-" + prerelease.map(\.description).joined(separator: ".") }
        if !build.isEmpty { text += "+" + build.joined(separator: ".") }
        return text
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.prerelease) == (rhs.major, rhs.minor, rhs.patch, rhs.prerelease)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A version without prerelease identifiers has higher precedence.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): return lhs.prerelease.lexicographicallyPrecedes(rhs.prerelease)
        }
    }

    private static func isValidIdentifier(_ part: some StringProtocol) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Numeric identifiers have no leading zeros.
    private static func numericIdentifier(_ part: some StringProtocol) -> Int? {
        guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), part == "0" || part.first != "0" else { return nil }
        return Int(part)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
