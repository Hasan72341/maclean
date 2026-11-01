import AppKit
import Foundation
import MacLeanCore

struct AppsApp: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var bundleID: String?
    var version: String?
    var bytes: Int64
    var lastUsed: Date?
    var added: Date?
    var modified: Date?
    var isAppStore: Bool
    var inUserFolder: Bool
    var executable: String?

    var id: String { path }

    var vendor: String { AppsScan.vendor(of: bundleID) }

    var appInfo: AppInfo {
        AppInfo(name: name, path: path, bundleID: bundleID, version: version, bytes: bytes)
    }

    var sourceTitle: String { isAppStore ? "App Store" : "Other source" }

    var daysSinceUse: Int? {
        guard let lastUsed else { return nil }
        return max(0, Int(Date().timeIntervalSince(lastUsed) / 86_400))
    }
}

struct AppsPart: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    var bytes: Int64
    var files: Int
    var id: String { path }
}

struct AppsBundleInfo: Sendable {
    var build: String?
    var minimumOS: String?
    var category: String?
    var copyright: String?
    var executablePath: String?
    var executableBytes: Int64 = 0
    var architectures: [String] = []
    var hasReceipt = false
    var signatureLines: [(String, String)] = []
    var authorities: [String] = []
    var teamID: String?
    var signingIdentifier: String?
    var hardenedRuntime = false
    var signed = false
    var signatureError: String?
    var gatekeeper: String = ""
    var gatekeeperAccepted = false
    var sandboxed = false
    var entitlementKeys: [String] = []
    var parts: [AppsPart] = []
    var localizations: [String] = []
    var plugins: [AppsPart] = []
    var loginHelpers: [String] = []
    var created: Date?
    var modified: Date?
    var files = 0
}

struct AppsLeftoverClean: Sendable {
    let date: Date
    let title: String
    let apps: [String]
    let removed: [Artifact]
    let summary: RemovalSummary
}

struct AppsExtension: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var kind: String
    var isSystem: Bool
    var bytes: Int64
    var files: Int
    var bundleID: String?
    var version: String?
    var modified: Date?
    var id: String { path }
    var scopeTitle: String { isSystem ? "All users" : "This user" }
}

struct AppsRunning: Identifiable, Hashable {
    var pid: Int32
    var name: String
    var bundleID: String?
    var path: String?
    var isActive: Bool
    var isHidden: Bool
    var isRegular: Bool
    var launched: Date?
    var arch: String
    var memory: Int64
    var cpu: Double
    var id: Int32 { pid }
}

struct AppsUninstallOutcome {
    var appName: String
    var appPath: String
    var title: String
    var date = Date()
    var summary: RemovalSummary
    var removedPaths: [String]
    var adminEligible: [String]
    var adminOutput: String?
}

struct AppsLaunchMatch: Identifiable, Hashable, Sendable {
    var item: StartupItem
    var appPath: String?
    var appName: String?
    var id: String { item.path }
}

final class AppsBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
