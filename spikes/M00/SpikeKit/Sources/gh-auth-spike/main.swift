// M00 live GitHub App validation.
//   validate: device-flow login (one browser approval) -> discovery -> read probe -> refresh WITHOUT client secret
//             -> optional draft-release write probe (--write)
//   probe:    same discovery/read/write probes, reusing the token saved by `validate` (no new approval).
//             Run it with the same build as `validate`: a rebuilt binary has a new code signature and
//             reading the saved keychain item would prompt.
// Tokens are stored in the login keychain and never printed. Only status codes, permission headers, and counts are.
//
// Usage: GITHUB_APP_CLIENT_ID=Iv23li... swift run gh-auth-spike validate --repo owner/name [--write]
//        swift run gh-auth-spike probe --repo owner/name [--write]
//        swift run gh-auth-spike forget

import CredentialSpike
import Foundation
import GitHubAuthSpike

let keychain = KeychainCredentialStore(service: "ReleaseManager.M00Spike.github", flavor: .fileBased)
let arguments = CommandLine.arguments.dropFirst()

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}

func report(_ result: ProbeResult, note: String = "") {
    let status = result.error.map { "\(result.status) \($0)" } ?? "\(result.status) OK"
    let permissions = result.acceptedPermissions.map { " needs[\($0)]" } ?? ""
    let remaining = result.rateLimit.remaining.map { " rate=\($0)/\(result.rateLimit.limit ?? 0)" } ?? ""
    print("  \(result.method) /\(result.path) -> \(status)\(permissions)\(remaining)\(note.isEmpty ? "" : "  \(note)")")
}

func jsonArray(_ data: Data) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func login(clientID: String) async throws -> UserAccessToken {
    print("[1] Device flow")
    let flow = DeviceFlowClient(clientID: clientID)
    let code = try await flow.requestDeviceCode()
    print("  Open \(code.verificationURI.absoluteString) and enter code: \(code.userCode)")
    print("  (code valid for \(code.expiresIn)s, polling every \(code.interval)s)")
    fflush(stdout)
    let token = try await flow.pollForAccessToken(code)
    try keychain.write(Data(token.accessToken.rawValue.utf8), account: "access_token")
    print("  Authorized. token kind=\(token.accessToken.kindPrefix) expires_in=\(token.expiresIn.map(String.init) ?? "never")"
        + " refresh_token=\(token.refreshToken == nil ? "absent" : "present") refresh_expires_in=\(token.refreshTokenExpiresIn.map(String.init) ?? "n/a")")
    print("  Stored in login keychain (value not shown).")
    return token
}

