#if DEBUG
    import Foundation
    import RelvoraCore

    /// Demo content for development and UI checks (`-RelvoraSeedSampleData YES`). Never compiled into Release.
    enum SampleData {
        private struct SampleTask {
            let title: String
            let column: Int
            var priority = TaskPriority.medium
            var type = TaskType.feature
            var labels: [String] = []
            var checklist: [String] = []
            var inRelease = true
        }

        private static let relvoraTasks = [
            SampleTask(
                title: "Drag-and-drop Kanban", column: 2, priority: .high, labels: ["Board"],
                checklist: ["Card drag", "Column drop", "Persist order"]),
            SampleTask(
                title: "Backup and restore", column: 3, priority: .high, labels: ["Data"],
                checklist: ["Export JSON", "Validate", "Safety copy"]),
            SampleTask(title: "Task editor sheet", column: 4, labels: ["Board", "UI"]),
            SampleTask(title: "Release plan editor", column: 1, labels: ["Releases"]),
            SampleTask(
                title: "Fix column header truncation", column: 1, priority: .urgent, type: .bugFix,
                labels: ["UI"]),
            SampleTask(
                title: "Write backup guide", column: 0, priority: .low, type: .documentation,
                inRelease: false),
            SampleTask(title: "GitHub repository browser", column: 0, labels: ["GitHub"], inRelease: false),
        ]

        /// Adds sample projects only to an empty store, so real data is never mixed with samples.
        static func seedIfEmpty(_ environment: AppEnvironment) async throws {
            guard try await environment.store.projects.projects(includeArchived: true).isEmpty else { return }

            let relvora = try await environment.projects.create(
                name: "Relvora", details: "Native macOS release planning.")
            let plan = try await environment.releasePlans.create(
                projectID: relvora.id, version: "0.2.0", title: "Kanban and backups",
                plannedDate: Calendar.current.date(byAdding: .day, value: 14, to: .now), targetBranch: "main")
            try await addTasks(relvoraTasks, to: relvora, plan: plan, environment: environment)

            let website = try await environment.projects.create(
                name: "Website Redesign", details: "Marketing site refresh for the spring launch.")
            try await addTasks(
                [
                    SampleTask(title: "Hero section", column: 4, labels: ["Design"], inRelease: false),
                    SampleTask(title: "Pricing page copy", column: 2, type: .documentation, inRelease: false),
                ], to: website, plan: nil, environment: environment)

            let tools = try await environment.projects.create(
                name: "Command-Line Tools", details: "Internal developer utilities.")
            _ = try await environment.projects.setArchived(tools, true)
        }

        private static func addTasks(
            _ tasks: [SampleTask], to project: Project, plan: ReleasePlan?, environment: AppEnvironment
        ) async throws {
            let columns = try await environment.board.load(projectID: project.id).orderedColumns
            for sample in tasks {
                let checklist = sample.checklist.enumerated().map { index, title in
                    ChecklistItem(title: title, isDone: index == 0, sortOrder: Double(index + 1))
                }
                _ = try await environment.board.createTask(
                    ProjectTask(
                        projectID: project.id,
                        columnID: columns[sample.column].id,
                        releasePlanID: sample.inRelease ? plan?.id : nil,
                        title: sample.title,
                        priority: sample.priority,
                        type: sample.type,
                        labels: sample.labels,
                        checklist: checklist,
                        sortOrder: 0
                    ))
            }
        }
    }
#endif
