import Foundation

/// The next version, suggested from what changed since the last release (Semantic Versioning).
public struct VersionSuggestion: Sendable, Equatable {
    public enum Bump: Sendable, Equatable {
        /// No earlier release: the first version.
        case first
        case patch
        case minor
        case major
    }

    public let version: SemanticVersion
    public let bump: Bump
    /// The release it follows; `nil` for the first release.
    public let base: SemanticVersion?
    /// Why, in a short phrase: "3 new features since 0.1.1".
    public let reason: String
    /// Extra context, such as why a breaking change before 1.0 raises only the minor version.
    public var note: String?

    /// The next patch, minor, and major versions after the base, for choosing another; the first version alone when
    /// there's no earlier release.
    public var choices: [(bump: Bump, version: SemanticVersion)] {
        guard let base else { return [(.first, version)] }
        return [Bump.patch, .minor, .major].map { ($0, VersionSuggester.next(after: base, $0)) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.bump == rhs.bump && lhs.base == rhs.base && lhs.reason == rhs.reason
            && lhs.note == rhs.note
    }
}

/// Suggests the next version:
/// - breaking changes raise the major version (before 1.0, the minor version: 1.0 is a decision, not a side effect);
/// - new features raise the minor version;
/// - anything else, or nothing yet, raises the patch version;
/// - a project without releases starts at 0.1.0.
///
/// Changes are the release-note sections (`ChangelogGenerator.entries`): pull request labels, Conventional Commits
/// prefixes, and task types.
public enum VersionSuggester {
    /// The latest stable release among `versions` (tags, published plans, or snapshots). Prereleases and custom labels
    /// are ignored: the next version follows the last finished one.
    public static func latestStable(_ versions: [String]) -> SemanticVersion? {
        versions.compactMap(SemanticVersion.init).filter { !$0.isPrerelease }.max()
    }

    public static func suggest(after base: SemanticVersion?, changes: [ChangelogCategory]) -> VersionSuggestion {
        guard let base else {
            return VersionSuggestion(
                version: SemanticVersion("0.1.0")!, bump: .first, base: nil, reason: "the first release")
        }
        let breaking = changes.count { $0 == .breaking }
        let features = changes.count { $0 == .features }
        let fixes = changes.count { $0 == .fixes }

        let bump: VersionSuggestion.Bump
        let reason: String
        var note: String?
        if breaking > 0 {
            bump = base.major == 0 ? .minor : .major
            reason = count(breaking, "breaking change")
            if base.major == 0 {
                note = "Before 1.0, breaking changes raise the minor version. Choose 1.0.0 when you’re ready."
            }
        } else if features > 0 {
            bump = .minor
            reason = count(features, "new feature")
        } else if fixes > 0 {
            bump = .patch
            reason = count(fixes, "fix", plural: "fixes")
        } else if changes.isEmpty {
            bump = .patch
            reason = "no changes listed yet"
        } else {
            bump = .patch
            reason = "no new features"
        }
        return VersionSuggestion(
            version: next(after: base, bump), bump: bump, base: base,
            reason: changes.isEmpty ? reason : "\(reason) since \(base)", note: note)
    }

    static func next(after base: SemanticVersion, _ bump: VersionSuggestion.Bump) -> SemanticVersion {
        let text =
            switch bump {
            case .first: "0.1.0"
            case .patch: "\(base.major).\(base.minor).\(base.patch + 1)"
            case .minor: "\(base.major).\(base.minor + 1).0"
            case .major: "\(base.major + 1).0.0"
            }
        return SemanticVersion(text)!
    }

    private static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? noun : plural ?? noun + "s")"
    }
}
