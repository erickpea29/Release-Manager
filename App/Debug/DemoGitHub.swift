#if DEBUG
    import CryptoKit
    import Foundation
    import GitHubIntegration
    import RelvoraCore

    /// An in-memory fake of the GitHub REST endpoints Relvora uses, for UI checks without a GitHub account
    /// (`-RelvoraDemoGitHub YES`). The real API client, sync, and release workflow run against it. Like GitHub, it
    /// keeps drafts tagless until they are published. Never compiled into Release builds.
    actor DemoGitHub: HTTPTransport {
        static let shared = DemoGitHub()
        nonisolated static let repositoryID: Int64 = 4242
        nonisolated static let owner = "relvora-demo"
        nonisolated static let name = "relvora"
        nonisolated static var fullName: String { "\(owner)/\(name)" }

        private struct Commit {
            let sha: String
            let message: String
            let login: String
            let date: Date
        }

        private struct Release {
            let id: Int
            var tag: String
            let name: String
            var draft: Bool
            let prerelease: Bool
            let createdAt: Date
            var publishedAt: Date?
            let target: String
            var body: String
        }

        private struct Pull {
            let number: Int
            let title: String
            let labels: [String]
            let login: String
            let commitIndex: Int
        }

        private var commits: [Commit] = []
        private var releases: [Release] = []
        private var tags: [String: String] = [:]
        private var pulls: [Pull] = []
        private var nextReleaseID = 10
        /// The next create succeeds on "GitHub" but the response is lost (a timeout).
        private var dropNextCreateResponse = false

        private init() {
            let start = Date.now.addingTimeInterval(-86_400 * 12)
            let history: [(String, String)] = [
                ("Release 0.1.0", "erick"),
                ("Add release history view (#12)", "erick"),
                ("fix: Crash when a column is empty (#13)", "ann"),
                ("docs: Backup and restore guide", "erick"),
                ("Merge pull request #14 from relvora-demo/drafts\n\nCreate GitHub drafts from release plans", "erick"),
                ("chore(deps): Bump swift-format (#15)", "dependabot[bot]"),
                ("perf: Faster board rendering", "ann"),
            ]
            commits = history.enumerated().map { index, item in
                Commit(
                    sha: Self.sha("demo-\(index)"), message: item.0, login: item.1,
                    date: start.addingTimeInterval(Double(index) * 86_400 * 1.5))
            }
            pulls = [
                Pull(
                    number: 12, title: "Add release history view", labels: ["feature"], login: "erick", commitIndex: 1),
                Pull(number: 13, title: "Crash when a column is empty", labels: ["bug"], login: "ann", commitIndex: 2),
                Pull(
                    number: 14, title: "Create GitHub drafts from release plans", labels: ["enhancement"],
                    login: "erick", commitIndex: 4),
                Pull(
                    number: 15, title: "Bump swift-format", labels: ["dependencies"], login: "dependabot[bot]",
                    commitIndex: 5),
            ]
            tags["v0.1.0"] = commits[0].sha
            releases = [
                Release(
                    id: 1, tag: "v0.1.0", name: "0.1.0", draft: false, prerelease: false, createdAt: commits[0].date,
                    publishedAt: commits[0].date, target: "main", body: "First preview.")
            ]
        }

        // MARK: Demo controls

        /// Publishes every draft, as a person would on github.com.
        func publishAll() {
            for index in releases.indices where releases[index].draft { publish(at: index) }
        }

        /// Like GitHub, publishing creates the tag at the target commit unless the tag already exists.
        private func publish(at index: Int) {
            releases[index].draft = false
            releases[index].publishedAt = .now
            if tags[releases[index].tag] == nil { tags[releases[index].tag] = releases[index].target }
        }

        /// Someone pushes the tag to another commit before the draft is published.
        func moveTagBeforePublishing(_ tag: String) { tags[tag] = commits[3].sha }

        func dropNextCreate() { dropNextCreateResponse = true }

        // MARK: HTTPTransport

        /// Every request fails as if the Mac were offline (error-state UI tests). Starts on with
        /// `-RelvoraDemoGitHubOffline YES`; toggled from the Demo GitHub menu.
        private var isOffline = UserDefaults.standard.bool(forKey: "RelvoraDemoGitHubOffline")

        func setOffline(_ offline: Bool) { isOffline = offline }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .milliseconds(120))
            if isOffline { throw URLError(.notConnectedToInternet) }
            let url = request.url!
            let path = url.path(percentEncoded: false)
            let method = request.httpMethod ?? "GET"
            let base = "/repos/\(Self.fullName)"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

            switch (method, path) {
            case ("GET", "/user"):
                return reply(
                    request, ["id": 1, "login": "demo", "name": "Demo", "html_url": "https://github.com/demo"])
            case ("GET", "/user/installations"):
                return reply(request, ["installations": [["id": 1]]])
            case ("GET", "/user/installations/1/repositories"):
                return reply(request, ["repositories": [repository]])
            case ("GET", "/repositories/\(Self.repositoryID)"):
                return reply(request, repository)
            case ("GET", base + "/releases"):
                return reply(request, releases.sorted { $0.createdAt > $1.createdAt }.map(json))
            case ("POST", base + "/releases"):
                return try create(request)
            case ("GET", base + "/tags"):
                return reply(
                    request,
                    tags.sorted { $0.key > $1.key }.map {
                        ["name": $0.key, "commit": ["sha": $0.value]] as [String: Any]
                    })
            case ("GET", base + "/branches"):
                return reply(
                    request,
                    [
                        ["name": "main", "commit": ["sha": commits.last!.sha]],
                        ["name": "release/0.1", "commit": ["sha": commits[0].sha]],
                    ])
            case ("GET", base + "/commits"):
                let head = index(of: query.first { $0.name == "sha" }?.value ?? "main") ?? commits.count - 1
                return reply(request, commits[...head].reversed().map(json))
            default:
                break
            }

            if method == "GET", path.hasPrefix(base + "/releases/"),
                let id = Int(path.dropFirst((base + "/releases/").count)),
                let release = releases.first(where: { $0.id == id })
            {
                return reply(request, json(release))
            }
            if method == "PATCH", path.hasPrefix(base + "/releases/"),
                let id = Int(path.dropFirst((base + "/releases/").count)),
                let index = releases.firstIndex(where: { $0.id == id })
            {
                let body =
                    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                if body["draft"] as? Bool == false, releases[index].draft { publish(at: index) }
                return reply(request, json(releases[index]))
            }
            if method == "GET", path.hasPrefix(base + "/git/ref/tags/") {
                let tag = String(path.dropFirst((base + "/git/ref/tags/").count))
                if let sha = tags[tag] { return reply(request, ["object": ["type": "commit", "sha": sha]]) }
            }
            if method == "GET", path.hasPrefix(base + "/compare/") {
                let spec = path.dropFirst((base + "/compare/").count).components(separatedBy: "...")
                if spec.count == 2, let from = index(of: spec[0]), let to = index(of: spec[1]) {
                    let range = from < to ? Array(commits[(from + 1)...to]) : []
                    return reply(
                        request,
                        [
                            "total_commits": range.count, "commits": range.map(json),
                            "html_url": "https://github.com/\(Self.fullName)/compare/\(spec[0])...\(spec[1])",
                        ])
                }
            }
            if method == "GET", path.hasPrefix(base + "/commits/") {
                let rest = String(path.dropFirst((base + "/commits/").count))
                if rest.hasSuffix("/pulls") {
                    let sha = String(rest.dropLast("/pulls".count))
                    let matching = pulls.filter { commits[$0.commitIndex].sha == sha }
                    return reply(request, matching.map(json))
                }
                if let index = index(of: rest) { return reply(request, json(commits[index])) }
            }
            return reply(request, ["message": "Not Found"], status: 404)
        }

        // MARK: Helpers

        private var repository: [String: Any] {
            [
                "id": Self.repositoryID, "name": Self.name, "owner": ["login": Self.owner], "private": false,
                "default_branch": "main", "html_url": "https://github.com/\(Self.fullName)",
                "description": "Demo repository (not on GitHub)",
            ]
        }

        private func create(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            nextReleaseID += 1
            let release = Release(
                id: nextReleaseID, tag: body["tag_name"] as? String ?? "", name: body["name"] as? String ?? "",
                draft: true, prerelease: body["prerelease"] as? Bool ?? false, createdAt: .now, publishedAt: nil,
                target: body["target_commitish"] as? String ?? "main", body: body["body"] as? String ?? "")
            releases.append(release)
            if dropNextCreateResponse {
                dropNextCreateResponse = false
                throw URLError(.timedOut)
            }
            return reply(request, json(release), status: 201)
        }

        /// A commit index by full or short SHA, branch, or tag.
        private func index(of ref: String) -> Int? {
            if ref == "main" { return commits.count - 1 }
            if ref == "release/0.1" { return 0 }
            let sha = tags[ref] ?? ref
            return commits.firstIndex { $0.sha.hasPrefix(sha) && sha.count >= 7 }
        }

        private func json(_ release: Release) -> [String: Any] {
            [
                "id": release.id, "tag_name": release.tag, "name": release.name, "draft": release.draft,
                "prerelease": release.prerelease, "created_at": Self.iso(release.createdAt),
                "published_at": release.publishedAt.map { Self.iso($0) as Any } ?? NSNull(),
                "target_commitish": release.target,
                "body": release.body,
                "html_url": "https://github.com/\(Self.fullName)/releases/tag/"
                    + (release.draft ? "untagged-\(release.id)" : release.tag),
            ]
        }

        private func json(_ commit: Commit) -> [String: Any] {
            [
                "sha": commit.sha, "html_url": "https://github.com/\(Self.fullName)/commit/\(commit.sha)",
                "commit": [
                    "message": commit.message, "author": ["name": commit.login, "date": Self.iso(commit.date)],
                ] as [String: Any],
                "author": ["login": commit.login],
            ]
        }

        private func json(_ pull: Pull) -> [String: Any] {
            [
                "number": pull.number, "title": pull.title,
                "html_url": "https://github.com/\(Self.fullName)/pull/\(pull.number)",
                "merged_at": Self.iso(commits[pull.commitIndex].date), "user": ["login": pull.login],
                "labels": pull.labels.map { ["name": $0] }, "base": ["ref": "main"],
            ]
        }

        private func reply(_ request: URLRequest, _ object: [String: Any], status: Int = 200) -> (Data, HTTPURLResponse)
        {
            response(request, object, status: status)
        }

        private func reply(_ request: URLRequest, _ array: [[String: Any]]) -> (Data, HTTPURLResponse) {
            response(request, array, status: 200)
        }

        private func response(_ request: URLRequest, _ object: Any, status: Int) -> (Data, HTTPURLResponse) {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }

        private nonisolated static func iso(_ date: Date) -> String { date.formatted(.iso8601) }

        private nonisolated static func sha(_ seed: String) -> String {
            Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    extension GitHubServices {
        /// Signed in as "demo" against `DemoGitHub`, with a throwaway cache.
        static func demo() -> GitHubServices {
            let account = GitHubAccount(
                id: 1, login: "demo", name: "Demo", htmlURL: URL(string: "https://github.com/demo")!)
            let tokens = TokenSet(
                accessToken: Secret("demo-token"), refreshToken: nil, accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil, account: account)
            return GitHubServices(
                configuration: GitHubConfiguration(clientID: "demo", appSlug: nil), transport: DemoGitHub.shared,
                credentials: InMemoryCredentialStore(tokens),
                // A fresh cache per launch, so one run's snapshot never shows up as another's cached data.
                cache: SnapshotCache(
                    directory: FileManager.default.temporaryDirectory.appending(
                        path: "RelvoraDemoCache-\(UUID().uuidString)")))
        }
    }

    /// Steps a release plan through the workflow at launch for UI checks (`-RelvoraDemoScenario <name>`).
    enum DemoScenario: String {
        /// Repository, commit, tag, generated notes, and a GitHub check.
        case prepare
        /// `prepare`, then the confirmation sheet.
        case review
        case draft
        case published
        /// The tag moved before publication: the plan needs the user's decision.
        case mismatch
        /// The create response is lost: the plan needs reconciliation.
        case timeout
        /// `published`, then Release History.
        case history
        /// `draft`, then the publish confirmation.
        case publish
        /// The tag moved before publication: the publish confirmation shows why it can't go ahead.
        case publishBlocked

        @MainActor private static var hasRun = false

        @MainActor
        func run(on release: ReleaseModel, app: AppModel) async {
            guard !Self.hasRun, release.plan?.status == .planned else { return }
            Self.hasRun = true
            // The launch option connects the demo repository just after the workspace loads.
            for _ in 0..<50 where release.workspace.connections.isEmpty || !release.github.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let connection = release.workspace.connections.first else { return }
            await release.setRepository(connection.id)  // loads branches and commits
            guard let latest = release.commits.first?.sha else {
                release.errorMessage = "Demo scenario: no commits loaded."
                return
            }
            await release.setTargetCommit(latest)
            if let notes = await release.generatedNotes() { release.notesText = notes }
            await release.runCheck()
            guard self != .prepare else { return }
            await release.beginReview()
            guard self != .review, var review = release.review else { return }
            release.review = nil
            review.confirmsIncompleteTasks = true
            if self == .timeout { await DemoGitHub.shared.dropNextCreate() }
            if case .failure(let error) = await release.createDraft(review),
                error as? ReleaseWorkflowError != .outcomeUnknown
            {
                release.errorMessage = AppAlert.message(for: error)
            }
            switch self {
            case .published, .history:
                await DemoGitHub.shared.publishAll()
                await release.reconcile()
                if self == .history, let snapshot = release.snapshots.last { app.showInHistory(snapshot.id) }
            case .mismatch:
                if let tag = release.plan?.tagName { await DemoGitHub.shared.moveTagBeforePublishing(tag) }
                await DemoGitHub.shared.publishAll()
                await release.reconcile()
            case .publish:
                await release.beginPublish()
            case .publishBlocked:
                if let tag = release.plan?.tagName { await DemoGitHub.shared.moveTagBeforePublishing(tag) }
                await release.beginPublish()
            default:
                break
            }
        }
    }
#endif
