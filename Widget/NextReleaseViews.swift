import RelvoraCore
import RelvoraWidgetData
import SwiftUI
import WidgetKit

/// Small: one project's next release. Medium and large: the chosen project in more detail, or every project's next
/// release. A click opens the project in Relvora (`relvora://project/<id>`), or Relvora's Dashboard.
struct NextReleaseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextReleaseEntry

    var body: some View {
        NextReleaseContent(entry: entry, family: family)
            .containerBackground(for: .widget) { Color(nsColor: .controlBackgroundColor) }
    }
}

/// The widget's content for one size, without its background.
struct NextReleaseContent: View {
    let entry: NextReleaseEntry
    let family: WidgetFamily

    var body: some View {
        content
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            if let id = entry.projectID {
                if let project = snapshot.project(id) {
                    chosen(project)
                } else {
                    MessageView(kind: .projectNotFound)
                }
            } else {
                every(snapshot)
            }
        } else {
            MessageView(kind: .noData)
        }
    }

    private func chosen(_ project: WidgetSnapshot.ProjectEntry) -> some View {
        Group {
            if family == .systemSmall {
                SmallProjectView(project: project, now: entry.date)
            } else {
                ProjectDetailView(project: project, now: entry.date, isLarge: family == .systemLarge)
            }
        }
        .widgetURL(WidgetLink.project(project.id).url)
    }

    /// Projects with a version being planned; the small widget shows the first.
    @ViewBuilder
    private func every(_ snapshot: WidgetSnapshot) -> some View {
        let projects = snapshot.projectsWithNextRelease
        if snapshot.projects.isEmpty {
            MessageView(kind: .noProjects)
        } else if projects.isEmpty {
            MessageView(kind: .noVersions)
        } else if family == .systemSmall {
            chosen(projects[0])
        } else {
            ReleaseListView(projects: projects, now: entry.date, limit: family == .systemLarge ? 6 : 3)
                .widgetURL(WidgetLink.dashboard.url)
        }
    }
}

// MARK: Layouts

