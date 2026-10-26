import AppKit
import Foundation
import Observation
import RelvoraCore
import UserNotifications

/// Relvora's macOS notifications (ADR 0019).
/// - Asks for permission the first time there's something to deliver or schedule.
/// - Shows a banner only when Relvora isn't the active app; otherwise the notification goes straight to Notification
///   Center, because the window already shows what happened.
/// - "Planned for today" is scheduled with macOS, so it arrives even when Relvora is closed.
/// - A click opens the project, the release plan, or the update sheet.
@Observable
final class Notifier: NSObject {
    enum Permission: Equatable {
        case unknown
        case notAsked
        case allowed
        case denied
    }

    private(set) var permission: Permission = .unknown
    /// Debug builds with a test settings suite record notifications here instead of showing them.
    private(set) var recorded: [NotificationContent] = []

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let records: Bool
    /// Opens what a clicked notification is about.
    @ObservationIgnored var open: (NotificationTarget) -> Void = { _ in }
    /// The "planned for today" notifications scheduled per project, so unchanged plans don't touch macOS.
    @ObservationIgnored private var scheduled: [UUID: [NotificationContent]] = [:]

    init(preferences: Preferences, records: Bool) {
        self.preferences = preferences
        self.records = records
    }

    private var center: UNUserNotificationCenter? { records ? nil : .current() }

    /// Projects with "planned for today" notifications scheduled.
    var scheduledProjectIDs: [UUID] { Array(scheduled.keys) }

    func start() {
        center?.delegate = self
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        guard let center else {
            permission = .allowed
            return
        }
        permission =
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined: .notAsked
            case .denied: .denied
            default: .allowed
            }
    }

    /// Asks macOS, once. Returns whether notifications may be shown.
    @discardableResult
    func requestPermission() async -> Bool {
        guard let center else { return true }
        await refreshPermission()
        if permission == .notAsked {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshPermission()
        }
        return permission == .allowed
    }

    // MARK: Delivering

    func deliver(_ content: NotificationContent) async {
        guard preferences.notifies(content.kind) else { return }
        if records {
            recorded.append(content)
            return
        }
        guard let center, await requestPermission() else { return }
        try? await center.add(Self.request(content))
    }

    /// Makes the project's scheduled "planned for today" notifications match `contents` (all of them, or none to
    /// remove them).
    func schedulePlanned(_ contents: [NotificationContent], projectID: UUID) async {
        let wanted = preferences.notifies(.plannedForToday) ? contents : []
        guard scheduled[projectID, default: []] != wanted else { return }
        let previous = scheduled[projectID, default: []]
        scheduled[projectID] = wanted
        if records {
            recorded.removeAll { previous.map(\.id).contains($0.id) }
            recorded += wanted
            return
        }
        guard let center else { return }
        let stale = previous.map(\.id).filter { id in !wanted.contains { $0.id == id } }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        guard !wanted.isEmpty, await requestPermission() else { return }
        for content in wanted { try? await center.add(Self.request(content)) }
    }

    /// After Settings › Notifications changed: scheduled notifications follow the switch.
    func removeAllPlanned() {
        let ids = scheduled.values.flatMap { $0.map(\.id) }
        scheduled = [:]
        if records {
            recorded.removeAll { ids.contains($0.id) }
        } else {
            center?.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static func request(_ content: NotificationContent) -> UNNotificationRequest {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.threadIdentifier = content.threadID
        body.sound = .default
        switch content.target {
        case .project(let id, let tab): body.userInfo = ["projectID": id.uuidString, "tab": tab]
        case .update: body.userInfo = ["update": true]
        }
        let trigger = content.fireDate.map { date in
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date),
                repeats: false)
        }
        return UNNotificationRequest(identifier: content.id, content: body, trigger: trigger)
    }

    fileprivate nonisolated static func target(_ userInfo: [AnyHashable: Any]) -> NotificationTarget? {
        if userInfo["update"] as? Bool == true { return .update }
        guard let id = (userInfo["projectID"] as? String).flatMap(UUID.init(uuidString:)),
            let tab = userInfo["tab"] as? String
        else { return nil }
        return .project(id, tab: tab)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Called while Relvora is open: a banner only when it isn't the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive } ? [.list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let target = Self.target(response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            NSApp.activate()
            open(target)
        }
    }
}
