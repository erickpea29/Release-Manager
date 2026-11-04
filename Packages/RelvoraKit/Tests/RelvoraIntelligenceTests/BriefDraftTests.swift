import FoundationModels
import RelvoraCore
import Testing

@testable import RelvoraIntelligence

/// The model's output as Relvora reads it. These tests parse generated content; they don't run the model, so they
/// pass on Macs without Apple Intelligence, such as CI.
@Suite("Brief draft")
struct BriefDraftTests {
    @Test("A whole draft becomes a composition, field by field")
    func wholeDraft() throws {
        let content = try GeneratedContent(
            json: """
                {"headline": "Two steps from a draft", "summary": "Briefs arrive.", "changesTitle": "Release briefs",
                 "layout": ["attention", "themes"],
                 "themes": [{"title": "Smarter Releases", "symbol": "sparkles", "taskRefs": ["T1", "T2"]}],
                 "attentionOrder": ["commit"], "nextStep": "commit", "nextStepReason": "Pick the commit first."}
                """)
        let composition = ReleaseBriefComposition(try BriefDraft.PartiallyGenerated(content))
        #expect(composition.headline == "Two steps from a draft")
        #expect(composition.changesTitle == "Release briefs")
        #expect(composition.layout == ["attention", "themes"])
        #expect(composition.themes == [.init(title: "Smarter Releases", symbol: "sparkles", taskRefs: ["T1", "T2"])])
        #expect(composition.attentionOrder == ["commit"])
        #expect(composition.nextStep == "commit")
        #expect(composition.nextStepReason == "Pick the commit first.")
    }

    @Test("While streaming, the next step's key isn't used until its reason has started")
    func streamingNextStep() throws {
        let content = try GeneratedContent(json: #"{"headline": "Almost", "nextStep": "pr-1"}"#)
        let composition = ReleaseBriefComposition(try BriefDraft.PartiallyGenerated(content))
        #expect(composition.headline == "Almost")
        #expect(composition.summary == nil)
        #expect(composition.nextStep == nil)
    }

    @Test("Without a model, the writer says why and writes nothing")
    func noWriter() async throws {
        let writer = NoReleaseBriefWriter()
        #expect(writer.status == .off)
        let facts = ReleaseBriefFacts(
            version: "1.0.0", title: nil, plannedDate: nil, tasks: [], attention: [], checklistDone: 0,
            checklistTotal: 0, hasTargetCommit: false, targetCI: nil, isCheckedOnGitHub: false)
        var count = 0
        for try await _ in writer.write(facts) { count += 1 }
        #expect(count == 0)
    }
}
