import Foundation
import Testing

@testable import RelvoraUpdates

@Suite("Code signatures")
struct CodeSignatureTests {
    private let teamID = "ABCDE12345"

    @Test("Release builds require Developer ID, the same team and bundle ID, and notarization")
    func developerIDRequirement() throws {
        let requirement = try #require(
            SigningPolicy.developerID.requirement(teamID: teamID, bundleID: "com.example.App"))
        #expect(requirement.contains(#"identifier "com.example.App""#))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        #expect(requirement.contains(SigningPolicy.developerIDRequirement))
        #expect(requirement.hasSuffix("and notarized"))
        let development = try #require(
            SigningPolicy.development.requirement(teamID: teamID, bundleID: "com.example.App"))
        #expect(!development.contains("notarized") && !development.contains("1.2.840.113635.100.6.2.6"))
    }

    @Test(
        "Team and bundle IDs can't inject anything into the requirement",
        arguments: [
            ("ABCDE1234\"", "com.example.App"), ("ABCDE1234", "com.example.App"),
            ("ABCDE12345", "com.example\" or true"), ("ABCDE12345", "com example"), ("ABCDE12345", ""),
        ])
    func injection(team: String, bundleID: String) {
        #expect(SigningPolicy.developerID.requirement(teamID: team, bundleID: bundleID) == nil)
    }

    @Test("An Apple app passes Apple's anchor but isn't Developer ID signed by a team")
    func appleApp() throws {
        let calculator = URL(filePath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: calculator.path))
        try CodeSignature.check(calculator, requirement: "anchor apple")
        let requirement = try #require(
            SigningPolicy.developerID.requirement(teamID: teamID, bundleID: "com.apple.calculator"))
        #expect {
            try CodeSignature.check(calculator, requirement: requirement)
        } throws: { error in
            (error as? SignatureProblem)?.isRequirementFailure == true
        }
    }

    @Test("A folder that isn't code fails with a reason")
    func notCode() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "NotCode-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: SignatureProblem.self) { try CodeSignature.check(folder, requirement: "anchor apple") }
        #expect(CodeSignature.teamIdentifier(ofCodeAt: folder) == nil)
    }

    /// Opt-in: `RELVORA_RELEASE_APP=/path/to/Relvora.app swift test`, with an app from a GitHub release. The team ID is
    /// read from the app itself and never printed.
    @Test(
        "A released Relvora meets the release requirement, and only for its own team",
        .enabled(if: ProcessInfo.processInfo.environment["RELVORA_RELEASE_APP"] != nil))
    func releasedApp() throws {
        let app = URL(filePath: try #require(ProcessInfo.processInfo.environment["RELVORA_RELEASE_APP"]))
        let team = try #require(CodeSignature.teamIdentifier(ofCodeAt: app))
        let bundleID = try #require(Bundle(url: app)?.bundleIdentifier)
        let requirement = try #require(SigningPolicy.developerID.requirement(teamID: team, bundleID: bundleID))
        try CodeSignature.check(app, requirement: requirement)
        let otherTeam = team == teamID ? "ZYXWV98765" : teamID
        #expect(throws: SignatureProblem.self) {
            try CodeSignature.check(
                app, requirement: SigningPolicy.developerID.requirement(teamID: otherTeam, bundleID: bundleID)!)
        }
        #expect(throws: SignatureProblem.self) {
            try CodeSignature.check(
                app, requirement: SigningPolicy.developerID.requirement(teamID: team, bundleID: bundleID + ".other")!)
        }
    }
}
