import Darwin
import Foundation
import MacLeanCore

@MainActor
final class MonitorClient: ObservableObject {
    @Published private(set) var status: MonitorStatus?
    @Published private(set) var alerts: [MonitorAlert] = []
    @Published private(set) var agentInstalled = false
    @Published var message: String?
    @Published var errorMessage: String?

    private var connection: NSXPCConnection?

    init() {
        agentInstalled = FileManager.default.fileExists(atPath: Self.agentPlistURL.path)
        connect()
    }

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(MonitorDefaults.launchAgentLabel).plist")
    }

    func connect() {
        if connection != nil { return }
        let connection = NSXPCConnection(
            machServiceName: MonitorDefaults.machServiceName,
            options: []
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MonitorXPCProtocol.self)
        connection.invalidationHandler = Self.signal(self) { client in client.connection = nil }
        connection.interruptionHandler = Self.signal(self) { client in
            client.errorMessage = "The background monitor was interrupted."
        }
        connection.resume()
        self.connection = connection
    }

    // XPC invokes these callbacks on its own queue. Building them in
    // nonisolated functions guarantees they never inherit main-actor
    // isolation (which traps at runtime under Swift 6).
    nonisolated private static func reply<T: Sendable>(
        _ client: MonitorClient,
        _ apply: @escaping @MainActor @Sendable (MonitorClient, T) -> Void
    ) -> @Sendable (T) -> Void {
        { [weak client] value in
            Task { @MainActor in
                guard let client else { return }
                apply(client, value)
            }
        }
    }

    nonisolated private static func signal(
        _ client: MonitorClient,
        _ apply: @escaping @MainActor @Sendable (MonitorClient) -> Void
    ) -> @Sendable () -> Void {
        { [weak client] in
            Task { @MainActor in
                guard let client else { return }
                apply(client)
            }
        }
    }

    private var proxy: MonitorXPCProtocol? {
        connect()
        let handler: @Sendable (any Error) -> Void = Self.reply(self) { (client: MonitorClient, error: any Error) in
            client.errorMessage = error.localizedDescription
        }
        return connection?.remoteObjectProxyWithErrorHandler(handler) as? MonitorXPCProtocol
    }

    func refresh() {
        guard let proxy else { return }
        proxy.status(reply: Self.reply(self) { (client: MonitorClient, data: Data) in
            let decoded = try? JSONDecoder().decode(MonitorStatus.self, from: data)
            client.status = decoded
            if let decoded { client.errorMessage = decoded.error }
        })
        proxy.alerts(reply: Self.reply(self) { (client: MonitorClient, data: Data) in
            client.alerts = (try? JSONDecoder().decode([MonitorAlert].self, from: data)) ?? []
        })
    }

    func start() {
        proxy?.startMonitoring(reply: Self.reply(self) { (client: MonitorClient, message: String) in
            client.message = message
            client.refresh()
        })
    }

    func stop() {
        proxy?.stopMonitoring(reply: Self.reply(self) { (client: MonitorClient, message: String) in
            client.message = message
            client.refresh()
        })
    }

    func clearAlerts() {
        proxy?.clearAlerts(reply: Self.reply(self) { (client: MonitorClient, data: Data) in
            client.alerts = (try? JSONDecoder().decode([MonitorAlert].self, from: data)) ?? []
            client.refresh()
        })
    }

    func scanWatched() {
        guard let paths = status?.watchedPaths, !paths.isEmpty else { return }
        proxy?.scanPaths(paths, reply: Self.reply(self) { (client: MonitorClient, data: Data) in
            client.alerts = (try? JSONDecoder().decode([MonitorAlert].self, from: data)) ?? []
            client.refresh()
        })
    }

    func quarantine(_ alert: MonitorAlert) {
        let title = alert.title
        proxy?.quarantine(
            path: alert.path,
            reason: "Realtime alert: \(title)",
            reply: Self.reply(self) { (client: MonitorClient, data: Data) in
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let error = object?["error"] as? String {
                    client.errorMessage = error
                } else {
                    client.message = "Quarantined \(title)."
                    client.refresh()
                }
            }
        )
    }

    func installAgent() async {
        guard let monitor = locateMonitorBinary() else {
            errorMessage = "maclean-monitor was not found next to the app."
            return
        }
        do {
            try writeAgentPlist(monitor: monitor)
            agentInstalled = true
            let uid = getuid()
            let label = MonitorDefaults.launchAgentLabel
            let plist = Self.agentPlistURL.path
            let bootstrap = await Task.detached {
                _ = ProcessRunner.run(
                    "/bin/launchctl",
                    ["bootout", "gui/\(uid)/\(label)"],
                    timeout: 15
                )
                return ProcessRunner.run(
                    "/bin/launchctl",
                    ["bootstrap", "gui/\(uid)", plist],
                    timeout: 15
                )
            }.value
            guard bootstrap.status == 0 else {
                errorMessage = "launchctl bootstrap failed: \(bootstrap.stderr)"
                return
            }
            _ = await Task.detached {
                ProcessRunner.run(
                    "/bin/launchctl",
                    ["kickstart", "-k", "gui/\(uid)/\(label)"],
                    timeout: 15
                )
            }.value
            message = "Monitoring agent installed."
            connection?.invalidate()
            connection = nil
            try? await Task.sleep(for: .milliseconds(300))
            connect()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateMonitorBinary() -> String? {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("maclean-monitor"))
        }
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(working.appendingPathComponent(".build/release/maclean-monitor"))
        candidates.append(working.appendingPathComponent(".build/debug/maclean-monitor"))
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }?.path
    }

    private func writeAgentPlist(monitor: String) throws {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": MonitorDefaults.launchAgentLabel,
            "ProgramArguments": [monitor, "--corpus", MonitorDefaults.corpusURL],
            "MachServices": [MonitorDefaults.machServiceName: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logs.appendingPathComponent("MacLeanMonitor.out").path,
            "StandardErrorPath": logs.appendingPathComponent("MacLeanMonitor.err").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: Self.agentPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: Self.agentPlistURL, options: [.atomic])
    }
}
