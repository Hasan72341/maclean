import AppKit
import Combine
import Darwin
import Foundation
import MacLeanCore
import SwiftUI

// MARK: - Models

struct MonitorProcessDetails: Sendable, Equatable {
    var pid: Int32
    var name: String?
    var path: String?
    var ppid: Int32?
    var uid: UInt32?
    var threads: Int?
    var startDate: Date?
    var virtualBytes: Int64?
    var residentBytes: Int64?
    var nice: Int32?
    var alive = true
}

struct MonitorVolume: Sendable, Identifiable, Hashable {
    var path: String
    var name: String
    var format: String
    var total: Int64
    var available: Int64
    var availableImportant: Int64
    var isRemovable: Bool
    var isEjectable: Bool
    var isInternal: Bool
    var isReadOnly: Bool
    var isRoot: Bool
    var isLocal: Bool
    var uuid: String?
    var id: String { path }
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct MonitorInterfaceInfo: Sendable, Equatable {
    var name: String
    var ipv4: [String] = []
    var ipv6: [String] = []
    var mac: String?
    var mtu: Int?
    var baudrate: Int64?
    var packetsIn: Int64 = 0
    var packetsOut: Int64 = 0
    var errorsIn: Int64 = 0
    var errorsOut: Int64 = 0
    var isUp = false
    var isRunning = false
    var isLoopback = false
}

struct MonitorSystemInfo: Sendable, Equatable {
    var model: String = "—"
    var marketingName: String?
    var modelNumber: String?
    var chip: String = "—"
    var logicalCores: Int = 0
    var physicalCores: Int = 0
    var performanceCores: Int?
    var efficiencyCores: Int?
    var memory: Int64 = 0
    var osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    var kernel: String?
    var hostname: String = ProcessInfo.processInfo.hostName
    var bootTime: Date?
    var firmware: String?
    var sip: String?
    var secureVM: String?
    var pageSize: Int = Int(sysconf(_SC_PAGESIZE))
    var architecture: String = "—"
}

struct MonitorAssertion: Sendable, Identifiable, Hashable {
    var pid: Int32
    var process: String
    var age: String
    var type: String
    var name: String
    var id: String { "\(pid)-\(type)-\(name)-\(age)" }
}

struct MonitorAssertionReport: Sendable, Equatable {
    var systemWide: [(name: String, value: Int)] = []
    var owners: [MonitorAssertion] = []
    var raw: String = ""

