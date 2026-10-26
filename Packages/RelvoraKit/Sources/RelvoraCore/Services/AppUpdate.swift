import Foundation

/// A release of Relvora itself, as the update check reads it from Relvora's own repository (ADR 0017).
public struct AppRelease: Sendable, Hashable {
    /// A file attached to the release.
    public struct Asset: Sendable, Hashable {
        public let id: Int64
        public let name: String
        public let size: Int64
        /// GitHub's checksum of the file, such as `sha256:…`; `nil` for files uploaded before GitHub kept one.
        public let digest: String?
        /// `false` while the file is still uploading.
        public let isUploaded: Bool

        public init(id: Int64, name: String, size: Int64, digest: String?, isUploaded: Bool) {
            self.id = id
            self.name = name
            self.size = size
            self.digest = digest
            self.isUploaded = isUploaded
        }
    }

    public let tagName: String
    public let name: String?
    /// The release notes, in Markdown.
    public let notes: String?
    public let htmlURL: URL
    public let publishedAt: Date?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [Asset]

    public init(
        tagName: String, name: String?, notes: String?, htmlURL: URL, publishedAt: Date?, isDraft: Bool,
        isPrerelease: Bool, assets: [Asset]
    ) {
        self.tagName = tagName
        self.name = name
        self.notes = notes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    /// The version in the tag (`v1.2.0` → 1.2.0); `nil` for a tag that isn't a version.
    public var version: SemanticVersion? { SemanticVersion(tagName) }
}

/// A newer Relvora, ready to download: the app's zip and the checksum file the release workflow attaches with it.
public struct AppUpdate: Sendable, Hashable {
    public let version: SemanticVersion
    public let release: AppRelease
    public let archive: AppRelease.Asset
    public let checksum: AppRelease.Asset

    public init(version: SemanticVersion, release: AppRelease, archive: AppRelease.Asset, checksum: AppRelease.Asset) {
        self.version = version
        self.release = release
        self.archive = archive
        self.checksum = checksum
    }
}

public enum AppUpdateCheck: Sendable, Equatable {
    /// No newer version; `latest` is the newest release found, if any.
    case upToDate(latest: SemanticVersion?)
    case available(AppUpdate)
    /// A newer version is published, but its build isn't attached yet (the release workflow takes a few minutes).
    case building(SemanticVersion)
}

/// Which release to offer, and how to check what was downloaded.
///
/// Only published, stable releases count: drafts, prereleases, and tags that aren't versions are ignored. The release
/// workflow names its files `Relvora-<version>.zip` and `Relvora-<version>.zip.sha256` (`scripts/release`).
public enum AppUpdateRules {
    public static func archiveName(for version: SemanticVersion) -> String { "Relvora-\(version).zip" }

    public static func checksumName(for version: SemanticVersion) -> String { archiveName(for: version) + ".sha256" }

    public static func check(_ releases: [AppRelease], current: SemanticVersion) -> AppUpdateCheck {
        let stable = releases.compactMap { release -> (SemanticVersion, AppRelease)? in
            guard !release.isDraft, !release.isPrerelease, let version = release.version, !version.isPrerelease
            else { return nil }
            return (version, release)
        }
        .sorted { $0.0 > $1.0 }

        for (version, release) in stable where version > current {
            if let update = update(version, release) { return .available(update) }
        }
        if let newest = stable.first, newest.0 > current { return .building(newest.0) }
        return .upToDate(latest: stable.first?.0)
    }

    /// The release's zip and checksum file, once both have finished uploading.
    private static func update(_ version: SemanticVersion, _ release: AppRelease) -> AppUpdate? {
        func asset(_ name: String) -> AppRelease.Asset? {
            release.assets.first { $0.name == name && $0.isUploaded && $0.size > 0 }
        }
        guard let archive = asset(archiveName(for: version)), let checksum = asset(checksumName(for: version)) else {
            return nil
        }
        return AppUpdate(version: version, release: release, archive: archive, checksum: checksum)
    }

    /// The SHA-256 in a `shasum -a 256` line (`<64 hex digits>  <file name>`), lowercased. `nil` unless the line names
    /// `archiveName` exactly.
    public static func sha256(inChecksumFile text: String, archiveName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingPrefix("*")
            guard name == archiveName, isSHA256(parts[0]) else { continue }
            return parts[0].lowercased()
        }
        return nil
    }

    /// The SHA-256 in a GitHub asset digest (`sha256:<64 hex digits>`), lowercased; `nil` for other digests.
    public static func sha256(inDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        return isSHA256(hex) ? hex.lowercased() : nil
    }

    private static func isSHA256(_ text: some StringProtocol) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}