func discover(_ api: GitHubRESTProbe) async throws {
    print("[2] Account and installations")
    let user = try await api.get("user")
    report(user, note: "login=\(jsonObject(user.body)["login"] as? String ?? "?")")
    let installations = try await api.get("user/installations")
    let installationList = jsonObject(installations.body)["installations"] as? [[String: Any]] ?? []
    report(installations, note: "installations=\(installationList.count)")
    for installation in installationList {
        guard let id = installation["id"] as? Int else { continue }
        let account = (installation["account"] as? [String: Any])?["login"] as? String ?? "?"
        let selection = installation["repository_selection"] as? String ?? "?"
        let permissions = (installation["permissions"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let repos = try await api.get("user/installations/\(id)/repositories", query: [URLQueryItem(name: "per_page", value: "100")])
        let names = (jsonObject(repos.body)["repositories"] as? [[String: Any]] ?? []).compactMap { $0["full_name"] as? String }
        report(repos, note: "account=\(account) selection=\(selection) granted=[\(permissions)] repos=\(names)")
    }
}

/// Returns the default branch head SHA, if the repository has commits.
func readProbe(_ api: GitHubRESTProbe, repo: String) async throws -> String? {
    print("[3] Read probe for \(repo)")
    let metadata = try await api.get("repos/\(repo)")
    let repoJSON = jsonObject(metadata.body)
    let defaultBranch = repoJSON["default_branch"] as? String ?? "main"
    report(metadata, note: "id=\(repoJSON["id"] as? Int ?? -1) private=\(repoJSON["private"] as? Bool ?? false) default=\(defaultBranch) push=\((repoJSON["permissions"] as? [String: Any])?["push"] as? Bool ?? false)")

    let releases = try await api.get("repos/\(repo)/releases", query: [URLQueryItem(name: "per_page", value: "30")])
    let releaseList = jsonArray(releases.body)
    report(releases, note: "count=\(releaseList.count) drafts=\(releaseList.filter { $0["draft"] as? Bool == true }.count)")

    let tags = try await api.get("repos/\(repo)/tags", query: [URLQueryItem(name: "per_page", value: "30")])
    let tagNames = jsonArray(tags.body).compactMap { $0["name"] as? String }
    report(tags, note: "count=\(tagNames.count)")

    report(try await api.get("repos/\(repo)/branches", query: [URLQueryItem(name: "per_page", value: "5")]))

    let commits = try await api.get("repos/\(repo)/commits", query: [URLQueryItem(name: "per_page", value: "5")])
    let headSHA = jsonArray(commits.body).first?["sha"] as? String
    report(commits, note: headSHA == nil ? "(no commits)" : "")

    if tagNames.count >= 2 {
        let compare = try await api.get("repos/\(repo)/compare/\(tagNames[1])...\(tagNames[0])", query: [URLQueryItem(name: "per_page", value: "100")])
        let compareJSON = jsonObject(compare.body)
        report(compare, note: "total_commits=\(compareJSON["total_commits"] as? Int ?? -1) page_commits=\((compareJSON["commits"] as? [Any])?.count ?? -1)")
    } else {
        print("  (compare skipped: repository has fewer than two tags)")
    }
    if let headSHA {
        report(try await api.get("repos/\(repo)/commits/\(headSHA)/pulls"))
        report(try await api.get("repos/\(repo)/git/matching-refs/tags"))
    }
    report(try await api.get("repos/\(repo)/pulls", query: [URLQueryItem(name: "state", value: "closed"), URLQueryItem(name: "per_page", value: "5")]))
    // Non-mutating POST: renders notes, creates nothing.
    report(try await api.send("POST", "repos/\(repo)/releases/generate-notes", json: ["tag_name": "m00-probe-unreleased", "target_commitish": defaultBranch]))
    return headSHA
}

func refreshCheck(clientID: String, token: UserAccessToken) async throws {
    print("[4] Refresh WITHOUT client secret")
    guard let refreshToken = token.refreshToken else {
        print("  No refresh token issued (user-token expiration is disabled for this app).")
        return
    }
    do {
        let refreshed = try await DeviceFlowClient(clientID: clientID).refreshWithoutClientSecret(refreshToken)
        try keychain.write(Data(refreshed.accessToken.rawValue.utf8), account: "access_token")
        print("  Refresh SUCCEEDED without a secret. new kind=\(refreshed.accessToken.kindPrefix) expires_in=\(refreshed.expiresIn.map(String.init) ?? "never")"
            + " new refresh_token=\(refreshed.refreshToken == nil ? "absent" : "present")")
        report(try await GitHubRESTProbe(token: refreshed.accessToken).get("user"), note: "new token works")
        report(try await GitHubRESTProbe(token: token.accessToken).get("user"), note: "old token after refresh (expect 401)")
    } catch {
        print("  Refresh FAILED without a secret: \(error)")
    }
}

func writeProbe(_ api: GitHubRESTProbe, repo: String, headSHA: String?) async throws {
    print("[5] Draft-release write probe")
    guard let headSHA else { print("  Skipped: repository has no commits to target."); return }
    let tagName = "m00-spike-\(Int(Date().timeIntervalSince1970))"
    report(try await api.get("repos/\(repo)/git/ref/tags/\(tagName)"), note: "tag before draft (expect 404)")
    let draft = try await api.send("POST", "repos/\(repo)/releases", json: [
        "tag_name": tagName,
        "target_commitish": headSHA,
        "name": "M00 spike draft (safe to delete)",
        "body": "Created by the Release Manager M00 permission probe.",
        "draft": true,
    ])
    let draftJSON = jsonObject(draft.body)
    report(draft, note: "draft=\(draftJSON["draft"] as? Bool ?? false) target_is_sha=\((draftJSON["target_commitish"] as? String) == headSHA)")
    report(try await api.get("repos/\(repo)/git/ref/tags/\(tagName)"), note: "tag after draft (404 = draft does not create tag)")
    let duplicate = try await api.send("POST", "repos/\(repo)/releases", json: ["tag_name": tagName, "target_commitish": headSHA, "draft": true])
    let duplicateErrors = (jsonObject(duplicate.body)["errors"] as? [[String: Any]] ?? []).map { "\($0["code"] ?? "?")/\($0["field"] ?? "?")" }
    report(duplicate, note: "second draft, same tag: errors=\(duplicateErrors)")
    if let duplicateID = jsonObject(duplicate.body)["id"] as? Int {
        report(try await api.send("DELETE", "repos/\(repo)/releases/\(duplicateID)", json: nil), note: "cleanup duplicate")
    }
    if let id = draftJSON["id"] as? Int {
        report(try await api.send("DELETE", "repos/\(repo)/releases/\(id)", json: nil), note: "cleanup draft")
        report(try await api.get("repos/\(repo)/git/ref/tags/\(tagName)"), note: "tag after cleanup (expect 404)")
    }
}

func savedToken() throws -> Secret {
    guard let data = try keychain.read(account: "access_token") else {
        print("No saved token. Run `validate` first.")
        exit(1)
    }
    return Secret(String(decoding: data, as: UTF8.self))
}

let clientID = ProcessInfo.processInfo.environment["GITHUB_APP_CLIENT_ID"]
let write = arguments.contains("--write")
do {
    switch (arguments.first, option("--repo")) {
    case ("validate", let repo?) where clientID != nil:
        let token = try await login(clientID: clientID!)
        let api = GitHubRESTProbe(token: token.accessToken)
        try await discover(api)
        let headSHA = try await readProbe(api, repo: repo)
        try await refreshCheck(clientID: clientID!, token: token)
        if write {
            try await writeProbe(GitHubRESTProbe(token: try savedToken()), repo: repo, headSHA: headSHA)
        } else {
            print("[5] Write probe skipped (pass --write to create and delete a draft release).")
        }
    case ("probe", let repo?):
        let api = GitHubRESTProbe(token: try savedToken())
        try await discover(api)
        let headSHA = try await readProbe(api, repo: repo)
        if write { try await writeProbe(api, repo: repo, headSHA: headSHA) }
    case ("forget", _):
        try keychain.delete(account: "access_token")
        print("Local token removed. Revoke the authorization itself at https://github.com/settings/apps/authorizations")
    default:
        print("Usage: GITHUB_APP_CLIENT_ID=<id> gh-auth-spike validate --repo owner/name [--write]")
        print("       gh-auth-spike probe --repo owner/name [--write]   (reuses the saved token)")
        print("       gh-auth-spike forget")
        exit(64)
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
