import RelvoraCore
import SwiftUI

/// The release brief above a planned version (ADR 0025): where it stands, the next step, then the themes, what needs
/// attention, and progress, in the order the model chose. Apple Intelligence writes the words when it can; the
/// verdict, counts, and buttons always come from the plan.
struct ReleaseBriefSection: View {
    @Environment(AppModel.self) private var app
    let release: ReleaseModel
    let isEnabled: (ReleaseBriefAction) -> Bool
    let perform: (ReleaseBriefAction) -> Void

    var body: some View {
        if let plan = release.plan, let facts = release.briefFacts {
            let briefs = app.briefs
            let brief = briefs.brief(for: plan.id, facts: facts)
            VStack(alignment: .leading, spacing: Spacing.m) {
                header(brief, planID: plan.id, facts: facts)
                if let step = brief.nextStep {
                    NextStepCallout(step: step, isEnabled: isEnabled(step.action), perform: perform)
                }
                ForEach(brief.sections) { section in
                    switch section {
                    case .themes:
                        if !brief.themes.isEmpty { BriefThemes(themes: brief.themes) }
                    case .attention:
                        if !brief.attention.isEmpty {
                            BriefAttentionList(
                                items: brief.attention, verdict: brief.verdict, isEnabled: isEnabled, perform: perform)
                        }
                    case .progress:
                        BriefProgress(facts: facts)
                    }
                }
                footer(brief, planID: plan.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            // Only the model's writing grows into place. Changes to the plan show at once: content that moves or fades
            // whenever CI or a pull request is read would be hard to follow, and to read.
            .animation(brief.source == .model(isComplete: false) ? .smooth : nil, value: brief)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Release brief")
            .accessibilityIdentifier("releaseBrief")
            .task(id: "\(facts.fingerprint)\n\(briefs.isEnabled)") {
                briefs.refreshStatus()
                guard briefs.needsWriting(plan.id, facts: facts) else { return }
                // Waits for the plan to settle, such as several checklist steps ticked in a row.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await briefs.write(plan.id, facts: facts)
            }
        }
    }

    private func header(_ brief: ReleaseBrief, planID: UUID, facts: ReleaseBriefFacts) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                // The icon and the words are separate elements, so the words' contrast is measured on their own.
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: brief.verdict.symbol)
                        .foregroundStyle(brief.verdict.tint)
                        .accessibilityHidden(true)
                    Text(brief.verdict.title).accessibilityIdentifier("releaseBriefVerdict")
                }
                .font(.headline)
                Spacer()
                writeControl(planID: planID, facts: facts)
            }
            Group {
                if let headline = brief.headline {
                    Text(headline)
                } else {
                    Text("Writing the brief for this version").redacted(reason: .placeholder)
                }
            }
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("releaseBriefHeadline")
            if let summary = brief.summary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("releaseBriefSummary")
            }
        }
    }

    @ViewBuilder
    private func writeControl(planID: UUID, facts: ReleaseBriefFacts) -> some View {
        let briefs = app.briefs
        if briefs.isWriting(planID) {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Writing…").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if briefs.isEnabled {
            Button("Write Again", systemImage: "arrow.clockwise") {
                Task { await briefs.write(planID, facts: facts) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Write the brief again with Apple Intelligence")
        }
    }

    @ViewBuilder
    private func footer(_ brief: ReleaseBrief, planID: UUID) -> some View {
        if let text = sourceLine(brief, planID: planID) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "apple.intelligence")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("releaseBriefSource")
        }
    }

    /// Who wrote the brief's words, or why Apple Intelligence didn't.
    private func sourceLine(_ brief: ReleaseBrief, planID: UUID) -> String? {
        let briefs = app.briefs
        switch brief.source {
        case .model(isComplete: true):
            return "Written on this Mac by Apple Intelligence. The verdict, counts, and buttons are Relvora’s own."
        case .model(isComplete: false):
            return "Apple Intelligence is writing on this Mac. Nothing leaves it."
        case .standard:
            guard app.preferences.writesReleaseBriefs else { return nil }
            return briefs.failures[planID]?.message ?? briefs.status.explanation
        }
    }
}

// MARK: - Components

/// The step the brief recommends, with its button.
private struct NextStepCallout: View {
    let step: ReleaseBrief.NextStep
    let isEnabled: Bool
    let perform: (ReleaseBriefAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Image(systemName: "arrow.forward.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next Step").font(.caption.weight(.semibold))
                Text(step.reason).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.s)
            Button(step.action.title) { perform(step.action) }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled)
        }
        .padding(Spacing.s)
        .background(
            Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("releaseBriefNextStep")
    }
}

/// The tasks in groups: the model's themes, or task types without a model.
private struct BriefThemes: View {
    let themes: [ReleaseBrief.Theme]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.s, alignment: .top)], alignment: .leading,
            spacing: Spacing.s
        ) {
            ForEach(themes) { theme in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(theme.title, systemImage: theme.symbol)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(theme.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isDone ? .green : .secondary)
                                .accessibilityLabel(task.isDone ? "Complete" : "Not complete")
                            Text(task.title).lineLimit(2)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(
                    Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("releaseBriefTheme")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks by theme")
    }
}

/// What stands in the way, or deserves a look, each with what deals with it.
private struct BriefAttentionList: View {
    let items: [ReleaseBriefAttention]
    let verdict: ReleaseBriefVerdict
    let isEnabled: (ReleaseBriefAction) -> Bool
    let perform: (ReleaseBriefAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(verdict == .blocked ? "Before the Draft" : "Worth a Look")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: item.severity.symbol)
                        .foregroundStyle(item.severity.tint)
                        .accessibilityLabel(item.severity.accessibilityName)
                    Text(item.message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.s)
                    if let action = item.action {
                        Button(action.title) { perform(action) }
                            .buttonStyle(.link)
                            .disabled(!isEnabled(action))
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityIdentifier("releaseBriefAttention")
    }
}

/// Tasks done, the release checklist, and the selected commit's CI.
private struct BriefProgress: View {
    let facts: ReleaseBriefFacts

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            meter("Tasks", done: facts.doneCount, total: facts.tasks.count)
            if facts.checklistTotal > 0 {
                meter("Checklist", done: facts.checklistDone, total: facts.checklistTotal)
            }
            if facts.hasTargetCommit {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Selected Commit").font(.callout.weight(.medium))
                    CIStatusLabel(status: facts.targetCI).font(.callout)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Progress")
        .accessibilityIdentifier("releaseBriefProgress")
    }

    private func meter(_ title: String, done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("\(done) of \(total)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            // The progress indicator carries the words, so VoiceOver reads one element with a role.
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(total > 0 && done == total ? .green : .accentColor)
                .accessibilityLabel(title)
                .accessibilityValue("\(done) of \(total) done")
        }
        .frame(maxWidth: 200)
    }
}

// MARK: - Design

extension ReleaseBriefVerdict {
    var symbol: String {
        switch self {
        case .blocked: "xmark.octagon.fill"
        case .almostReady: "exclamationmark.triangle.fill"
        case .ready: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: .red
        case .almostReady: .orange
        case .ready: .green
        }
    }
}

extension ReleaseIssue.Severity {
    var accessibilityName: String {
        switch self {
        case .blocking: "Must be fixed"
        case .warning: "Warning"
        case .note: "Note"
        }
    }
}
