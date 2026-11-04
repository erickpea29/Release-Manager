import FoundationModels
import RelvoraCore

/// Writes release briefs with Apple Intelligence's on-device model (ADR 0025). The facts and the prompt never leave
/// the Mac: the model runs here, and Relvora asks for no server model.
public struct OnDeviceBriefWriter: ReleaseBriefWriter {
    public init() {}

    public var status: ReleaseBriefWriterStatus {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    public func write(_ facts: ReleaseBriefFacts) -> AsyncThrowingStream<ReleaseBriefComposition, any Error> {
        let prompt = ReleaseBriefComposer.prompt(facts)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // A new session for each brief: nothing from another plan's brief is in its context.
                    let session = LanguageModelSession(instructions: ReleaseBriefComposer.instructions)
                    let stream = session.streamResponse(
                        to: prompt, generating: BriefDraft.self, includeSchemaInPrompt: true,
                        options: GenerationOptions(temperature: 0.3))
                    for try await snapshot in stream {
                        continuation.yield(ReleaseBriefComposition(snapshot.content))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The brief as the model writes it. Properties are generated in this order, so the headline shows first and the
/// sections' order is known before their content.
@Generable(description: "The release brief for one version, composed only from the facts given")
struct BriefDraft {
    @Guide(description: "Where the release stands, in at most 12 words. Don't repeat the version number.")
    var headline: String

    @Guide(description: "What the release brings for the app's users, in one or two short sentences.")
    var summary: String

    @Guide(description: "What the COMMITS do in at most 8 words, like a pull request title; empty without COMMITS.")
    var changesTitle: String

    @Guide(
        description: "The sections, in the order to show them: what matters most for this release first.",
        .maximumCount(3), .element(.anyOf(["themes", "attention", "progress"])))
    var layout: [String]

    @Guide(description: "One to four groups of related tasks, the most important first.", .maximumCount(4))
    var themes: [ThemeDraft]

    @Guide(description: "Keys from ATTENTION, most important first, copied exactly.")
    var attentionOrder: [String]

    @Guide(description: "The best next step: one key from NEXT STEP CHOICES, copied exactly.")
    var nextStep: String

    @Guide(description: "Why that's the next step, in one short sentence.")
    var nextStepReason: String
}

@Generable(description: "A group of related tasks in the release")
struct ThemeDraft {
    @Guide(description: "Two to four words in title case, such as “Smoother Publishing”.")
    var title: String

    @Guide(description: "The symbol that fits the group best.", .anyOf(ReleaseBriefComposer.themeSymbols))
    var symbol: String

    @Guide(description: "Refs of the tasks in this group, such as T1, copied from TASKS.")
    var taskRefs: [String]
}

extension ReleaseBriefComposition {
    init(_ draft: BriefDraft.PartiallyGenerated) {
        self.init(
            headline: draft.headline, summary: draft.summary, changesTitle: draft.changesTitle, layout: draft.layout,
            themes: draft.themes?.map { Theme(title: $0.title, symbol: $0.symbol, taskRefs: $0.taskRefs) },
            attentionOrder: draft.attentionOrder,
            // The key is whole once its reason has started: a key still streaming ("pr-1" of "pr-15") isn't used.
            nextStep: draft.nextStepReason == nil ? nil : draft.nextStep, nextStepReason: draft.nextStepReason)
    }
}
