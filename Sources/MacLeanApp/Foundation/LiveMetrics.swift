import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacLeanCore
import SwiftUI

// MARK: - Snapshot types

struct CPUSample: Sendable, Equatable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    var cores: [Double] = []
    var total: Double { min(1, max(0, user + system)) }
}

struct MemorySample: Sendable, Equatable {
    var total: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var free: Int64 = 0
    var active: Int64 = 0
    var inactive: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var appMemory: Int64 = 0
    var cached: Int64 = 0
    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressureLevel: Int = 1
    var used: Int64 { appMemory + wired + compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var pressureTitle: String {
        switch pressureLevel {
        case 4: return "Critical"
        case 2: return "Warning"
        default: return "Normal"
        }
    }
}

struct DiskSample: Sendable, Equatable {
    var total: Int64 = 0
    var available: Int64 = 0
    var availableImportant: Int64 = 0
    var readPerSec: Double = 0
    var writePerSec: Double = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkInterfaceSample: Sendable, Equatable, Identifiable {
    var name: String
    var rxBytes: Int64
    var txBytes: Int64
    var id: String { name }
}

struct NetworkSample: Sendable, Equatable {
    var rxPerSec: Double = 0
    var txPerSec: Double = 0
    var rxTotal: Int64 = 0
    var txTotal: Int64 = 0
    var interfaces: [NetworkInterfaceSample] = []
}

struct BatterySample: Sendable, Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    var designCapacity: Int?
    var maxCapacity: Int?
    var temperatureC: Double?
    var condition: String?
    var healthFraction: Double? {
        guard let designCapacity, let maxCapacity, designCapacity > 0 else { return nil }
        return Double(maxCapacity) / Double(designCapacity)
    }
}

struct ProcessSample: Sendable, Equatable, Identifiable, Hashable {
    var pid: Int32
    var cpu: Double
    var memory: Int64
    var user: String
    var name: String
    var id: Int32 { pid }
}

struct MetricsSnapshot: Sendable, Equatable {
    var date = Date()
    var cpu = CPUSample()
    var memory = MemorySample()
    var disk = DiskSample()
    var network = NetworkSample()
    var battery: BatterySample?
    var loadAverage: [Double] = [0, 0, 0]
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var thermalState: ProcessInfo.ThermalState = .nominal
    var processCount: Int = 0

    var thermalTitle: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// 0...100 composite health used by the dashboard.
    var healthScore: Int {
        var score = 100.0
        score -= max(0, cpu.total - 0.5) * 40
        score -= max(0, memory.usedFraction - 0.7) * 60
        score -= max(0, disk.usedFraction - 0.8) * 120
        if memory.pressureLevel >= 2 { score -= 10 }
        if memory.pressureLevel >= 4 { score -= 15 }
        if thermalState == .serious { score -= 10 }
        if thermalState == .critical { score -= 20 }
        return Int(max(0, min(100, score.rounded())))
    }
}

// MARK: - Sampler (off main actor)

actor MetricsSampler {
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousCoreTicks: [[UInt64]] = []
    private var previousNet: (rx: Int64, tx: Int64, date: Date)?
    private var previousRawNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var netAccum: [String: (rx: Int64, tx: Int64)] = [:]
    private var previousDisk: (read: Int64, write: Int64, date: Date)?
    private var tick = 0
    private var cachedBattery: BatterySample?

    func sample() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        snapshot.cpu = sampleCPU()
        snapshot.memory = sampleMemory()
        snapshot.disk = sampleDisk()
        snapshot.network = sampleNetwork()
        if tick % 10 == 0 { cachedBattery = Self.sampleBattery() }
        snapshot.battery = cachedBattery
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { snapshot.loadAverage = loads }
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.thermalState = ProcessInfo.processInfo.thermalState
        snapshot.processCount = Self.processCount()
        tick += 1
        return snapshot
    }

