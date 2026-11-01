import Foundation
import MacLeanCore

final class MonitorXPCService: NSObject, MonitorXPCProtocol {
    private let engine: MonitorEngine

    init(engine: MonitorEngine) {
        self.engine = engine
    }

    func startMonitoring(reply: @escaping (String) -> Void) {
        engine.start(completion: reply)
    }

    func stopMonitoring(reply: @escaping (String) -> Void) {
        engine.stop(completion: reply)
    }

    func status(reply: @escaping (Data) -> Void) {
        reply(engine.statusData())
    }

    func alerts(reply: @escaping (Data) -> Void) {
        reply(engine.alertsData())
    }

    func scanPaths(_ paths: [String], reply: @escaping (Data) -> Void) {
        engine.scan(paths: paths, completion: reply)
    }

    func quarantine(path: String, reason: String, reply: @escaping (Data) -> Void) {
        engine.quarantine(path: path, reason: reason, completion: reply)
    }

    func clearAlerts(reply: @escaping (Data) -> Void) {
        engine.clearAlerts(completion: reply)
    }
}

final class MonitorListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: MonitorXPCService

    init(service: MonitorXPCService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MonitorXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

func defaultWatchPaths() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
        home.appendingPathComponent("Downloads"),
        home.appendingPathComponent("Desktop"),
        home.appendingPathComponent("Documents"),
        home.appendingPathComponent("Library/LaunchAgents"),
        home.appendingPathComponent("Library/Application Support"),
        URL(fileURLWithPath: "/Library/LaunchAgents"),
        URL(fileURLWithPath: "/Library/LaunchDaemons"),
        URL(fileURLWithPath: "/Applications"),
    ].filter { FileManager.default.fileExists(atPath: $0.path) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") {
    print("""
    maclean-monitor — real-time macOS scanner

    USAGE
      maclean-monitor [--foreground] [--corpus <path|url>] [--watch <dir>]...
                      [--state-dir <dir>]

    Without --foreground it registers the XPC Mach service
    \(MonitorDefaults.machServiceName); launchd must start it.
    """)
    exit(0)
}

var corpusSource = MonitorDefaults.corpusURL
var watchPaths: [URL] = []
var stateDirectory = MonitorDefaults.supportDirectory
var foreground = false
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--foreground":
        foreground = true
    case "--corpus":
        index += 1
        if index < arguments.count { corpusSource = arguments[index] }
    case "--watch":
        index += 1
        if index < arguments.count {
            watchPaths.append(URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath))
        }
    case "--state-dir":
        index += 1
        if index < arguments.count {
            stateDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
        }
    default:
        break
    }
    index += 1
}

if watchPaths.isEmpty {
    watchPaths = defaultWatchPaths()
}

let engine = MonitorEngine(
    corpusSource: corpusSource,
    watchPaths: watchPaths,
    stateDirectory: stateDirectory
)
let service = MonitorXPCService(engine: engine)

if foreground {
    engine.start { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    RunLoop.main.run()
} else {
    let listener = NSXPCListener(machServiceName: MonitorDefaults.machServiceName)
    let delegate = MonitorListenerDelegate(service: service)
    listener.delegate = delegate
    listener.resume()
    if engine.wasEnabled {
        // Resume monitoring the user left on; retry while offline (corpus download).
        func resume(_ attempt: Int) {
            engine.start { message in
                if message.hasPrefix("Could not load corpus"), attempt < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { resume(attempt + 1) }
                }
            }
        }
        resume(0)
    }
    RunLoop.main.run()
}