private struct SmallProjectView: View {
    let project: WidgetSnapshot.ProjectEntry
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                ProjectIcon(name: project.iconName).font(.title3)
                Spacer(minLength: Spacing.xs)
                if let release = project.nextRelease {
                    ProgressRing(progress: release.progress, lineWidth: 5, percentFont: .caption2.bold())
                        .frame(width: 46, height: 46)
                }
            }
            Spacer(minLength: Spacing.xxs)
            Text(project.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let release = project.nextRelease {
                Text(release.version)
                    .font(.title3.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                TasksText(release: release).font(.caption)
                ReleaseStatusLine(release: release, now: now).font(.caption2)
            } else {
                Text("No version planned").font(.subheadline.weight(.semibold))
                if let last = project.lastRelease { LastReleaseLine(release: last, lines: 2).font(.caption2) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectDetailView: View {
    let project: WidgetSnapshot.ProjectEntry
    let now: Date
    let isLarge: Bool

    var body: some View {
        if let release = project.nextRelease {
            if isLarge { large(release) } else { medium(release) }
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ProjectHeader(project: project)
                Spacer(minLength: 0)
                Text("No version planned").font(.title3.weight(.semibold))
                Text("Plan a version in the project’s Releases tab.").font(.caption).foregroundStyle(.secondary)
                if let last = project.lastRelease { LastReleaseLine(release: last).font(.caption) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        }
    }

    private func medium(_ release: WidgetSnapshot.NextRelease) -> some View {
        HStack(spacing: Spacing.m) {
            ProgressRing(progress: release.progress, lineWidth: 9, percentFont: .title3.bold())
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 3) {
                ProjectHeader(project: project).font(.caption)
                VersionTitle(release: release, font: .title2)
                TasksText(release: release).font(.caption)
                ReleaseStatusLine(release: release, now: now).font(.caption)
                if let last = project.lastRelease { LastReleaseLine(release: last).font(.caption2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func large(_ release: WidgetSnapshot.NextRelease) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ProjectHeader(project: project).font(.headline)
            HStack(spacing: Spacing.l) {
                ProgressRing(progress: release.progress, lineWidth: 12, percentFont: .title.bold())
                    .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    VersionTitle(release: release, font: .largeTitle)
                    TasksText(release: release).font(.callout)
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xs) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    StatusLabel(status: release.status)
                }
                GridRow {
                    Text("Planned").foregroundStyle(.secondary)
                    if let date = release.plannedDate {
                        PlannedDateLabel(date: date, now: now)
                    } else {
                        Text("No date")
                    }
                }
                if let last = project.lastRelease {
                    GridRow {
                        Text("Last release").foregroundStyle(.secondary)
                        LastReleaseLine(release: last, showsIcon: false)
                    }
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct ReleaseListView: View {
    let projects: [WidgetSnapshot.ProjectEntry]
    let now: Date
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: limit > 3 ? Spacing.s : Spacing.xs) {
            HStack {
                Text("Next Releases").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if projects.count > limit {
                    Text("\(projects.count - limit) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(projects.prefix(limit)) { project in
                if let release = project.nextRelease {
                    Link(destination: WidgetLink.project(project.id).url) {
                        ReleaseRow(project: project, release: release, now: now, isLarge: limit > 3)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ReleaseRow: View {
    let project: WidgetSnapshot.ProjectEntry
    let release: WidgetSnapshot.NextRelease
    let now: Date
    /// The large widget also shows each project's group, and longer bars.
    let isLarge: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            ProjectIcon(name: project.iconName)
                .font(.body)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isLarge, let group = project.groupName {
                        Text(group).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.xs)
                    Text(release.version).font(.caption.monospaced().weight(.medium)).lineLimit(1)
                }
                // The bars line up on the trailing edge, whatever the status says.
                HStack(spacing: Spacing.xs) {
                    ReleaseStatusLine(release: release, now: now).layoutPriority(1)
                    Spacer(minLength: Spacing.xs)
                    TasksText(release: release, short: true).fixedSize()
                    if release.taskCount > 0 {
                        ProgressBar(progress: release.progress).frame(width: isLarge ? 120 : 84)
                    }
                }
                .font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MessageView: View {
    enum Kind {
        /// Relvora hasn't written a snapshot yet, or this copy can't share one.
        case noData
        case noProjects
        case noVersions
        case projectNotFound
    }

    let kind: Kind

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .widgetAccentable()
                .padding(.bottom, Spacing.xxs)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .widgetURL(WidgetLink.dashboard.url)
    }

    private var symbol: String {
        switch kind {
        case .noData, .noProjects: "shippingbox"
        case .noVersions: "calendar.badge.plus"
        case .projectNotFound: "questionmark.folder"
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .noData: "Open Relvora"
        case .noProjects: "No Projects"
        case .noVersions: "No Versions Planned"
        case .projectNotFound: "Project Not Found"
        }
    }

    private var message: LocalizedStringKey {
        switch kind {
        case .noData: "Your releases appear here once Relvora has opened."
        case .noProjects: "Create a project in Relvora to plan its releases."
        case .noVersions: "Plan a version in a project’s Releases tab."
        case .projectNotFound: "It was deleted or archived. Edit the widget to choose another."
        }
    }
}

// MARK: Pieces

private struct ProjectIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(.tint)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

private struct ProjectHeader: View {
    let project: WidgetSnapshot.ProjectEntry

    var body: some View {
        HStack(spacing: 6) {
            ProjectIcon(name: project.iconName)
            Text(project.name).fontWeight(.semibold).lineLimit(1)
            if let group = project.groupName {
                Text(group).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct VersionTitle: View {
    let release: WidgetSnapshot.NextRelease
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(release.version)
                .font(font.monospaced().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let title = release.title {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// "3 of 8 done", or "3/8" in a row. Numbers stay full-strength, as in the app.
private struct TasksText: View {
    let release: WidgetSnapshot.NextRelease
    var short = false

    var body: some View {
        if release.taskCount == 0 {
            Text(short ? "No tasks" : "No tasks yet").foregroundStyle(.secondary)
        } else if short {
            Text("\(release.doneCount)/\(release.taskCount)")
                .monospacedDigit()
                .accessibilityLabel("\(release.doneCount) of \(release.taskCount) tasks done")
        } else {
            Text("\(release.doneCount) of \(release.taskCount) done")
                .monospacedDigit()
                .accessibilityLabel("\(release.doneCount) of \(release.taskCount) tasks done")
        }
    }
}

/// A draft waiting on GitHub, or a version needing reconciliation, says so; a planned version shows its date.
private struct ReleaseStatusLine: View {
    let release: WidgetSnapshot.NextRelease
    let now: Date

    var body: some View {
        if release.status != .planned {
            StatusLabel(status: release.status)
        } else if let date = release.plannedDate {
            PlannedDateLabel(date: date, now: now)
        }
    }
}

/// Status: always an icon and words, never color alone (Design System §3).
private struct StatusLabel: View {
    let status: ReleasePlanStatus

    var body: some View {
        IconText(symbol: status.symbol, tint: status.tint) { Text(status.title) }
    }
}

/// The planned day: "Today", or a date. A day already passed is marked late.
private struct PlannedDateLabel: View {
    let date: Date
    let now: Date

    var body: some View {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let text = date.formatted(.dateTime.month(.abbreviated).day())
        if day < today {
            IconText(symbol: "exclamationmark.circle.fill", tint: .orange) { Text("Planned \(text)") }
                .accessibilityLabel("Planned for \(text), already passed")
        } else if day == today {
            IconText(symbol: "calendar", tint: .secondary) { Text("Today") }
                .accessibilityLabel("Planned for today")
        } else {
            IconText(symbol: "calendar", tint: .secondary) { Text(text) }
                .accessibilityLabel("Planned for \(text)")
        }
    }
}

private struct LastReleaseLine: View {
    let release: WidgetSnapshot.LastRelease
    var showsIcon = true
    var lines = 1

    var body: some View {
        let text: Text =
            if let date = release.publishedAt {
                Text("Released \(release.version) \(date.formatted(.relative(presentation: .named)))")
            } else {
                Text("Released \(release.version)")
            }
        if showsIcon {
            IconText(symbol: "checkmark.seal", tint: .secondary, lines: lines) { text }.foregroundStyle(.secondary)
        } else {
            text
        }
    }
}

/// An icon and its words, tighter than `Label` for a widget's small text.
private struct IconText<Title: View>: View {
    let symbol: String
    let tint: Color
    var lines = 1
    @ViewBuilder let title: Title

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            title.lineLimit(lines)
        }
    }
}

private struct ProgressRing: View {
    /// `nil` while the version has no tasks.
    let progress: Double?
    let lineWidth: CGFloat
    let percentFont: Font

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress ?? 0)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            Text(progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                .font(percentFont)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(lineWidth)
        }
        .padding(lineWidth / 2)
        // The tasks text says the same in words.
        .accessibilityHidden(true)
    }
}

private struct ProgressBar: View {
    let progress: Double?

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * (progress ?? 0))
                        .widgetAccentable()
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Tokens

/// The app's spacing scale (`App/DesignSystem/Tokens.swift`).
private enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

/// The app's status icons and colors (`App/DesignSystem/Badges.swift`).
extension ReleasePlanStatus {
    fileprivate var symbol: String {
        switch self {
        case .planned: "calendar"
        case .draftCreated: "doc.badge.clock"
        case .reconciliationNeeded: "exclamationmark.arrow.triangle.2.circlepath"
        case .published: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .planned, .cancelled: .secondary
        case .draftCreated: .blue
        case .reconciliationNeeded: .orange
        case .published: .green
        }
    }
}
