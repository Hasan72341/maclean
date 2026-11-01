import Foundation

public enum MonitorDefaults {
    public static let machServiceName = "xyz.nyora.maclean.monitor"
    public static let corpusURL = "https://corpus.nyora.xyz/panther_corpus.sqlite"
    public static let launchAgentLabel = "xyz.nyora.maclean.monitor"

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacLean", isDirectory: true)
    }

    public static var alertsURL: URL {
        supportDirectory.appendingPathComponent("alerts.json")
    }
}

public struct MonitorAlert: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let date: Date
    public let path: String
    public let title: String
    public let detail: String
    public let severity: Severity
    public let kind: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        path: String,
        title: String,
        detail: String,
        severity: Severity,
        kind: String
    ) {
        self.id = id
        self.date = date
        self.path = path
        self.title = title
        self.detail = detail
        self.severity = severity
        self.kind = kind
    }
}

public struct MonitorStatus: Codable, Sendable {
    public let running: Bool
    public let watchedPaths: [String]
    public let alertCount: Int
    public let corpusVersion: String?
    public let lastScan: Date?
    public let error: String?

    public init(
        running: Bool,
        watchedPaths: [String],
        alertCount: Int,
        corpusVersion: String?,
        lastScan: Date?,
        error: String?
    ) {
        self.running = running
        self.watchedPaths = watchedPaths
        self.alertCount = alertCount
        self.corpusVersion = corpusVersion
        self.lastScan = lastScan
        self.error = error
    }
}

@objc public protocol MonitorXPCProtocol {
    func startMonitoring(reply: @escaping (String) -> Void)
    func stopMonitoring(reply: @escaping (String) -> Void)
    func status(reply: @escaping (Data) -> Void)
    func alerts(reply: @escaping (Data) -> Void)
    func scanPaths(_ paths: [String], reply: @escaping (Data) -> Void)
    func quarantine(path: String, reason: String, reply: @escaping (Data) -> Void)
    func clearAlerts(reply: @escaping (Data) -> Void)
}
