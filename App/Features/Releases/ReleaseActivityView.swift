import RelvoraCore
import SwiftUI

/// GitHub work for a release plan, shown live step by step (ADR 0025): each step pending, running, then done or
/// failed. The steps are the work Relvora really does, in order; nothing is shown that didn't happen.
struct ReleaseActivity: Equatable {
    enum Kind: Equatable {
        case check, startDraft, createDraft, readDraft, publish, reconcile

        var running: String {
            switch self {
            case .check, .reconcile: "Checking GitHub"
            case .startDraft: "Starting the draft"
            case .createDraft: "Creating the draft"
            case .readDraft: "Reading the draft"
            case .publish: "Publishing"
            }
        }

        var done: String {
            switch self {
            case .check, .reconcile: "Checked GitHub"
            case .startDraft: "Started the draft"
            case .createDraft: "Created the draft"
            case .readDraft: "Read the draft"
            case .publish: "Published"
            }
        }

        var failed: String {
            switch self {
            case .check, .reconcile: "Couldn’t check GitHub"
            case .startDraft: "Couldn’t start the draft"
            case .createDraft: "Couldn’t create the draft"
            case .readDraft: "Couldn’t read the draft"
            case .publish: "Couldn’t publish"
            }
        }
    }

    struct Step: Equatable, Identifiable {
        enum State: Equatable { case pending, running, done, failed }

        let id: Int
        let title: String
        var state: State = .pending
    }

    let kind: Kind
    var steps: [Step]
    let startedAt: Date
    var finishedAt: Date?
    /// Why it stopped, when a step failed.
    var failure: String?
    /// What it found, such as "Ready for a draft".
    var outcome: String?

    init(kind: Kind, steps: [String], now: Date = .now) {
        self.kind = kind
        self.steps = steps.enumerated().map { Step(id: $0.offset, title: $0.element) }
        startedAt = now
    }

    var isRunning: Bool { finishedAt == nil }
    var title: String { isRunning ? kind.running : failure == nil ? kind.done : kind.failed }
    /// The step in progress, for a sheet's one-line status.
    var currentStep: String? { steps.first { $0.state == .running }?.title }

    mutating func end(failure: String? = nil, outcome: String? = nil, now: Date = .now) {
        guard isRunning else { return }
        finishedAt = now
        self.failure = failure
        self.outcome = outcome
    }
}

/// The plan's GitHub work as it happens: a header with the time so far, then each step. Once done, the steps fold
/// away behind the header, which opens them again.
struct ReleaseActivityCard: View {
    let activity: ReleaseActivity
    var stats: ChangeStats?
    let hide: () -> Void
    @State private var showsSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                // Only finished work folds: a button then, plain text while it runs or after it failed (a disabled
                // button would draw its words dimmed).
                if activity.isRunning || activity.failure != nil {
                    header
                } else {
                    Button {
                        withAnimation(.smooth) { showsSteps.toggle() }
                    } label: {
                        header.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(activity.title), \(seconds(at: activity.finishedAt ?? .now)) seconds")
                    .accessibilityHint(showsSteps ? "Hides the steps" : "Shows the steps")
                }
                if let outcome = activity.outcome {
                    Text("· \(outcome)").foregroundStyle(.secondary)
                }
                Spacer()
                if let stats { DiffStatChip(stats: stats) }
                if !activity.isRunning {
                    Button("Hide Steps", systemImage: "xmark", action: hide)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(activity.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            stepIcon(step.state).frame(width: 16)
                            Text(step.title).foregroundStyle(step.state == .pending ? .secondary : .primary)
                        }
                    }
                    if let failure = activity.failure {
                        Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, Spacing.m)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Spacing.s)
        .animation(.smooth, value: activity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("releaseActivity")
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            if !activity.isRunning && activity.failure == nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
            statusIcon
            Text(activity.title).font(.headline)
            elapsed.foregroundStyle(.secondary)
        }
    }

    /// Running or failed: the steps show. Done: they fold away until opened.
    private var isOpen: Bool { activity.isRunning || activity.failure != nil || showsSteps }

    @ViewBuilder
    private var statusIcon: some View {
        if activity.isRunning {
            ProgressView().controlSize(.mini)
        } else if activity.failure != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if activity.isRunning {
            TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                Text("\(seconds(at: context.date))s").monospacedDigit()
            }
        } else {
            Text("\(seconds(at: activity.finishedAt ?? .now))s").monospacedDigit()
        }
    }

    private func seconds(at date: Date) -> Int { max(0, Int(date.timeIntervalSince(activity.startedAt))) }

    @ViewBuilder
    private func stepIcon(_ state: ReleaseActivity.Step.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case .running:
            ProgressView().controlSize(.mini).accessibilityLabel("In progress")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
    }
}

/// How much a release changes, as GitHub shows it: "+482 −37" and five squares split between additions and
/// deletions. The numbers are full-strength text; the squares carry the color.
struct DiffStatChip: View {
    let stats: ChangeStats

    var body: some View {
        let squares = stats.squares
        HStack(spacing: Spacing.xs) {
            Text("+\(stats.additions) −\(stats.deletions)\(stats.isPartial ? "+" : "")")
                .font(.callout.monospacedDigit())
                .accessibilityLabel(
                    "\(stats.additions) lines added and \(stats.deletions) removed, in \(stats.changedFiles) "
                        + "\(stats.changedFiles == 1 ? "file" : "files")")
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(
                            index < squares.additions
                                ? Color.green : index < squares.additions + squares.deletions ? Color.red : Color.gray
                        )
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .help("\(stats.changedFiles) files changed\(stats.isPartial ? " (GitHub lists the first 300)" : "")")
        .accessibilityIdentifier("diffStats")
    }
}
