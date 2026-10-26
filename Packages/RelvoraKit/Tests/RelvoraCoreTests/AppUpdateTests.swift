import Foundation
import Testing

@testable import RelvoraCore

@Suite("App updates")
struct AppUpdateTests {
    private func release(
        _ tag: String, draft: Bool = false, prerelease: Bool = false, files: Bool = true, uploading: Bool = false
    ) -> AppRelease {
        let version = SemanticVersion(tag)?.description ?? tag
        let assets =
            files
            ? [
                AppRelease.Asset(
                    id: 1, name: "Relvora-\(version).zip", size: 5_000_000, digest: nil, isUploaded: !uploading),
                AppRelease.Asset(id: 2, name: "Relvora-\(version).zip.sha256", size: 84, digest: nil, isUploaded: true),
            ] : []
        return AppRelease(
            tagName: tag, name: nil, notes: nil, htmlURL: URL(string: "https://github.com/o/r/releases/tag/\(tag)")!,
            publishedAt: draft ? nil : .now, isDraft: draft, isPrerelease: prerelease, assets: assets)
    }

    private func check(_ releases: [AppRelease], current: String = "0.1.2") -> AppUpdateCheck {
        AppUpdateRules.check(releases, current: SemanticVersion(current)!)
    }

    @Test("The newest published stable release with its zip and checksum is offered")
    func newest() throws {
        let result = check([release("v0.1.2"), release("v0.3.0"), release("v0.2.0")])
        guard case .available(let update) = result else {
            Issue.record("Expected an update, got \(result)")
            return
        }
        #expect(update.version.description == "0.3.0")
        #expect(update.archive.name == "Relvora-0.3.0.zip" && update.checksum.name == "Relvora-0.3.0.zip.sha256")
    }

    @Test("Drafts, prereleases, and tags that aren't versions are never offered")
    func ignored() {
        let result = check([
            release("v0.4.0", draft: true), release("v0.4.0-beta.1"), release("v0.3.0", prerelease: true),
            release("Spring launch"), release("v0.1.2"),
        ])
        #expect(result == .upToDate(latest: SemanticVersion("0.1.2")))
    }

    @Test("A newer release whose build isn't attached yet is reported as building")
    func building() {
        #expect(check([release("v0.2.0", files: false), release("v0.1.2")]) == .building(SemanticVersion("0.2.0")!))
        #expect(check([release("v0.2.0", uploading: true)]) == .building(SemanticVersion("0.2.0")!))
        // An older newer version with its files is offered meanwhile.
        guard case .available(let update) = check([release("v0.3.0", files: false), release("v0.2.0")]) else {
            Issue.record("Expected 0.2.0")
            return
        }
        #expect(update.version.description == "0.2.0")
    }

    @Test("Up to date: the same or older versions, or none")
    func upToDate() {
        #expect(check([release("v0.1.2"), release("v0.1.1")]) == .upToDate(latest: SemanticVersion("0.1.2")))
        #expect(check([release("v0.1.0")]) == .upToDate(latest: SemanticVersion("0.1.0")))
        #expect(check([]) == .upToDate(latest: nil))
    }

    @Test("The checksum file's line for the zip gives its SHA-256")
    func checksumFile() {
        let hex = String(repeating: "Ab", count: 32)
        func sha256(_ text: String) -> String? {
            AppUpdateRules.sha256(inChecksumFile: text, archiveName: "Relvora-0.2.0.zip")
        }
        #expect(sha256("\(hex)  Relvora-0.2.0.zip\n") == hex.lowercased())
        #expect(sha256("\(hex) *Relvora-0.2.0.zip") == hex.lowercased())
        // Another file, a short hash, or no file name: not a checksum for this zip.
        #expect(sha256("\(hex)  Relvora-0.1.0.zip") == nil)
        #expect(sha256("abc123  Relvora-0.2.0.zip") == nil)
        #expect(sha256(hex) == nil)
    }

    @Test("GitHub's sha256 digests are read; other digests aren't")
    func digest() {
        let hex = String(repeating: "0f", count: 32)
        #expect(AppUpdateRules.sha256(inDigest: "sha256:\(hex)") == hex)
        #expect(AppUpdateRules.sha256(inDigest: "sha512:\(hex)") == nil)
        #expect(AppUpdateRules.sha256(inDigest: "sha256:xyz") == nil)
        #expect(AppUpdateRules.sha256(inDigest: nil) == nil)
    }
}
