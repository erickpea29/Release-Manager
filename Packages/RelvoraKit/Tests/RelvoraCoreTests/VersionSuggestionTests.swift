import Foundation
import Testing

@testable import RelvoraCore

@Suite("Version suggestion")
struct VersionSuggestionTests {
    private func suggest(_ base: String?, _ changes: [ChangelogCategory]) -> VersionSuggestion {
        VersionSuggester.suggest(after: base.flatMap(SemanticVersion.init), changes: changes)
    }

    @Test(
        "Breaking changes raise major, features minor, anything else patch",
        arguments: [
            ("1.4.2", [ChangelogCategory.breaking, .features], "2.0.0", "1 breaking change since 1.4.2"),
            ("1.4.2", [.features, .features, .fixes], "1.5.0", "2 new features since 1.4.2"),
            ("1.4.2", [.fixes, .fixes, .maintenance], "1.4.3", "2 fixes since 1.4.2"),
            ("1.4.2", [.documentation, .other], "1.4.3", "no new features since 1.4.2"),
            ("1.4.2", [], "1.4.3", "no changes listed yet"),
        ])
    func bumps(base: String, changes: [ChangelogCategory], expected: String, reason: String) {
        let suggestion = suggest(base, changes)
        #expect(suggestion.version.description == expected)
        #expect(suggestion.reason == reason)
    }

    @Test("Before 1.0, breaking changes raise the minor version; 1.0 stays a deliberate choice")
    func beforeOne() {
        let suggestion = suggest("0.1.1", [.breaking])
        #expect(suggestion.version.description == "0.2.0" && suggestion.bump == .minor)
        #expect(suggestion.reason == "1 breaking change since 0.1.1" && suggestion.note != nil)
        #expect(suggest("1.0.0", [.breaking]).note == nil)
        #expect(suggestion.choices.map(\.version.description) == ["0.1.2", "0.2.0", "1.0.0"])
    }

    @Test("A project without releases starts at 0.1.0")
    func first() {
        let suggestion = suggest(nil, [.features])
        #expect(suggestion.version.description == "0.1.0" && suggestion.bump == .first)
        #expect(suggestion.choices.map(\.version.description) == ["0.1.0"])
    }

    @Test("The base is the latest stable release; prereleases, custom labels, and tag prefixes are handled")
    func latestStable() {
        #expect(
            VersionSuggester.latestStable(["v0.1.0", "0.1.1", "v0.2.0-beta.1", "Spring launch"])?.description == "0.1.1"
        )
        #expect(VersionSuggester.latestStable(["v1.10.0", "v1.9.3"])?.description == "1.10.0")
        #expect(VersionSuggester.latestStable(["Spring launch"]) == nil)
    }
}
