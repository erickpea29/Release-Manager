#if DEBUG
    import Foundation
    import RelvoraCore

    /// A scripted stand-in for Apple Intelligence (`-RelvoraBriefWriter demo`): it streams a brief built from the
    /// facts, the way the on-device model does, so UI tests and demos see a written brief on any Mac. It groups tasks
    /// by whether they're done, which Relvora's standard brief never does.
    nonisolated struct DemoBriefWriter: ReleaseBriefWriter {
        static let shippedTheme = "Shipped So Far"
        static let openTheme = "Still in Progress"

        var status: ReleaseBriefWriterStatus { .available }

        func write(_ facts: ReleaseBriefFacts) -> AsyncThrowingStream<ReleaseBriefComposition, any Error> {
            let steps = Self.steps(Self.composition(facts))
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for step in steps {
                        try? await Task.sleep(for: .milliseconds(120))
                        if Task.isCancelled { break }
                        continuation.yield(step)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        static func composition(_ facts: ReleaseBriefFacts) -> ReleaseBriefComposition {
            let headline =
                switch facts.verdict {
                case .blocked: "\(facts.version) needs a few fixes before its draft"
                case .almostReady: "\(facts.version) can be drafted after a quick look"
                case .ready: "\(facts.version) is ready to ship"
                }
            var themes: [ReleaseBriefComposition.Theme] = []
            let done = facts.tasks.filter(\.isDone).map(\.ref)
            let open = facts.tasks.filter { !$0.isDone }.map(\.ref)
            if !done.isEmpty { themes.append(.init(title: shippedTheme, symbol: "shippingbox", taskRefs: done)) }
            if !open.isEmpty {
                themes.append(.init(title: openTheme, symbol: "wrench.and.screwdriver", taskRefs: open))
            }
            let next = facts.nextStepKeys.first
            return ReleaseBriefComposition(
                headline: headline,
                summary: "A demo brief: \(facts.doneCount) of \(facts.tasks.count) tasks are done, grouped by how far "
                    + "along they are.",
                layout: facts.verdict == .blocked
                    ? ["attention", "themes", "progress"] : ["themes", "progress", "attention"],
                themes: themes, attentionOrder: facts.attention.map(\.key).reversed(), nextStep: next,
                nextStepReason: next.map { _ in "The demo writer always starts with the first choice." })
        }

        /// The composition as it grows: the headline word by word, then each field in the model's order.
        static func steps(_ whole: ReleaseBriefComposition) -> [ReleaseBriefComposition] {
            var steps: [ReleaseBriefComposition] = []
            var partial = ReleaseBriefComposition()
            let words = (whole.headline ?? "").split(separator: " ")
            for count in stride(from: 2, through: words.count, by: 2) + [words.count] {
                partial.headline = words.prefix(count).joined(separator: " ")
                steps.append(partial)
            }
            partial.summary = whole.summary
            steps.append(partial)
            partial.layout = whole.layout
            for theme in whole.themes ?? [] {
                partial.themes = (partial.themes ?? []) + [theme]
                steps.append(partial)
            }
            partial.attentionOrder = whole.attentionOrder
            partial.nextStep = whole.nextStep
            partial.nextStepReason = whole.nextStepReason
            steps.append(partial)
            return steps
        }
    }
#endif