    private func sampleCPU() -> CPUSample {
        var result = CPUSample()
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let user = UInt64(info.cpu_ticks.0)
            let system = UInt64(info.cpu_ticks.1)
            let idle = UInt64(info.cpu_ticks.2)
            let nice = UInt64(info.cpu_ticks.3)
            if let prev = previousTicks {
                let du = Double(user &- prev.user) + Double(nice &- prev.nice)
                let ds = Double(system &- prev.system)
                let di = Double(idle &- prev.idle)
                let total = du + ds + di
                if total > 0 {
                    result.user = du / total
                    result.system = ds / total
                    result.idle = di / total
                }
            }
            previousTicks = (user, system, idle, nice)
        }

        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &cpuInfoCount) == KERN_SUCCESS,
           let cpuInfo {
            var current: [[UInt64]] = []
            var cores: [Double] = []
            for index in 0..<Int(cpuCount) {
                let base = Int(CPU_STATE_MAX) * index
                let ticks = [
                    UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)])),
                    UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)])),
                    UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)])),
                    UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])),
                ]
                current.append(ticks)
                if index < previousCoreTicks.count {
                    let prev = previousCoreTicks[index]
                    let busy = Double(ticks[0] &- prev[0]) + Double(ticks[1] &- prev[1]) + Double(ticks[3] &- prev[3])
                    let idle = Double(ticks[2] &- prev[2])
                    cores.append(busy + idle > 0 ? busy / (busy + idle) : 0)
                } else {
                    cores.append(0)
                }
            }
            previousCoreTicks = current
            result.cores = cores
            let size = vm_size_t(MemoryLayout<integer_t>.stride * Int(cpuInfoCount))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }
        return result
    }

    private func sampleMemory() -> MemorySample {
        var result = MemorySample()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = Int64(sysconf(_SC_PAGESIZE))
            result.free = Int64(stats.free_count) * page
            result.active = Int64(stats.active_count) * page
            result.inactive = Int64(stats.inactive_count) * page
            result.wired = Int64(stats.wire_count) * page
            result.compressed = Int64(stats.compressor_page_count) * page
            result.appMemory = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
            result.cached = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            result.swapUsed = Int64(swap.xsu_used)
            result.swapTotal = Int64(swap.xsu_total)
        }
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            result.pressureLevel = Int(level)
        }
        return result
    }

    private func sampleDisk() -> DiskSample {
        var result = DiskSample()
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            result.total = Int64(values.volumeTotalCapacity ?? 0)
            result.availableImportant = values.volumeAvailableCapacityForImportantUsage ?? 0
            result.available = max(Int64(values.volumeAvailableCapacity ?? 0), result.availableImportant)
        }
        let io = Self.diskIOTotals()
        result.totalRead = io.read
        result.totalWritten = io.write
        let now = Date()
        if let prev = previousDisk {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0 {
                result.readPerSec = max(0, Double(io.read - prev.read) / dt)
                result.writePerSec = max(0, Double(io.write - prev.write) / dt)
            }
        }
        previousDisk = (io.read, io.write, now)
        return result
    }

    private static func diskIOTotals() -> (read: Int64, write: Int64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: Int64 = 0
        var write: Int64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let unmanaged = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0),
               let stats = unmanaged.takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    private func sampleNetwork() -> NetworkSample {
        var result = NetworkSample()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var raw: [String: (rx: UInt32, tx: UInt32)] = [:]
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            raw[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }
        // The 32-bit counters wrap at 4 GiB; accumulate deltas with wrapping math.
        for (name, value) in raw {
            if let prev = previousRawNet[name] {
                let drx = Int64(value.rx &- prev.rx)
                let dtx = Int64(value.tx &- prev.tx)
                var acc = netAccum[name] ?? (0, 0)
                acc.rx += drx
                acc.tx += dtx
                netAccum[name] = acc
            } else if netAccum[name] == nil {
                netAccum[name] = (Int64(value.rx), Int64(value.tx))
            }
        }
        previousRawNet = raw
        let rx = netAccum.values.reduce(0) { $0 + $1.rx }
        let tx = netAccum.values.reduce(0) { $0 + $1.tx }
        result.rxTotal = rx
        result.txTotal = tx
        result.interfaces = netAccum
            .map { NetworkInterfaceSample(name: $0.key, rxBytes: $0.value.rx, txBytes: $0.value.tx) }
            .filter { $0.rxBytes + $0.txBytes > 0 }
            .sorted { $0.rxBytes + $0.txBytes > $1.rxBytes + $1.txBytes }
        let now = Date()
        if let prev = previousNet {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0 {
                result.rxPerSec = max(0, Double(rx - prev.rx) / dt)
                result.txPerSec = max(0, Double(tx - prev.tx) / dt)
            }
        }
        previousNet = (rx, tx, now)
        return result
    }

    static func sampleBattery() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let state = description[kIOPSPowerSourceStateKey] as? String
            let minutes = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            var sample = BatterySample(
                percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: charging,
                onAC: state == kIOPSACPowerValue,
                minutesRemaining: minutes,
                condition: description["BatteryHealth"] as? String
            )
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber)?.intValue
                }
                sample.cycleCount = prop("CycleCount")
                sample.designCapacity = prop("DesignCapacity")
                sample.maxCapacity = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity")
                if let temp = prop("Temperature") { sample.temperatureC = Double(temp) / 100 }
            }
            return sample
        }
        return nil
    }

    private static func processCount() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return 0 }
        return size / MemoryLayout<kinfo_proc>.stride
    }

    /// Top processes via `ps`. Cheap enough to call every couple of seconds.
    static func processes() -> [ProcessSample] {
        let result = ProcessRunner.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,user=,comm="], timeout: 5)
        guard result.status == 0 else { return [] }
        var list: [ProcessSample] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]) else { continue }
            list.append(ProcessSample(
                pid: pid,
                cpu: Double(parts[1]) ?? 0,
                memory: (Int64(parts[2]) ?? 0) * 1024,
                user: String(parts[3]),
                name: String(parts[4])
            ))
        }
        return list
    }
}

