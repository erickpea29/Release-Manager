import Foundation
import RelvoraCore
import Testing

@testable import GitHubIntegration

@Suite("App update API")
struct AppUpdateAPITests {
    private static let releases = """
        [{"id": 9, "tag_name": "v0.2.0", "name": "0.2.0", "draft": false, "prerelease": false,
          "created_at": "2026-10-26T00:00:00Z", "published_at": "2026-10-26T01:00:00Z", "target_commitish": "main",
          "html_url": "https://github.com/octo/app/releases/tag/v0.2.0", "body": "## Features\\n- Updates",
          "assets": [
            {"id": 31, "name": "Relvora-0.2.0.zip", "size": 5234512, "state": "uploaded",
             "digest": "sha256:d17ea7d827695e2913275160ebfd72a047426ac2b1256e84f5cd5ee78965a1c9"},
            {"id": 32, "name": "Relvora-0.2.0.zip.sha256", "size": 84, "state": "starter", "digest": null}
          ]},
         {"id": 8, "tag_name": "v0.1.2", "name": "", "draft": false, "prerelease": false,
          "created_at": "2026-10-20T00:00:00Z", "published_at": "2026-10-20T01:00:00Z", "target_commitish": "main",
          "html_url": "https://github.com/octo/app/releases/tag/v0.1.2", "body": null}]
        """

    @Test("Releases are read by repository name, with their files")
    func releases() async throws {
        let harness = Harness()
        await harness.mock.on("/repos/octo/app/releases", json: Self.releases)
        let releases = try await harness.api.appReleases(repository: "octo/app")
        #expect(releases.map(\.tagName) == ["v0.2.0", "v0.1.2"])
        let assets = releases[0].assets
        #expect(assets.map(\.name) == ["Relvora-0.2.0.zip", "Relvora-0.2.0.zip.sha256"])
        #expect(assets[0].id == 31 && assets[0].size == 5_234_512 && assets[0].isUploaded)
        #expect(assets[0].digest?.hasPrefix("sha256:") == true)
        #expect(!assets[1].isUploaded && assets[1].digest == nil)
        #expect(releases[0].notes == "## Features\n- Updates" && releases[1].name == nil && releases[1].assets.isEmpty)
    }

    @Test("A release file is downloaded as raw bytes from the assets endpoint")
    func download() async throws {
        let harness = Harness()
        await harness.mock.on("/repos/octo/app/releases/assets/31", .init(body: "zip bytes"))
        let data = try await harness.api.releaseAsset(repository: "octo/app", id: 31)
        #expect(String(decoding: data, as: UTF8.self) == "zip bytes")
        let sent = try #require(await harness.mock.requests(to: "/repos/octo/app/releases/assets/31").first)
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test(
        "Only owner/name repository names are requested",
        arguments: ["octo", "octo/app/releases", "../app", "octo/..", "octo/app?x=1", "octo/a p", "/app", ""])
    func invalidNames(name: String) async throws {
        let harness = Harness()
        await #expect(throws: GitHubError.self) { try await harness.api.appReleases(repository: name) }
        #expect(await harness.mock.requests.isEmpty)
    }

    @Test("Redirects never carry the token to another host, and never leave HTTPS")
    func redirects() throws {
        let api = URL(string: "https://api.github.com/repos/octo/app/releases/assets/31")!
        func redirect(to target: String) -> URLRequest {
            var request = URLRequest(url: URL(string: target)!)
            request.setValue("Bearer ghu_SECRET", forHTTPHeaderField: "Authorization")
            return request
        }
        let storage = try #require(
            RedirectGuard.follow(redirect(to: "https://release-assets.githubusercontent.com/x?sig=1"), from: api))
        #expect(storage.value(forHTTPHeaderField: "Authorization") == nil)
        let sameHost = try #require(
            RedirectGuard.follow(redirect(to: "https://api.github.com/repositories/1"), from: api))
        #expect(sameHost.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_SECRET")
        #expect(RedirectGuard.follow(redirect(to: "http://api.github.com/x"), from: api) == nil)
    }
}
