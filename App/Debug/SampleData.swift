#if DEBUG
    import RelvoraCore

    /// Demo content for development and UI checks (`-RelvoraSeedSampleData YES`). Never compiled into Release.
    enum SampleData {
        static let projects = [
            ("Relvora", "Native macOS release planning."),
            ("Website Redesign", "Marketing site refresh for the spring launch."),
            ("Command-Line Tools", "Internal developer utilities."),
        ]

        /// Adds the sample projects only to an empty store, so real data is never mixed with samples.
        static func seedIfEmpty(_ environment: AppEnvironment) async throws {
            guard try await environment.store.projects.projects(includeArchived: true).isEmpty else { return }
            for (name, details) in projects {
                _ = try await environment.createProject(name: name, details: details)
            }
        }
    }
#endif
