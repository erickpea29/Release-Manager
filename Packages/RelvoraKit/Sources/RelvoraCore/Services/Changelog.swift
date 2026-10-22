import Foundation

/// Changelog sections, in the order they appear. Raw values are stable keys for settings and backups.
public enum ChangelogCategory: String, Sendable, CaseIterable, Comparable, Codable {
    case breaking, features, improvements, fixes, documentation, maintenance, other

    public var title: String {
        switch self {
        case .breaking: "Breaking Changes"
        case .features: "Features"
        case .improvements: "Improvements"
        case .fixes: "Bug Fixes"
        case .documentation: "Documentation"
        case .maintenance: "Maintenance"
        case .other: "Other Changes"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    init(_ type: TaskType) {
        switch type {
        case .feature: self = .features
        case .improvement: self = .improvements
        case .bugFix: self = .fixes
        case .documentation: self = .documentation
        case .maintenance: self = .maintenance
        case .other: self = .other
        }
    }
}

public struct ChangelogOptions: Sendable, Equatable {
    /// Completed tasks assigned to the release.
    public var includeTasks: Bool
    /// Merged pull requests between the base tag and the target commit.
    public var includePullRequests: Bool
    /// Commits that aren't part of a listed pull request.
    public var includeCommits: Bool
    /// The user's own label → section rules (Settings › Releases). They win over the built-in mapping.
    public var labelRules: [ChangelogLabelRule]

    public init(
        includeTasks: Bool = true, includePullRequests: Bool = true, includeCommits: Bool = true,
        labelRules: [ChangelogLabelRule] = []
    ) {
        self.includeTasks = includeTasks
        self.includePullRequests = includePullRequests
        self.includeCommits = includeCommits
        self.labelRules = labelRules
    }
}

/// Puts pull requests with a label into a section, e.g. `ui` → Improvements. Labels match ignoring case.
public struct ChangelogLabelRule: Sendable, Hashable, Codable {
    public var label: String
    public var category: ChangelogCategory

    public init(label: String, category: ChangelogCategory) {
        self.label = label
        self.category = category
    }

    /// Trimmed, non-empty rules; a label listed twice keeps its first rule.
    public static func normalized(_ rules: [ChangelogLabelRule]) -> [ChangelogLabelRule] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            let label = rule.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { return nil }
            return ChangelogLabelRule(label: label, category: rule.category)
        }
    }
}

public struct ChangelogInput: Sendable {
    /// The release's tasks. Only completed ones are listed.
    public var tasks: [ProjectTask]
    public var changes: UnreleasedChanges?
    /// The tag being released, for the compare link.
    public var tagName: String?
    public var repositoryURL: URL?

    public init(tasks: [ProjectTask], changes: UnreleasedChanges?, tagName: String?, repositoryURL: URL?) {
        self.tasks = tasks
        self.changes = changes
        self.tagName = tagName
        self.repositoryURL = repositoryURL
    }
}

public struct ChangelogEntry: Sendable, Equatable {
    public let category: ChangelogCategory
    public let text: String
}

/// Builds release notes deterministically from local tasks and GitHub data: the same input always gives the same
/// Markdown. Pull requests are grouped by label, then by a Conventional Commits prefix in the title; tasks by type.
public enum ChangelogGenerator {
    public static func markdown(_ input: ChangelogInput, options: ChangelogOptions = .init()) -> String {
        let grouped = Dictionary(grouping: entries(input, options: options), by: \.category)
        var sections = ChangelogCategory.allCases.compactMap { category -> String? in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return "## \(category.title)\n\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
        }
        if let link = compareURL(input) { sections.append("**Full changelog:** \(link.absoluteString)") }
        return sections.joined(separator: "\n\n") + (sections.isEmpty ? "" : "\n")
    }

    public static func entries(_ input: ChangelogInput, options: ChangelogOptions = .init()) -> [ChangelogEntry] {
        let pullRequests =
            options.includePullRequests ? (input.changes?.pullRequests ?? []).sorted { $0.number < $1.number } : []
        let pullRequestTitles = Set(pullRequests.map { normalizedTitle($0.title) })
        var entries: [ChangelogEntry] = []

        if options.includeTasks {
            let done = input.tasks.filter { $0.completedAt != nil }
                .sorted { ($0.completedAt!, $0.title) < ($1.completedAt!, $1.title) }
            for task in done where !pullRequestTitles.contains(normalizedTitle(task.title)) {
                entries.append(ChangelogEntry(category: ChangelogCategory(task.type), text: oneLine(task.title)))
            }
        }

        for pullRequest in pullRequests {
            let parsed = ConventionalTitle(pullRequest.title)
            let category =
                category(labels: pullRequest.labels, title: pullRequest.title, rules: options.labelRules) ?? .other
            var text = "\(oneLine(parsed.description)) (#\(pullRequest.number))"
            if let author = pullRequest.authorLogin { text += " by @\(author)" }
            entries.append(ChangelogEntry(category: category, text: text))
        }

        if options.includeCommits, let changes = input.changes {
            let listed = Set(pullRequests.map(\.number))
            for commit in changes.commits.reversed() where Set(commit.pullRequestNumbers).isDisjoint(with: listed) {
                guard let line = commitLine(commit) else { continue }
                entries.append(
                    ChangelogEntry(category: category(labels: [], title: line.title) ?? .other, text: line.text))
            }
        }
        return entries
    }

