import Testing

@testable import RelvoraCore

@Suite("Release versions")
struct ReleaseVersionTests {
    @Test("Precedence follows the Semantic Versioning 2.0.0 specification example")
    func specificationPrecedence() throws {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0", "1.9.0", "1.10.0", "2.0.0-beta.1", "2.0.0",
        ]
        let versions = try ordered.map { try #require(SemanticVersion($0), "\($0) should parse") }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
        }
        #expect(versions.shuffled().sorted() == versions)
    }

    @Test("Build metadata is ignored for equality and ordering", arguments: [("1.0.0+001", "1.0.0+exp.sha.5114f85")])
    func buildMetadata(lhs: String, rhs: String) throws {
        let a = try #require(SemanticVersion(lhs))
        let b = try #require(SemanticVersion(rhs))
        #expect(a == b)
        #expect(!(a < b) && !(b < a))
        #expect(a.description == lhs)
    }

    @Test("A leading v is accepted and dropped")
    func leadingV() throws {
        #expect(try #require(SemanticVersion("v1.2.3")).description == "1.2.3")
        #expect(try #require(SemanticVersion("V2.0.0-rc.1")).isPrerelease)
    }

    @Test(
        "Malformed semantic versions are rejected",
        arguments: [
            "1.0", "1.0.0.0", "01.0.0", "1.02.0", "1.0.0-", "1.0.0-01", "1.0.0-alpha..1", "1.0.0+", "1.0.0-β", "",
            "-1.0.0",
        ]
    )
    func malformed(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test("Non-semantic text becomes a custom label sorted after semantic versions")
    func customLabels() throws {
        let label = try ReleaseVersion(parsing: "  Spring 2026  ")
        #expect(label == .custom("Spring 2026"))
        #expect(try ReleaseVersion(parsing: "9.9.9") < label)
        #expect(try ReleaseVersion(parsing: "Build 9") < ReleaseVersion(parsing: "Build 10"))
    }

    @Test(
        "Empty, multi-line, and over-long versions are invalid",
        arguments: ["", "   ", "1.0\nrc", String(repeating: "x", count: 65)])
    func invalid(text: String) {
        #expect(throws: ValidationError.invalidVersion(text)) { try ReleaseVersion(parsing: text) }
    }
}