// MARK: - Published monitor

/// Shared real-time system monitor. Samples once per second and keeps a
/// rolling history (120 samples = 2 minutes) for graphs.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let historyLength = 120

    @Published private(set) var latest = MetricsSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var cpuUserHistory: [Double] = []
    @Published private(set) var cpuSystemHistory: [Double] = []
    @Published private(set) var coreHistory: [[Double]] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var memoryBytesHistory: [Double] = []
    @Published private(set) var swapHistory: [Double] = []
    @Published private(set) var compressedHistory: [Double] = []
    @Published private(set) var netRxHistory: [Double] = []
    @Published private(set) var netTxHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var loadHistory: [Double] = []
    @Published private(set) var healthHistory: [Double] = []
    @Published private(set) var processes: [ProcessSample] = []
    @Published var intervalSeconds: Double = 1

    private let sampler = MetricsSampler()
    private var task: Task<Void, Never>?
    private var processTick = 0

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.sampler.sample()
                self.ingest(snapshot)
                if self.processTick % 3 == 0 {
                    let list = await Task.detached(priority: .utility) { MetricsSampler.processes() }.value
                    self.processes = list
                }
                self.processTick += 1
                let nanos = UInt64(max(0.25, self.intervalSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshProcesses() async {
        processes = await Task.detached(priority: .userInitiated) { MetricsSampler.processes() }.value
    }

    private func ingest(_ s: MetricsSnapshot) {
        latest = s
        push(&cpuHistory, s.cpu.total)
        push(&cpuUserHistory, s.cpu.user)
        push(&cpuSystemHistory, s.cpu.system)
        if coreHistory.count != s.cpu.cores.count {
            coreHistory = Array(repeating: [], count: s.cpu.cores.count)
        }
        for (index, value) in s.cpu.cores.enumerated() {
            push(&coreHistory[index], value)
        }
        push(&memoryHistory, s.memory.usedFraction)
        push(&memoryBytesHistory, Double(s.memory.used))
        push(&swapHistory, Double(s.memory.swapUsed))
        push(&compressedHistory, Double(s.memory.compressed))
        push(&netRxHistory, s.network.rxPerSec)
        push(&netTxHistory, s.network.txPerSec)
        push(&diskReadHistory, s.disk.readPerSec)
        push(&diskWriteHistory, s.disk.writePerSec)
        push(&loadHistory, s.loadAverage.first ?? 0)
        push(&healthHistory, Double(s.healthScore))
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLength {
            array.removeFirst(array.count - Self.historyLength)
        }
    }
}
