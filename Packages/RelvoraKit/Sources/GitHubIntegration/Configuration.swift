import Foundation
import os

/// Public configuration of the Relvora GitHub App. Contains no secrets: a client ID is public by design.
public struct GitHubConfiguration: Sendable {
    public let clientID: String
    /// URL name of the GitHub App, used for its install page.
    public let appSlug: String?
    public let apiBaseURL: URL
    public let webBaseURL: URL
    /// Pinned REST API version (ADR 0009).
    public let apiVersion: String

    public init(
        clientID: String,
        appSlug: String?,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        webBaseURL: URL = URL(string: "https://github.com")!,
        apiVersion: String = "2022-11-28"
    ) {
        self.clientID = clientID
        self.appSlug = appSlug
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
        self.apiVersion = apiVersion
    }

    /// Where the user adds repositories to the app's installation.
    public var installURL: URL {
        appSlug.map { webBaseURL.appending(path: "apps/\($0)/installations/new") }
            ?? webBaseURL.appending(path: "settings/installations")
    }

    /// Where the user revokes Relvora's authorization (the app itself cannot without a client secret).
    public var authorizationsURL: URL { webBaseURL.appending(path: "settings/apps/authorizations") }
}

enum Log {
    /// Logs never include tokens, headers, or response bodies; paths are marked private.
    static let github = Logger(subsystem: "com.erickpea29.Relvora", category: "github")
}
