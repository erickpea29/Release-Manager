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

/// Release status: always icon + text, never color alone.
struct StatusBadge: View {
    let status: ReleasePlanStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.12), in: Capsule())
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
