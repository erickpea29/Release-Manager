import SwiftUI

/// Placeholder until release snapshots exist (M04).
struct ReleaseHistoryView: View {
    var body: some View {
        ContentUnavailableView(
            "No Releases Yet",
            systemImage: "clock.arrow.circlepath",
            description: Text("Published releases will appear here with their notes and tasks.")
        )
    }
}
