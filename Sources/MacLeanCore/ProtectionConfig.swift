import Foundation

public enum ScanMode: Int, CaseIterable, Codable, Sendable {
    case fast = 1
    case standard = 2
    case protected = 3
    case paranoid = 4
    case smart = 5

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .standard: return "Default"
        case .protected: return "Protected"
        case .paranoid: return "Paranoid"
        case .smart: return "Smart"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "fast": self = .fast
        case "default", "standard": self = .standard
        case "protected": self = .protected
        case "paranoid": self = .paranoid
        case "smart": self = .smart
        default: return nil
        }
    }

    public var canAskPrivilegedAgentAuthorizationOnScan: Bool {
        rawValue >= 2 && rawValue <= 4
    }
}

public struct ScanOption: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let launchItems = ScanOption(rawValue: 0x0001)
    public static let predefinedPaths = ScanOption(rawValue: 0x0002)
    public static let diskURLs = ScanOption(rawValue: 0x0004)
    public static let safariExtensions = ScanOption(rawValue: 0x0008)
    public static let securityIssues = ScanOption(rawValue: 0x0010)
    public static let cronJobs = ScanOption(rawValue: 0x0020)
    public static let configurationProfiles = ScanOption(rawValue: 0x0040)
    public static let runningProcesses = ScanOption(rawValue: 0x0080)
    public static let safariHomepage = ScanOption(rawValue: 0x0100)
    public static let privilegedURLs = ScanOption(rawValue: 0x0200)
    public static let externalDrives = ScanOption(rawValue: 0x0400)
    public static let mailAttachments = ScanOption(rawValue: 0x0800)
    public static let chromeExtensions = ScanOption(rawValue: 0x1000)

    public static let all: ScanOption = [
        .launchItems, .predefinedPaths, .diskURLs, .safariExtensions,
        .securityIssues, .cronJobs, .configurationProfiles, .runningProcesses,
        .safariHomepage, .privilegedURLs, .externalDrives, .mailAttachments,
        .chromeExtensions,
    ]

    public var names: [String] {
        var result: [String] = []
        if contains(.launchItems) { result.append("launch agents/daemons") }
        if contains(.predefinedPaths) { result.append("predefined paths") }
        if contains(.diskURLs) { result.append("disk URLs") }
        if contains(.safariExtensions) { result.append("Safari extensions") }
        if contains(.securityIssues) { result.append("security issues") }
        if contains(.cronJobs) { result.append("cron jobs") }
        if contains(.configurationProfiles) { result.append("configuration profiles") }
        if contains(.runningProcesses) { result.append("running processes") }
        if contains(.safariHomepage) { result.append("Safari homepage") }
        if contains(.privilegedURLs) { result.append("privileged URLs") }
        if contains(.externalDrives) { result.append("external drives") }
        if contains(.mailAttachments) { result.append("mail attachments") }
        if contains(.chromeExtensions) { result.append("Chrome extensions") }
        return result
    }
}

public struct ScanConfiguration: Codable, Sendable {
    public var scanMode: ScanMode
    public var scanOption: ScanOption
    public var cloudFilesProcessMode: Int
    public var maxConcurrentOperationCount: Int
    public var isDMGScanEnabled: Bool
    public var isPKGScanEnabled: Bool
    public var isArchiveScanEnabled: Bool
    public var isPUAScanEnabled: Bool
    public var isProgressEnabled: Bool
    public var diskScanURLs: [String]
    public var maxPKGFileSize: Int64
    public var maxArchiveFileSize: Int64
    public var maxExternalDriveSize: Int64
    public var maxEnumerationDepth: Int
    public var maxPackageEnumerationDepth: Int
    public var maxContainerEnumerationDepth: Int
    public var maxArchiveNestingDepth: Int
    public var maxFileURLsChunkSize: Int
    public var userConsentWaitingTimeout: Double
    public var externalUtilityExecutionTimeout: Double
    public var shouldIncludeIgnoredMalwares: Bool
    public var enumerationSpecialMode: Int
    public var extendedRulesUsageEnabled: Bool
    public var isLicensedDmgSupportEnabled: Bool
    public var maxArchiveTotalUncompressedSize: Int64
    public var maxArchiveExtractedFilesCount: Int
    public var maxArchiveCompressionRatio: Double

