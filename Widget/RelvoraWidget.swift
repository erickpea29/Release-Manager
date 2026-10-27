import SwiftUI
import WidgetKit

/// The desktop widget (ADR 0024): the progress of the version being planned, in one project or in every project. It
/// reads only the snapshot the app writes to their shared App Group container.
@main
struct RelvoraWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NextRelease", intent: ProjectWidgetIntent.self, provider: NextReleaseProvider()) {
            entry in
            NextReleaseWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Release")
        .description("The progress of the version being planned, in one project or in all of them.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
