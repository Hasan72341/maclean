import Foundation

public struct PermissionGrant: Codable, Sendable, Identifiable {
    public var id: String { "\(service)|\(client)" }
    public let service: String
    public let client: String
    public let authValue: Int
    public let lastModified: Date?

    public init(service: String, client: String, authValue: Int, lastModified: Date?) {
        self.service = service
        self.client = client
        self.authValue = authValue
        self.lastModified = lastModified
    }

    public var allowed: Bool { authValue == 2 || authValue == 3 }
}

public struct PermissionReport: Codable, Sendable {
    public let database: String
    public let grants: [PermissionGrant]
    public let fullDiskAccess: Bool
    public let error: String?

    public init(
        database: String,
        grants: [PermissionGrant],
        fullDiskAccess: Bool,
        error: String?
    ) {
        self.database = database
        self.grants = grants
        self.fullDiskAccess = fullDiskAccess
        self.error = error
    }

    public static let empty = PermissionReport(
        database: "",
        grants: [],
        fullDiskAccess: false,
        error: nil
    )
}

public enum PermissionsScanner {
    public static func databaseURL(home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Application Support/com.apple.TCC/TCC.db"
        )
    }

    public static func databaseURLs(home: URL) -> [URL] {
        [
            databaseURL(home: home),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        database: URL? = nil
    ) -> PermissionReport {
        let candidates = database.map { [$0] } ?? databaseURLs(home: home)
        var firstError: String?
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let report = query(database: path)
            if report.error == nil { return report }
            if firstError == nil { firstError = report.error }
        }
        let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? candidates[0]
        return PermissionReport(
            database: path.path,
            grants: [],
            fullDiskAccess: false,
            error: firstError ?? "TCC database not found."
        )
    }

    private static func query(database path: URL) -> PermissionReport {

        let query = """
        SELECT service, client, auth_value, COALESCE(last_modified, 0) FROM access ORDER BY service, client;
        """
        let result = ProcessRunner.run(
            "/usr/bin/sqlite3",
            ["-separator", "\t", path.path, query],
            timeout: 15
        )
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return PermissionReport(
                database: path.path,
                grants: [],
                fullDiskAccess: false,
                error: message.isEmpty
                    ? "Could not read TCC. Grant Full Disk Access to maclean."
                    : message
            )
        }

        var grants: [PermissionGrant] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let timestamp = Double(parts[3]) ?? 0
            grants.append(
                PermissionGrant(
                    service: String(parts[0]),
                    client: String(parts[1]),
                    authValue: Int(parts[2]) ?? 0,
                    lastModified: timestamp > 0
                        ? Date(timeIntervalSince1970: timestamp)
                        : nil
                )
            )
        }
        return PermissionReport(
            database: path.path,
            grants: grants,
            fullDiskAccess: true,
            error: nil
        )
    }

    @discardableResult
    public static func reset(service: String, bundle: String) -> ProcessResult {
        ProcessRunner.run(
            "/usr/bin/tccutil",
            ["reset", tccutilServiceName(service), bundle],
            timeout: 20
        )
    }

    public static func tccutilServiceName(_ service: String) -> String {
        let prefix = "kTCCService"
        guard service.hasPrefix(prefix) else { return service }
        return String(service.dropFirst(prefix.count))
    }
}