    /// What the user should know about the data behind the notes.
    public static func warnings(_ input: ChangelogInput, options: ChangelogOptions = .init()) -> [String] {
        var warnings: [String] = []
        let open = input.tasks.filter { $0.completedAt == nil }.count
        if options.includeTasks && open > 0 {
            warnings.append(
                "\(open) \(open == 1 ? "task isn’t" : "tasks aren’t") complete and \(open == 1 ? "was" : "were") left out."
            )
        }
        guard let changes = input.changes else {
            if options.includePullRequests || options.includeCommits {
                warnings.append("No GitHub changes were loaded, so only tasks are listed.")
            }
            return warnings
        }
        if changes.isTruncated {
            warnings.append("Only \(changes.commits.count) of \(changes.totalCommits) commits were listed.")
        }
        if !changes.pullRequestsComplete {
            warnings.append(
                "Some pull requests were matched from commit messages, so their titles and labels are missing.")
        }
        if changes.baseTag == nil {
            warnings.append("There’s no previous release to compare with, so recent commits were used.")
        }
        return warnings
    }

    /// The section for a pull request or commit: the user's label rules first, then built-in label meanings, then a
    /// Conventional Commits prefix. `nil` when nothing gives a signal.
    public static func category(labels: [String], title: String, rules: [ChangelogLabelRule] = []) -> ChangelogCategory?
    {
        let custom = labels.compactMap { label in
            rules.first { $0.label.caseInsensitiveCompare(label.trimmingCharacters(in: .whitespaces)) == .orderedSame }?
                .category
        }
        if let best = custom.min() { return best }
        let labelCategories = labels.compactMap(category(label:))
        if let best = labelCategories.min() { return best }
        let parsed = ConventionalTitle(title)
        if parsed.isBreaking { return .breaking }
        return parsed.type.flatMap(category(conventionalType:))
    }

    static func category(label: String) -> ChangelogCategory? {
        let tokens = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func any(_ words: Set<String>) -> Bool { tokens.contains(where: words.contains) }
        if any(["breaking"]) { return .breaking }
        if any(["bug", "bugs", "bugfix", "fix", "fixes", "hotfix", "regression"]) { return .fixes }
        if any(["feature", "features", "feat", "enhancement", "enhancements"]) { return .features }
        if any(["improvement", "improvements", "perf", "performance", "polish", "ux"]) { return .improvements }
        if tokens.contains(where: { $0.hasPrefix("doc") }) { return .documentation }
        if any([
            "chore", "maintenance", "dependencies", "dependency", "deps", "refactor", "ci", "build", "test", "tests",
            "infra", "infrastructure", "tooling",
        ]) {
            return .maintenance
        }
        return nil
    }

    static func category(conventionalType type: String) -> ChangelogCategory? {
        switch type {
        case "feat", "feature": .features
        case "fix", "bugfix", "hotfix": .fixes
        case "perf", "improvement": .improvements
        case "docs", "doc": .documentation
        case "chore", "refactor", "build", "ci", "test", "tests", "style", "deps": .maintenance
        default: nil
        }
    }

    // MARK: Helpers

    private static func compareURL(_ input: ChangelogInput) -> URL? {
        guard let base = input.changes?.baseTag, let tag = input.tagName, let repository = input.repositoryURL else {
            return nil
        }
        return repository.appending(path: "compare/\(base)...\(tag)")
    }

    /// A commit's line, or `nil` for merge commits that carry no information of their own.
    private static func commitLine(_ commit: RemoteCommit) -> (title: String, text: String)? {
        let summary = commit.summary.trimmingCharacters(in: .whitespaces)
        if let match = summary.firstMatch(of: /^Merge pull request #(\d+)/) {
            // GitHub's merge button puts the pull request title in the commit body.
            let body = commit.message.split(separator: "\n").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            guard let body else { return nil }
            return (body, "\(oneLine(ConventionalTitle(body).description)) (#\(match.1))")
        }
        if summary.isEmpty || summary.hasPrefix("Merge branch") || summary.hasPrefix("Merge remote-tracking branch") {
            return nil
        }
        return (summary, "\(oneLine(ConventionalTitle(summary).description)) (\(commit.shortSHA))")
    }

    private static func normalizedTitle(_ title: String) -> String {
        var text = ConventionalTitle(title).description.lowercased().trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// A title in Conventional Commits form, such as `feat(board)!: Drag columns`.
struct ConventionalTitle: CustomStringConvertible {
    let type: String?
    let isBreaking: Bool
    /// The title without its prefix, first letter capitalized.
    let description: String

    init(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: /^([A-Za-z]+)(\([^)]*\))?(!)?:\s+(.+)$/) else {
            type = nil
            isBreaking = false
            description = trimmed
            return
        }
        type = match.1.lowercased()
        isBreaking = match.3 != nil
        let rest = String(match.4)
        description = rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
