import Foundation
import Observation
import RelvoraCore
import RelvoraWidgetData
import SwiftUI
import WidgetKit
import os

extension View {
    /// The desktop widget (ADR 0024): keeps its snapshot up to date, and opens what a click on it names.
    func desktopWidget(_ model: AppModel) -> some View {
        modifier(DesktopWidgetSupport(model: model))
    }
}

private struct DesktopWidgetSupport: ViewModifier {
    let model: AppModel
    /// A link that arrived before the projects were loaded, such as the one that launched Relvora.
    @State private var link: WidgetLink?

    func body(content: Content) -> some View {
        content
            .onAppear { WidgetSnapshotWriter.shared.start(model) }
            .onOpenURL { url in
                link = WidgetLink(url: url)
                openLink()
            }
            .onChange(of: model.hasLoaded) { openLink() }
    }

    private func openLink() {
        guard model.hasLoaded, let link else { return }
        self.link = nil
        model.openWidgetLink(link)
    }
}

extension AppModel {
    /// A project the data no longer has (deleted, or named by another copy's widget) opens the Dashboard.
    func openWidgetLink(_ link: WidgetLink) {
        switch link {
        case .dashboard:
            navigationRequest = .dashboard
        case .project(let id):
            if projects.contains(where: { $0.id == id }) {
                openProject(id)
            } else {
                navigationRequest = .dashboard
            }
        }
    }
}

/// Writes the desktop widget's snapshot whenever the projects or their numbers change, then asks WidgetKit to reload
/// the widget (ADR 0024). The widget reads only this file, in the App Group container the two share.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()
    /// Changes come in bursts (every project's numbers at launch, a card moved across the board): one write, a second
    /// after the last.
    static let delay: Duration = .seconds(1)

    private static let log = Logger(subsystem: "com.erickpea29.Relvora", category: "widget")

    private weak var model: AppModel?
    private var store: WidgetSnapshotStore?
    /// A test folder is never read by the widget, so writing there doesn't reload it.
    private var reloadsWidget = true
    private var written: WidgetSnapshot?
    private var pending: Task<Void, Never>?

    private init() {}

    /// Follows `model` for as long as Relvora runs, even with its window closed. Only the first call counts.
    func start(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        guard model.startupError == nil, let destination = Self.destination(for: model.options) else { return }
        store = destination.store
        reloadsWidget = destination.reloadsWidget
        Self.log.info("Widget snapshot: \(destination.store.fileURL.path(percentEncoded: false), privacy: .public)")
        changed()
    }

    /// Where this copy writes, if anywhere. Only a copy using the real data writes to the shared container: a test copy
    /// (an in-memory or test store, sample data, a test settings suite) never does, so the widget never shows its data.
    /// An ad-hoc signed copy has no usable container (`WidgetSnapshotStore.shared()`).
    private static func destination(for options: LaunchOptions) -> (store: WidgetSnapshotStore, reloadsWidget: Bool)? {
        #if DEBUG
            // `-RelvoraWidgetTestFolder <name>`: the snapshot goes to a folder of that name that the widget never reads,
            // in the shared container when there is one, to check what would be written.
            if let name = UserDefaults.standard.string(forKey: "RelvoraWidgetTestFolder"), !name.isEmpty,
                name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            {
                let base = WidgetSnapshotStore.sharedContainerURL() ?? URL.temporaryDirectory
                let folder = base.appending(path: "Widget Tests", directoryHint: .isDirectory)
                    .appending(path: name, directoryHint: .isDirectory)
                return (WidgetSnapshotStore(folder: folder), false)
            }
        #endif
        let isTestCopy =
            options.inMemoryStore || options.seedSampleData || options.defaultsSuite != nil
            || options.storeName != LaunchOptions().storeName
        guard !isTestCopy, let store = WidgetSnapshotStore.shared() else { return nil }
        return (store, true)
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.hasLoaded
            _ = model.projects
            _ = model.groups
            _ = model.stats
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        observe()
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    /// Writes only once every project's numbers are loaded, and only what changed.
    private func write() {
        guard let model, model.hasLoaded, let store else { return }
        let snapshot = WidgetSnapshot.make(
            projects: model.projects, groups: model.groups,
            progress: model.stats.mapValues { stats in
                WidgetSnapshot.Progress(
                    activePlan: stats.activePlan, versionTaskCount: stats.versionTaskCount,
                    versionDoneCount: stats.versionCompletedCount, lastRelease: stats.lastRelease)
            })
        guard snapshot != written else { return }
        do {
            try store.write(snapshot)
            written = snapshot
            Self.log.info("Wrote the widget snapshot: \(snapshot.projects.count) projects")
            #if DEBUG
                // A test folder's snapshot holds only test data. It's logged whole, so checks can read it.
                if !reloadsWidget, let data = try? WidgetSnapshotStore.encode(snapshot) {
                    Self.log.info("Test snapshot: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                }
            #endif
            if reloadsWidget { WidgetCenter.shared.reloadAllTimelines() }
        } catch {
            Self.log.error("Couldn’t write the widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
