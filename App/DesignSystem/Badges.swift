import RelvoraCore
import SwiftUI

extension TaskPriority {
    var symbol: String {
        switch self {
        case .low: "arrow.down"
        case .medium: "equal"
        case .high: "arrow.up"
        case .urgent: "exclamationmark.2"
        }
    }

    var tint: Color {
        switch self {
        case .low: .secondary
        case .medium: .blue
        case .high: .orange
        case .urgent: .red
        }
    }
}

extension TaskType {
    var symbol: String {
        switch self {
        case .feature: "sparkles"
        case .improvement: "wand.and.stars"
        case .bugFix: "ladybug"
        case .documentation: "doc.text"
        case .maintenance: "wrench.and.screwdriver"
        case .other: "circle.dashed"
        }
    }
}

extension ReleasePlanStatus {
    var symbol: String {
        switch self {
        case .planned: "calendar"
        case .draftCreated: "doc.badge.clock"
        case .reconciliationNeeded: "exclamationmark.arrow.triangle.2.circlepath"
        case .published: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .planned: .secondary
        case .draftCreated: .blue
        case .reconciliationNeeded: .orange
        case .published: .green
        case .cancelled: .secondary
        }
    }
}

extension ReleaseSnapshotState {
    var symbol: String {
        switch self {
        case .pending: "exclamationmark.arrow.triangle.2.circlepath"
        case .draftCreated: "doc.badge.clock"
        case .published: "checkmark.seal.fill"
        case .abandoned: "trash"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .orange
        case .draftCreated: .blue
        case .published: .green
        case .abandoned: .secondary
        }
    }
}

/// Snapshot state: icon + text, like `StatusBadge`.
struct SnapshotStateBadge: View {
    let state: ReleaseSnapshotState

    var body: some View {
        StatusCapsule(title: state.title, symbol: state.symbol, tint: state.tint)
    }
}

extension ReleaseIssue.Severity {
    var symbol: String {
        switch self {
        case .blocking: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .blocking: .red
        case .warning: .orange
        case .note: .secondary
        }
    }
}

/// A row of facts with a fixed-width label column.
struct FactRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content
                .gridColumnAlignment(.leading)
        }
    }
}

/// An icon-only link to a page on GitHub, with a tooltip and a spoken label.
struct GitHubLinkIcon: View {
    let url: URL
    let label: String

    var body: some View {
        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Release status: always icon + text, never color alone.
struct StatusBadge: View {
    let status: ReleasePlanStatus

    var body: some View {
        StatusCapsule(title: status.title, symbol: status.symbol, tint: status.tint)
    }
}

/// Status inside a list row: icon and text without a capsule, so the text follows the row's color (white on a
/// focused selection). A translucent capsule lightened the selection behind white text and failed the contrast audit.
struct RowStatusLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    var isSelected = false

    init(_ status: ReleasePlanStatus, isSelected: Bool = false) {
        self.init(title: status.title, symbol: status.symbol, tint: status.tint, isSelected: isSelected)
    }

    init(_ state: ReleaseSnapshotState, isSelected: Bool = false) {
        self.init(title: state.title, symbol: state.symbol, tint: state.tint, isSelected: isSelected)
    }

    init(title: String, symbol: String, tint: Color, isSelected: Bool) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isSelected = isSelected
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
        }
        .font(.caption.weight(.medium))
    }
}

/// Colored icon and capsule with full-strength text: colored caption text failed the contrast audit on tinted
/// backgrounds and selected rows.
private struct StatusCapsule: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct PriorityIndicator: View {
    let priority: TaskPriority

    var body: some View {
        Image(systemName: priority.symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(priority.tint)
            .help("\(priority.title) priority")
            .accessibilityLabel("\(priority.title) priority")
    }
}

struct LabelChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
        }
        .panel()
        .padding(Spacing.l)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