    public init() {
        scanMode = .standard
        scanOption = .all
        cloudFilesProcessMode = 0
        maxConcurrentOperationCount = -1
        isDMGScanEnabled = true
        isPKGScanEnabled = true
        isArchiveScanEnabled = false
        isPUAScanEnabled = false
        isProgressEnabled = false
        diskScanURLs = []
        maxPKGFileSize = 100 * 1024 * 1024
        maxArchiveFileSize = 100 * 1024 * 1024
        maxExternalDriveSize = -1
        maxEnumerationDepth = 3
        maxPackageEnumerationDepth = 3
        maxContainerEnumerationDepth = -1
        maxArchiveNestingDepth = 10
        maxFileURLsChunkSize = 500
        userConsentWaitingTimeout = 300
        externalUtilityExecutionTimeout = 30
        shouldIncludeIgnoredMalwares = false
        enumerationSpecialMode = 0
        extendedRulesUsageEnabled = false
        isLicensedDmgSupportEnabled = false
        maxArchiveTotalUncompressedSize = 10 * 1024 * 1024 * 1024
        maxArchiveExtractedFilesCount = 10_000
        maxArchiveCompressionRatio = 500
    }

    public static func fast() -> ScanConfiguration {
        var configuration = ScanConfiguration()
        configuration.scanMode = .fast
        configuration.scanOption = [.launchItems, .predefinedPaths, .diskURLs]
        configuration.isDMGScanEnabled = true
        configuration.isPKGScanEnabled = false
        configuration.isArchiveScanEnabled = false
        configuration.maxEnumerationDepth = 2
        configuration.extendedRulesUsageEnabled = false
        return configuration
    }

    public static func standard() -> ScanConfiguration {
        var configuration = ScanConfiguration()
        configuration.scanMode = .standard
        configuration.scanOption = [
            .launchItems, .predefinedPaths, .diskURLs, .safariExtensions,
            .cronJobs, .configurationProfiles, .runningProcesses, .safariHomepage,
        ]
        configuration.isDMGScanEnabled = true
        configuration.isPKGScanEnabled = true
        configuration.isArchiveScanEnabled = false
        configuration.maxEnumerationDepth = 3
        configuration.extendedRulesUsageEnabled = false
        return configuration
    }

    public static func smart() -> ScanConfiguration {
        var configuration = standard()
        configuration.scanMode = .smart
        return configuration
    }

    public static func protectedScan() -> ScanConfiguration {
        var configuration = ScanConfiguration()
        configuration.scanMode = .protected
        configuration.scanOption = .all
        configuration.isDMGScanEnabled = true
        configuration.isPKGScanEnabled = true
        configuration.isArchiveScanEnabled = true
        configuration.maxEnumerationDepth = 5
        configuration.extendedRulesUsageEnabled = false
        return configuration
    }

    public static func protectedWithDirectories(_ urls: [URL]) -> ScanConfiguration {
        var configuration = ScanConfiguration()
        configuration.scanMode = .protected
        configuration.scanOption = [.diskURLs]
        configuration.diskScanURLs = urls.map(\.path)
        configuration.isDMGScanEnabled = true
        configuration.isPKGScanEnabled = true
        configuration.isArchiveScanEnabled = true
        configuration.maxEnumerationDepth = 5
        configuration.extendedRulesUsageEnabled = false
        configuration.maxArchiveCompressionRatio = 1000
        configuration.maxArchiveExtractedFilesCount = 30_000
        return configuration
    }

    public static func paranoid() -> ScanConfiguration {
        var configuration = protectedScan()
        configuration.scanMode = .paranoid
        configuration.maxArchiveNestingDepth = 20
        configuration.maxArchiveFileSize = 512 * 1024 * 1024
        configuration.maxEnumerationDepth = -1
        configuration.maxPackageEnumerationDepth = -1
        configuration.enumerationSpecialMode = 1
        configuration.extendedRulesUsageEnabled = true
        configuration.isLicensedDmgSupportEnabled = true
        return configuration
    }

    public static func paranoidWithDirectories(_ urls: [URL]) -> ScanConfiguration {
        var configuration = paranoid()
        configuration.scanOption = [.diskURLs]
        configuration.diskScanURLs = urls.map(\.path)
        return configuration
    }

    public var optionsDescription: String {
        scanOption.names.joined(separator: ", ")
    }
}
