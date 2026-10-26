import AppKit
import CryptoKit
import Foundation
import GitHubIntegration
import Observation
import RelvoraCore
import RelvoraUpdates
import os

/// Finds a newer Relvora in its own repository's releases and installs it (ADR 0017).
///
/// Checking reads the releases with the user's GitHub sign-in. Installing saves a backup of the data, downloads the
/// zip, checks it against the release's checksum, and hands it to the updater service inside the app, which checks
/// the signature and replaces the app. Then Relvora opens the new version and quits.
@Observable
final class UpdateModel {
    enum Step: Int, CaseIterable, Identifiable {
        case backingUp, downloading, verifying, installing, relaunching

        var id: Self { self }

        var title: String {
            switch self {
            case .backingUp: "Saving a backup of your data"
            case .downloading: "Downloading"
            case .verifying: "Checking the download against the release’s checksum"
            case .installing: "Checking the signature and installing"
            case .relaunching: "Opening the new version"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(latest: SemanticVersion?)
        /// Published, but its build isn't attached yet.
        case building(SemanticVersion)
        case available(AppUpdate)
        case installing(AppUpdate, Step)
        /// `update` is `nil` when the check itself failed.
        case failed(AppUpdate?, message: String)
        /// Updates can't be checked in this build or without a sign-in.
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    var isPresented = false
    /// A newer version found by the last check and not skipped: the sidebar offers it.
    private(set) var offered: AppUpdate?
    private(set) var lastChecked: Date?
    /// Why the last automatic check failed, for Settings.
    private(set) var lastProblem: String?

    let currentVersion: SemanticVersion?
    @ObservationIgnored private let github: GitHubModel
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let isDemo: Bool
    /// Read once, when first needed.
    @ObservationIgnored private lazy var isDeveloperIDSigned = CodeSignature.isOwnCodeDeveloperID()
    @ObservationIgnored private var checkedThisLaunch = false

    private enum Key {
        static let lastChecked = "lastUpdateCheck"
        static let skippedVersion = "skippedUpdateVersion"
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Never logs tokens or file contents.
    private static let log = Logger(subsystem: "com.erickpea29.Relvora", category: "updates")

    init(github: GitHubModel, preferences: Preferences, isDemo: Bool) {
        self.github = github
        self.preferences = preferences
        self.isDemo = isDemo
        currentVersion = AppModel.appVersion.flatMap(SemanticVersion.init)
        lastChecked = preferences.defaults.object(forKey: Key.lastChecked) as? Date
    }

    var repository: String? { github.services?.updateRepository }

    /// Why this copy can't check for updates; `nil` when it can.
    var unavailableReason: String? {
        guard github.services != nil, let repository else {
            return "This build of Relvora doesn’t name a GitHub repository to update from."
        }
        #if DEBUG
            guard isDemo else { return "Updates are off in development builds. Release builds update themselves." }
        #else
            guard isDeveloperIDSigned else {
                return "This copy of Relvora isn’t signed with Developer ID, so it can’t check an update’s signature. "
                    + "Install a release from GitHub."
            }
        #endif
        guard currentVersion != nil else { return "This build of Relvora has no version number." }
        guard github.isConnected else {
            return "Sign in to GitHub in Settings › GitHub. Relvora reads its updates from \(repository) with your "
                + "sign-in."
        }
        return nil
    }

    var isInstalling: Bool {
        if case .installing = phase { true } else { false }
    }

    // MARK: Checking

    /// Checks at launch, then once a day while Relvora runs, when automatic checks are on. Runs until cancelled.
    func runAutomaticChecks() async {
        try? await Task.sleep(for: .seconds(5))
        while !Task.isCancelled {
            if preferences.checksForUpdates, isDue { await check(manual: false) }
            try? await Task.sleep(for: .seconds(60 * 60))
        }
    }

    private var isDue: Bool {
        guard checkedThisLaunch, let lastChecked else { return true }
        return Date.now.timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    /// A manual check shows its result in the update sheet, skipped versions included. An automatic one only offers a
    /// new version in the sidebar.
    func check(manual: Bool) async {
        if manual { isPresented = true }
        guard !isInstalling, phase != .checking else { return }
        if let reason = unavailableReason {
            if manual { phase = .unavailable(reason) }
            return
        }
        guard let services = github.services, let repository, let currentVersion else { return }
        if manual { phase = .checking }
        checkedThisLaunch = true
        do {
            let result = AppUpdateRules.check(
                try await services.api.appReleases(repository: repository), current: currentVersion)
            lastChecked = .now
            preferences.defaults.set(lastChecked, forKey: Key.lastChecked)
            lastProblem = nil
            Self.log.notice("Checked for updates: \(String(describing: result), privacy: .public)")
            switch result {
            case .available(let update):
                let skipped = preferences.defaults.string(forKey: Key.skippedVersion) == update.version.description
                offered = manual || !skipped ? update : nil
                if manual { phase = .available(update) }
            case .upToDate(let latest):
                offered = nil
                if manual { phase = .upToDate(latest: latest) }
            case .building(let version):
                if manual { phase = .building(version) }
            }
        } catch {
            let message = Self.checkFailure(error, repository: repository)
            Self.log.error("Update check failed: \(String(describing: error), privacy: .public)")
            lastProblem = message
            if manual { phase = .failed(nil, message: message) }
        }
    }

    private static func checkFailure(_ error: GitHubError, repository: String) -> String {
        switch error {
        case .notFound, .forbidden:
            "Your GitHub sign-in can’t read \(repository), where Relvora’s updates are published. Add the repository "
                + "to the Relvora GitHub App’s installation, or ask its owner for access."
        default:
            AppAlert.message(for: error)
        }
    }

    /// Opens the sheet on the version the sidebar offers.
    func showOffered() {
        guard let offered, !isInstalling else { return }
        phase = .available(offered)
        isPresented = true
    }

    /// Automatic checks stop offering this version; a manual check still shows it.
    func skip(_ update: AppUpdate) {
        preferences.defaults.set(update.version.description, forKey: Key.skippedVersion)
        offered = nil
        dismiss()
    }

    func dismiss() {
        guard !isInstalling else { return }
        isPresented = false
        if case .available = phase { return }
        phase = .idle
    }

    // MARK: Installing

    /// Installs `update`, then relaunches. `saveBackup` saves the data first and returns the file: an update can
    /// change the data so an older Relvora can't open it.
    func install(_ update: AppUpdate, saveBackup: () async throws -> URL) async {
        guard let services = github.services, let repository, let bundleID = Bundle.main.bundleIdentifier else {
            return
        }
        if let problem = UpdateLocation.problem(for: Bundle.main.bundleURL) {
            phase = .failed(update, message: AppAlert.message(for: UpdateInstallError.notInstallable(problem)))
            return
        }
        do {
            phase = .installing(update, .backingUp)
            let backup: URL
            do {
                backup = try await saveBackup()
            } catch {
                throw UpdateFailure(
                    "Relvora couldn’t save a backup of your data, so it didn’t install the update. "
                        + AppAlert.message(for: error))
            }

            phase = .installing(update, .downloading)
            let checksumFile = try await services.api.releaseAsset(repository: repository, id: update.checksum.id)
            guard
                let expected = AppUpdateRules.sha256(
                    inChecksumFile: String(decoding: checksumFile, as: UTF8.self), archiveName: update.archive.name),
                AppUpdateRules.sha256(inDigest: update.archive.digest).map({ $0 == expected }) ?? true
            else { throw UpdateInstallError.checksumMismatch }
            let archive = try await services.api.releaseAsset(repository: repository, id: update.archive.id)

            phase = .installing(update, .verifying)
            guard SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw UpdateInstallError.checksumMismatch
            }
            let file = try Self.downloadFolder().appending(path: update.archive.name)
            try archive.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }

            phase = .installing(update, .installing)
            try await UpdaterClient(appBundleID: bundleID).install(
                archive: file, version: update.version, sha256: expected)

            phase = .installing(update, .relaunching)
            offered = nil
            try await relaunch(installed: update.version, backup: backup)
        } catch {
            Self.log.error("Update \(update.version.description, privacy: .public) failed: \(error, privacy: .private)")
            phase = .failed(update, message: AppAlert.message(for: error))
        }
    }

    /// Opens the new version and quits. The new copy waits for this one to quit before it opens the data; the ticket
    /// tells it to.
    private func relaunch(installed version: SemanticVersion, backup: URL) async throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var arguments: [String] = []
        #if DEBUG
            arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        #endif
        RelaunchTicket(
            previousPID: getpid(), version: version.description, backupPath: backup.path, arguments: arguments
        ).save()

        let others = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        // Not waiting for the new copy to finish launching: it waits for this one first.
        var started = false
        for _ in 0..<100 where !started {
            try? await Task.sleep(for: .milliseconds(50))
            started = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
                !others.contains($0.processIdentifier)
            }
        }
        guard started else {
            RelaunchTicket.clear()
            throw UpdateFailure("Relvora \(version) is installed, but it didn’t open. Quit Relvora and open it again.")
        }
        // An open sheet stops the app from quitting.
        isPresented = false
        try? await Task.sleep(for: .milliseconds(300))
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    /// Emptied before each download, so a download that never finished doesn't stay.
    private static func downloadFolder() throws -> URL {
        let folder = URL.cachesDirectory.appending(path: "Updates", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: After relaunching

    /// When an update opened this copy, waits for the copy that installed it to quit, so the two never have the data
    /// open together. Called before the data is opened.
    static func waitForPreviousCopy(_ ticket: RelaunchTicket, timeout: TimeInterval = 20) {
        guard ticket.previousPID > 0, ticket.previousPID != getpid() else { return }
        let start = Date.now
        while Date.now.timeIntervalSince(start) < timeout,
            let previous = NSRunningApplication(processIdentifier: ticket.previousPID),
            previous.bundleIdentifier == Bundle.main.bundleIdentifier, !previous.isTerminated
        {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let waited = Int(Date.now.timeIntervalSince(start) * 1000)
        log.notice(
            "Opened by the update to \(ticket.version, privacy: .public); waited \(waited) ms for the previous copy")
    }

    /// "Relvora is updated", after the relaunch that installed this version.
    static func installedNotice(_ ticket: RelaunchTicket) -> AppAlert? {
        guard ticket.version == AppModel.appVersion else { return nil }
        let backup = ticket.backupPath.map { URL(filePath: $0) }
        return AppAlert(
            title: "Relvora is updated to \(ticket.version)",
            message: "The previous version is in the Trash. "
                + (backup.map { "Your data from before the update was saved as “\($0.lastPathComponent)”." } ?? ""),
            revealURL: backup)
    }
}

/// A failed step, in words for the user.
private struct UpdateFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