    static func == (lhs: MonitorAssertionReport, rhs: MonitorAssertionReport) -> Bool {
        lhs.raw == rhs.raw
    }
}

struct MonitorCommandOutput: Sendable, Equatable {
    var title: String
    var command: String
    var status: Int32
    var output: String
    var date = Date()
}

// MARK: - Low-level inspectors (read-only)

enum MonitorProbe {
    static func cString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = cString(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == 4 { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024 * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return cString(buffer)
    }

    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func commName(_ info: kinfo_proc) -> String {
        var comm = info.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func details(_ pid: Int32) -> MonitorProcessDetails {
        var result = MonitorProcessDetails(pid: pid)
        result.path = executablePath(pid)
        if let info = kinfo(pid) {
            result.alive = info.kp_proc.p_pid == pid
            result.name = commName(info)
            result.ppid = info.kp_eproc.e_ppid
            result.uid = info.kp_eproc.e_ucred.cr_uid
            let start = info.kp_proc.p_un.__p_starttime
            result.startDate = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
            result.nice = Int32(info.kp_proc.p_nice)
        } else {
            result.alive = false
        }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size {
            result.threads = Int(task.pti_threadnum)
            result.virtualBytes = Int64(task.pti_virtual_size)
            result.residentBytes = Int64(task.pti_resident_size)
        }
        return result
    }

    /// pid -> ppid for every process the kernel reports.
    static func parentMap() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var map: [Int32: Int32] = [:]
        for index in 0..<min(count, list.count) {
            map[list[index].kp_proc.p_pid] = list[index].kp_eproc.e_ppid
        }
        return map
    }

    static func userName(_ uid: UInt32) -> String? {
        guard let entry = getpwuid(uid) else { return nil }
        return String(cString: entry.pointee.pw_name)
    }

    static func interfaces() -> [String: MonitorInterfaceInfo] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [:] }
        defer { freeifaddrs(pointer) }
        var result: [String: MonitorInterfaceInfo] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            var info = result[name] ?? MonitorInterfaceInfo(name: name)
            let flags = Int32(entry.pointee.ifa_flags)
            info.isUp = flags & IFF_UP != 0
            info.isRunning = flags & IFF_RUNNING != 0
            info.isLoopback = flags & IFF_LOOPBACK != 0
            guard let addr = entry.pointee.ifa_addr else {
                result[name] = info
                continue
            }
            let family = Int32(addr.pointee.sa_family)
            if family == AF_LINK {
                if let data = entry.pointee.ifa_data {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    info.mtu = Int(stats.ifi_mtu)
                    info.baudrate = Int64(stats.ifi_baudrate)
                    info.packetsIn = Int64(stats.ifi_ipackets)
                    info.packetsOut = Int64(stats.ifi_opackets)
                    info.errorsIn = Int64(stats.ifi_ierrors)
                    info.errorsOut = Int64(stats.ifi_oerrors)
                }
                info.mac = macAddress(addr)
            } else if family == AF_INET || family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = cString(host)
                    if family == AF_INET { info.ipv4.append(text) } else { info.ipv6.append(text) }
                }
            }
            result[name] = info
        }
        return result
    }

    private static func macAddress(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
            let alen = Int(dl.pointee.sdl_alen)
            let nlen = Int(dl.pointee.sdl_nlen)
            guard alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) else { return nil }
            let base = UnsafeRawPointer(dl).advanced(by: offset + nlen)
            let bytes = (0..<alen).map { base.load(fromByteOffset: $0, as: UInt8.self) }
            if bytes.allSatisfy({ $0 == 0 }) { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    static func volumes() -> [MonitorVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeUUIDStringKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            return MonitorVolume(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                format: values.volumeLocalizedFormatDescription ?? "—",
                total: Int64(values.volumeTotalCapacity ?? 0),
                available: max(Int64(values.volumeAvailableCapacity ?? 0), important),
                availableImportant: important,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                isReadOnly: values.volumeIsReadOnly ?? false,
                isRoot: values.volumeIsRootFileSystem ?? false,
                isLocal: values.volumeIsLocal ?? true,
                uuid: values.volumeUUIDString
            )
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    static func systemInfo() -> MonitorSystemInfo {
        var info = MonitorSystemInfo()
        info.model = sysctlString("hw.model") ?? "—"
        info.chip = sysctlString("machdep.cpu.brand_string") ?? "—"
        info.logicalCores = Int(sysctlInt("hw.logicalcpu") ?? sysctlInt("hw.ncpu") ?? 0)
        info.physicalCores = Int(sysctlInt("hw.physicalcpu") ?? 0)
        info.performanceCores = sysctlInt("hw.perflevel0.physicalcpu").map(Int.init)
        info.efficiencyCores = sysctlInt("hw.perflevel1.physicalcpu").map(Int.init)
        info.memory = sysctlInt("hw.memsize") ?? Int64(ProcessInfo.processInfo.physicalMemory)
        info.kernel = sysctlString("kern.version")?.components(separatedBy: ":").first
        info.hostname = sysctlString("kern.hostname") ?? ProcessInfo.processInfo.hostName
        info.bootTime = bootTime()
        info.architecture = sysctlInt("hw.optional.arm64") == 1 ? "Apple silicon (arm64)" : "Intel (x86_64)"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        info.osVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let profiler = ProcessRunner.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "SPSoftwareDataType", "-json"], timeout: 30)
        if profiler.status == 0,
           let data = profiler.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first {
                info.marketingName = hw["machine_name"] as? String
                info.modelNumber = hw["model_number"] as? String
                info.firmware = (hw["boot_rom_version"] as? String) ?? (hw["os_loader_version"] as? String)
                if info.chip == "—", let chip = hw["chip_type"] as? String { info.chip = chip }
            }
            if let sw = (json["SPSoftwareDataType"] as? [[String: Any]])?.first {
                if let os = sw["os_version"] as? String { info.osVersion = os }
                if let sip = sw["system_integrity"] as? String {
                    info.sip = sip.contains("enabled") ? "Enabled" : (sip.contains("disabled") ? "Disabled" : sip)
                }
                if let vm = sw["secure_vm"] as? String {
                    info.secureVM = vm.contains("enabled") ? "Enabled" : (vm.contains("disabled") ? "Disabled" : vm)
                }
            }
        }
        return info
    }

    static func assertions() -> MonitorAssertionReport {
        let result = ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"], timeout: 15)
        var report = MonitorAssertionReport(raw: result.stdout + result.stderr)
        var section = 0
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Assertion status system-wide") { section = 1; continue }
            if line.hasPrefix("Listed by owning process") { section = 2; continue }
            if line.hasPrefix("Kernel Assertions") || line.hasPrefix("Idle sleep preventers") { section = 3; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if section == 1 {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, let value = Int(parts[parts.count - 1]) {
                    report.systemWide.append((parts.dropLast().joined(separator: " "), value))
                }
            } else if section == 2, trimmed.hasPrefix("pid ") {
                if let assertion = parseOwner(trimmed) { report.owners.append(assertion) }
            }
        }
        return report
    }

    private static func parseOwner(_ line: String) -> MonitorAssertion? {
        // pid 123(name): [0x0000...] 00:12:34 PreventUserIdleSystemSleep named: "reason"
        let afterPid = line.dropFirst(4)
        guard let open = afterPid.firstIndex(of: "("),
              let pid = Int32(afterPid[..<open]),
              let close = afterPid.range(of: "):")?.lowerBound else { return nil }
        let process = String(afterPid[afterPid.index(after: open)..<close])
        var rest = String(afterPid[afterPid.index(close, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
            rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var name = parts.count > 2 ? String(parts[2]) : ""
        if let range = name.range(of: "named:") {
            name = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let quoteEnd = name.dropFirst().firstIndex(of: "\""), name.hasPrefix("\"") {
                name = String(name[name.index(after: name.startIndex)..<quoteEnd])
            }
        }
        return MonitorAssertion(pid: pid, process: process, age: String(parts[0]), type: String(parts[1]), name: name)
    }

    static func run(_ title: String, _ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> MonitorCommandOutput {
        let result = ProcessRunner.run(executable, arguments, timeout: timeout)
        var output = result.stdout
        if !result.stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + result.stderr }
        if result.timedOut { output += "\n(timed out)" }
        return MonitorCommandOutput(
            title: title,
            command: ([executable] + arguments).joined(separator: " "),
            status: result.status,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Runs a fixed shell command through the macOS administrator prompt.
    static func runAsAdmin(_ title: String, _ shellCommand: String) -> MonitorCommandOutput {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var output = run(title, "/usr/bin/osascript", ["-e", script], timeout: 180)
        output.command = "sudo " + shellCommand
        return output
    }

    /// Sends a signal; refuses launchd, the kernel, and MacLean itself.
    static func signal(_ pid: Int32, _ sig: Int32) -> String? {
        guard pid > 1 else { return "Refusing to signal a system root process (pid \(pid))." }
        guard pid != getpid() else { return "Refusing to signal MacLean itself." }
        if Darwin.kill(pid, sig) == 0 { return nil }
        let code = errno
        if code == EPERM { return "Permission denied — the process belongs to another user or the system." }
        if code == ESRCH { return "No such process (already exited)." }
        return String(cString: strerror(code))
    }
}

// MARK: - Store

@MainActor
final class MonitorStore: ObservableObject {
    static let shared = MonitorStore()
    static let historyLength = 120

    @Published private(set) var processCPU: [Int32: [Double]] = [:]
    @Published private(set) var processMemory: [Int32: [Double]] = [:]
    @Published private(set) var interfaceRx: [String: [Double]] = [:]
    @Published private(set) var interfaceTx: [String: [Double]] = [:]
    @Published private(set) var batteryHistory: [Double] = []
    @Published private(set) var batteryTempHistory: [Double] = []
    @Published private(set) var thermalHistory: [Double] = []
    @Published private(set) var load5History: [Double] = []
    @Published private(set) var load15History: [Double] = []
    @Published private(set) var processCountHistory: [Double] = []
    @Published private(set) var peakCPU: Double = 0
    @Published private(set) var peakMemory: Int64 = 0
    @Published private(set) var peakRx: Double = 0
    @Published private(set) var peakTx: Double = 0
    @Published private(set) var startedAt = Date()
    @Published private(set) var sampleCount = 0
    @Published var paused = false

    @Published private(set) var systemInfo: MonitorSystemInfo?
    @Published private(set) var systemInfoState: LoadState = .idle
    @Published private(set) var volumes: [MonitorVolume] = []
    @Published private(set) var volumesState: LoadState = .idle
    @Published private(set) var interfaces: [String: MonitorInterfaceInfo] = [:]
    @Published private(set) var interfacesState: LoadState = .idle
    @Published private(set) var assertions = MonitorAssertionReport()
    @Published private(set) var assertionsState: LoadState = .idle
    @Published private(set) var thermalReport: MonitorCommandOutput?
    @Published private(set) var thermalReportState: LoadState = .idle
    @Published private(set) var vmStats: MemoryStats?
    @Published private(set) var vmStatsState: LoadState = .idle
    @Published private(set) var snapshots: [String] = []
    @Published private(set) var snapshotsState: LoadState = .idle
    @Published private(set) var parents: [Int32: Int32] = [:]
    @Published private(set) var parentsState: LoadState = .idle
    @Published private(set) var details: [Int32: MonitorProcessDetails] = [:]
    @Published private(set) var trash: SizeInfo?
    @Published private(set) var trashState: LoadState = .idle
    @Published var lastCommand: MonitorCommandOutput?
    @Published var actionBusy = false
    @Published var lastFailures: [(path: String, reason: String)] = []

    private var cancellables: Set<AnyCancellable> = []
    private var lastInterfaceBytes: [String: (rx: Int64, tx: Int64, date: Date)] = [:]

    private init() {
        let monitor = SystemMonitor.shared
        monitor.$processes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                MainActor.assumeIsolated { self?.ingest(processes: list) }
            }
            .store(in: &cancellables)
        monitor.$latest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.ingest(snapshot: snapshot) }
            }
            .store(in: &cancellables)
    }

    // MARK: Live ingestion

    private func ingest(processes list: [ProcessSample]) {
        guard !list.isEmpty else { return }
        var cpu = processCPU
        var memory = processMemory
        let alive = Set(list.map(\.pid))
        for process in list {
            Self.push(&cpu[process.pid, default: []], process.cpu)
            Self.push(&memory[process.pid, default: []], Double(process.memory))
        }
        for pid in cpu.keys where !alive.contains(pid) {
            cpu[pid] = nil
            memory[pid] = nil
        }
        processCPU = cpu
        processMemory = memory
    }

    private func ingest(snapshot s: MetricsSnapshot) {
        guard s.processCount > 0 else { return }
        sampleCount += 1
        peakCPU = max(peakCPU, s.cpu.total)
        peakMemory = max(peakMemory, s.memory.used)
        peakRx = max(peakRx, s.network.rxPerSec)
        peakTx = max(peakTx, s.network.txPerSec)
        if let battery = s.battery {
            Self.push(&batteryHistory, Double(battery.percent))
            if let temp = battery.temperatureC { Self.push(&batteryTempHistory, temp) }
        }
        Self.push(&thermalHistory, Double(s.thermalState.rawValue))
        if s.loadAverage.count == 3 {
            Self.push(&load5History, s.loadAverage[1])
            Self.push(&load15History, s.loadAverage[2])
        }
        Self.push(&processCountHistory, Double(s.processCount))

        let now = s.date
        var rx = interfaceRx
        var tx = interfaceTx
        for iface in s.network.interfaces {
            if let prev = lastInterfaceBytes[iface.name] {
                let dt = now.timeIntervalSince(prev.date)
                if dt > 0 {
                    Self.push(&rx[iface.name, default: []], max(0, Double(iface.rxBytes - prev.rx) / dt))
                    Self.push(&tx[iface.name, default: []], max(0, Double(iface.txBytes - prev.tx) / dt))
                }
            }
            lastInterfaceBytes[iface.name] = (iface.rxBytes, iface.txBytes, now)
        }
        interfaceRx = rx
        interfaceTx = tx
    }

    private static func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > historyLength { array.removeFirst(array.count - historyLength) }
    }

    func resetPeaks() {
        peakCPU = 0
        peakMemory = 0
        peakRx = 0
        peakTx = 0
        startedAt = Date()
        sampleCount = 0
    }

    // MARK: Sampling control

    func setPaused(_ value: Bool) {
        paused = value
        if value { SystemMonitor.shared.stop() } else { SystemMonitor.shared.start() }
    }

    // MARK: Datasets

    func loadSystemInfo(force: Bool = false) async {
        if !force, systemInfo != nil || systemInfoState.isLoading { return }
        systemInfoState = .loading("Reading hardware and software profile…")
        let info = await engine(priority: .utility) { MonitorProbe.systemInfo() }
        systemInfo = info
        systemInfoState = .loaded(Date())
    }

    func loadVolumes(force: Bool = false) async {
        if !force, volumesState.loadedAt != nil || volumesState.isLoading { return }
        volumesState = .loading("Reading mounted volumes…")
        volumes = await engine { MonitorProbe.volumes() }
        volumesState = .loaded(Date())
    }

    func loadInterfaces(force: Bool = false) async {
        if !force, interfacesState.loadedAt != nil || interfacesState.isLoading { return }
        interfacesState = .loading("Reading network interfaces…")
        interfaces = await engine { MonitorProbe.interfaces() }
        interfacesState = .loaded(Date())
    }

    func loadAssertions(force: Bool = false) async {
        if !force, assertionsState.loadedAt != nil || assertionsState.isLoading { return }
        assertionsState = .loading("Reading power assertions…")
        let report = await engine(priority: .utility) { MonitorProbe.assertions() }
        assertions = report
        assertionsState = report.raw.isEmpty ? .failed("pmset returned no output") : .loaded(Date())
    }

    func loadThermalReport(force: Bool = false) async {
        if !force, thermalReportState.loadedAt != nil || thermalReportState.isLoading { return }
        thermalReportState = .loading("Reading pmset thermal report…")
        let output = await engine(priority: .utility) { MonitorProbe.run("Thermal report", "/usr/bin/pmset", ["-g", "therm"], timeout: 15) }
        thermalReport = output
        thermalReportState = output.status == 0 ? .loaded(Date()) : .failed("pmset exited \(output.status)")
    }

    func loadVMStats(force: Bool = false) async {
        if !force, vmStatsState.loadedAt != nil || vmStatsState.isLoading { return }
        vmStatsState = .loading("Running vm_stat through the engine…")
        let stats = await engine(priority: .utility) { PerformanceScanner.memory() }
        vmStats = stats
        vmStatsState = stats == nil ? .failed("vm_stat failed") : .loaded(Date())
    }

    func loadSnapshots(force: Bool = false) async {
        if !force, snapshotsState.loadedAt != nil || snapshotsState.isLoading { return }
        snapshotsState = .loading("Listing local Time Machine snapshots…")
        snapshots = await engine(priority: .utility) { PerformanceScanner.localSnapshots() }
        snapshotsState = .loaded(Date())
    }

    func loadParents(force: Bool = false) async {
        if !force, parentsState.isLoading { return }
        if !force, let loaded = parentsState.loadedAt, Date().timeIntervalSince(loaded) < 5 { return }
        parentsState = .loading("Reading process tree…")
        parents = await engine { MonitorProbe.parentMap() }
        parentsState = .loaded(Date())
    }

    func refreshDetails(_ pid: Int32) async {
        let value = await engine { MonitorProbe.details(pid) }
        details[pid] = value
    }

    func children(of pid: Int32) -> [Int32] {
        parents.filter { $0.value == pid && $0.key != pid }.map(\.key).sorted()
    }

    // MARK: Actions

    /// Sends SIGTERM / SIGKILL to processes the user selected and records the outcome.
    func signal(_ pids: [Int32], force: Bool, names: [Int32: String], memory: [Int32: Int64]) async {
        actionBusy = true
        defer { actionBusy = false }
        let sig = force ? SIGKILL : SIGTERM
        let results = await engine { pids.map { ($0, MonitorProbe.signal($0, sig)) } }
        var summary = RemovalSummary()
        for (pid, error) in results {
            if let error {
                summary.failures.append(("\(names[pid] ?? "pid") (\(pid))", error))
            } else {
                summary.removed += 1
                summary.bytes += memory[pid] ?? 0
            }
        }
        lastFailures = summary.failures
        let title = force ? "Force quit processes" : "Quit processes"
        let detail = results.map { "\(names[$0.0] ?? "?") (\($0.0))" }.joined(separator: ", ")
        ActivityLog.shared.record("Monitor", title, summary, detail: detail)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await SystemMonitor.shared.refreshProcesses()
        await loadParents(force: true)
    }

    /// Escalates a kill through the administrator prompt for processes owned by root or other users.
    func adminSignal(_ pid: Int32, force: Bool, name: String) async {
        guard pid > 1, pid != getpid() else {
            lastCommand = MonitorCommandOutput(title: "Refused", command: "", status: 1, output: "MacLean will not signal pid \(pid).")
            return
        }
        actionBusy = true
        defer { actionBusy = false }
        let flag = force ? "-9" : "-15"
        let output = await engine { MonitorProbe.runAsAdmin("Quit \(name) as administrator", "/bin/kill \(flag) \(pid)") }
        lastCommand = output
        var summary = RemovalSummary()
        if output.status == 0 { summary.removed = 1 } else { summary.failures = [("\(name) (\(pid))", output.output.isEmpty ? "exit \(output.status)" : output.output)] }
        ActivityLog.shared.record("Monitor", force ? "Force quit (admin)" : "Quit (admin)", summary, detail: "\(name) (\(pid))")
        try? await Task.sleep(nanoseconds: 700_000_000)
        await SystemMonitor.shared.refreshProcesses()
    }

    /// Runs /usr/sbin/purge through the administrator prompt and reports the memory delta.
    func purgeMemory() async {
        actionBusy = true
        defer { actionBusy = false }
        let before = SystemMonitor.shared.latest.memory
        let output = await engine { MonitorProbe.runAsAdmin("Purge inactive memory", "/usr/sbin/purge") }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = SystemMonitor.shared.latest.memory
        let gained = max(0, after.free - before.free)
        var result = output
        result.output = (output.output.isEmpty ? "" : output.output + "\n")
            + "Free before: \(Format.bytes(before.free)) · after: \(Format.bytes(after.free)) · cached before: \(Format.bytes(before.cached)) · after: \(Format.bytes(after.cached))"
        lastCommand = result
        var summary = RemovalSummary()
        if output.status == 0 {
            summary.removed = 1
            summary.bytes = gained
        } else {
            summary.failures = [("purge", output.output.isEmpty ? "exit \(output.status)" : output.output)]
        }
        ActivityLog.shared.record("Monitor", "Purge memory", summary)
        await loadVMStats(force: true)
    }

    func loadTrash(force: Bool = false) async {
        if !force, trashState.loadedAt != nil || trashState.isLoading { return }
        trashState = .loading("Measuring the Trash…")
        let url = EngineActions.home.appendingPathComponent(".Trash")
        trash = await engine(priority: .utility) { FileSizer.measure(url) }
        trashState = .loaded(Date())
    }

    func emptyTrash() async {
        actionBusy = true
        defer { actionBusy = false }
        let summary = await EngineActions.emptyTrash()
        lastFailures = summary.failures
        ActivityLog.shared.record("Monitor", "Empty Trash", summary)
        await loadTrash(force: true)
    }

    func eject(_ volume: MonitorVolume) async {
        guard volume.isEjectable || volume.isRemovable, !volume.isRoot else {
            lastFailures = [(volume.path, "This volume is not ejectable.")]
            return
        }
        actionBusy = true
        defer { actionBusy = false }
        let url = URL(fileURLWithPath: volume.path)
        let error: String? = await Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        var summary = RemovalSummary()
        if let error {
            summary.failures = [(volume.path, error)]
        } else {
            summary.removed = 1
        }
        lastFailures = summary.failures
        ToastCenter.shared.show(error == nil ? "Ejected \(volume.name)" : "Eject failed: \(error ?? "")", error: error != nil)
        ActivityLog.shared.add(ActivityEntry(module: "Monitor", title: "Eject \(volume.name)", items: summary.removed, bytes: 0, failures: summary.failures.count, detail: volume.path))
        await loadVolumes(force: true)
    }
}
