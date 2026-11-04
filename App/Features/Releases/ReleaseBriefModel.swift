import Foundation
import Observation
import RelvoraCore

/// Release briefs written by the on-device model, per plan (ADR 0025). Kept while Relvora runs: never saved, synced,
/// or backed up. Shown briefs are always checked against the plan's current facts.
@Observable
final class ReleaseBriefModel {
    struct Written: Equatable {
        /// The facts it was written for.
        let fingerprint: String
        let composition: ReleaseBriefComposition
        let isComplete: Bool
        let writtenAt: Date?
    }

    struct Failure: Equatable {
        let fingerprint: String
        let message: String
    }

    private(set) var written: [UUID: Written] = [:]
    private(set) var writing: Set<UUID> = []
    /// The last brief that couldn't be written. It isn't tried again for the same facts until the user asks.
    private(set) var failures: [UUID: Failure] = [:]
    /// Apple Intelligence can be turned on, or finish downloading, while Relvora runs: read again when a brief shows.
    private(set) var status: ReleaseBriefWriterStatus

    @ObservationIgnored private let writer: any ReleaseBriefWriter
    @ObservationIgnored private let preferences: Preferences
    /// The latest write of each plan. An earlier write that is still finishing never overwrites a later one.
    @ObservationIgnored private var generations: [UUID: Int] = [:]

    init(writer: any ReleaseBriefWriter, preferences: Preferences) {
        self.writer = writer
        self.preferences = preferences
        status = writer.status
    }

    /// Briefs are written by the model: on in Settings, and the model is available on this Mac.
    var isEnabled: Bool { preferences.writesReleaseBriefs && status == .available }

    func refreshStatus() {
        let current = writer.status
        if current != status { status = current }
    }

    /// The model's brief when there is one (still being written, or written for earlier facts while it's rewritten),
    /// otherwise the standard one.
    func brief(for planID: UUID, facts: ReleaseBriefFacts) -> ReleaseBrief {
        guard preferences.writesReleaseBriefs, let entry = written[planID] else {
            return ReleaseBriefComposer.standard(facts)
        }
        return ReleaseBriefComposer.resolve(entry.composition, facts: facts, isComplete: entry.isComplete)
    }

    func isWriting(_ planID: UUID) -> Bool { writing.contains(planID) }

    /// Whether to write the plan's brief now: none yet, or one written for other facts. Not again for facts it just
    /// failed on.
    func needsWriting(_ planID: UUID, facts: ReleaseBriefFacts) -> Bool {
        guard isEnabled, !writing.contains(planID), failures[planID]?.fingerprint != facts.fingerprint else {
            return false
        }
        guard let entry = written[planID] else { return true }
        return !entry.isComplete || entry.fingerprint != facts.fingerprint
    }

    /// Writes the plan's brief. The first one streams into view; a rewrite replaces the brief shown once it's complete,
    /// so the brief never empties while the plan changes.
    func write(_ planID: UUID, facts: ReleaseBriefFacts) async {
        guard isEnabled else { return }
        let generation = (generations[planID] ?? 0) + 1
        generations[planID] = generation
        func isLatest() -> Bool { generations[planID] == generation && !Task.isCancelled }

        writing.insert(planID)
        failures[planID] = nil
        defer { if generations[planID] == generation { writing.remove(planID) } }

        let streamsIntoView = written[planID]?.isComplete != true
        var latest: ReleaseBriefComposition?
        do {
            for try await composition in writer.write(facts) {
                guard isLatest() else { break }
                latest = composition
                if streamsIntoView {
                    written[planID] = Written(
                        fingerprint: facts.fingerprint, composition: composition, isComplete: false, writtenAt: nil)
                }
            }
            guard isLatest(), let latest else {
                if streamsIntoView && generations[planID] == generation { written[planID] = nil }
                return
            }
            written[planID] = Written(
                fingerprint: facts.fingerprint, composition: latest, isComplete: true, writtenAt: .now)
        } catch {
            guard generations[planID] == generation else { return }
            if streamsIntoView { written[planID] = nil }
            if !Task.isCancelled {
                failures[planID] = Failure(
                    fingerprint: facts.fingerprint,
                    message: "Apple Intelligence couldn’t write this brief (\(error.localizedDescription)), so "
                        + "Relvora composed it from its rules.")
            }
        }
    }
}
