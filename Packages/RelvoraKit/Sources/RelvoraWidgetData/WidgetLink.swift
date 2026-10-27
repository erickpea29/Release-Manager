import Foundation

/// A link from the widget into Relvora (ADR 0024): `relvora://project/<id>` opens a project, `relvora://dashboard` the
/// Dashboard.
public enum WidgetLink: Sendable, Equatable {
    case dashboard
    case project(UUID)

    public static let scheme = "relvora"

    public var url: URL {
        switch self {
        case .dashboard: URL(string: "\(Self.scheme)://dashboard")!
        case .project(let id): URL(string: "\(Self.scheme)://project/\(id.uuidString)")!
        }
    }

    /// `nil` for any other URL.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (url.host()?.lowercased(), path.count) {
        case ("dashboard", 0):
            self = .dashboard
        case ("project", 1):
            guard let id = UUID(uuidString: path[0]) else { return nil }
            self = .project(id)
        default:
            return nil
        }
    }
}
