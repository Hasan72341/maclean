import MacLeanCore
import SwiftUI

enum ProtectionRoute: Hashable {
    case profiles
    case profileDetail(String)
    case scanRun
    case findings
    case findingsSeverity(String)
    case findingsKind(String)
    case findingDetail(String)
    case history
    case quarantine
    case quarantineRecord(String)
    case realtime
    case watchedPaths
    case alerts
    case alertDetail(String)
    case yaraRules
    case yaraRuleFile(String)
    case corpus
    case deepScan
    case mailTrash
    case mailbox(String)
    case photosDuplicates
    case photoGroup(String)
    case photoLibraries
    case documentVersions
    case documentVersionFile(String)
    case deletedUsers
    case systemCaches
    case storeItem(String)
    case universalBinaries
    case universalBinaryDetail(String)
}

enum ProtectionModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        ProtectionOverviewScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: ProtectionRoute) -> some View {
        switch route {
        case .profiles: ProtectionProfilesScreen()
        case .profileDetail(let id): ProtectionProfileDetailScreen(profileID: id)
        case .scanRun: ProtectionScanRunScreen()
        case .findings: ProtectionFindingsScreen()
        case .findingsSeverity(let severity): ProtectionFindingListScreen(filter: .severity(severity))
        case .findingsKind(let kind): ProtectionFindingListScreen(filter: .kind(kind))
        case .findingDetail(let id): ProtectionFindingDetailScreen(findingID: id)
        case .history: ProtectionHistoryScreen()
        case .quarantine: ProtectionQuarantineScreen()
        case .quarantineRecord(let id): ProtectionQuarantineRecordScreen(recordID: id)
        case .realtime: ProtectionRealtimeScreen()
        case .watchedPaths: ProtectionWatchedPathsScreen()
        case .alerts: ProtectionAlertsScreen()
        case .alertDetail(let id): ProtectionAlertDetailScreen(alertID: id)
        case .yaraRules: ProtectionRulesScreen()
        case .yaraRuleFile(let name): ProtectionRuleFileScreen(name: name)
        case .corpus: ProtectionCorpusScreen()
        case .deepScan: ProtectionDeepScanScreen()
        case .mailTrash: ProtectionMailTrashScreen()
        case .mailbox(let path): ProtectionMailboxScreen(path: path)
        case .photosDuplicates: ProtectionPhotosScreen()
        case .photoGroup(let hash): ProtectionPhotoGroupScreen(hash: hash)
        case .photoLibraries: ProtectionPhotoLibrariesScreen()
        case .documentVersions: ProtectionDocumentsScreen()
        case .documentVersionFile(let path): ProtectionDocumentFileScreen(path: path)
        case .deletedUsers: ProtectionStoreListScreen(kind: "deleted-user")
        case .systemCaches: ProtectionStoreListScreen(kind: "system-cache")
        case .storeItem(let path): ProtectionStoreItemScreen(path: path)
        case .universalBinaries: ProtectionUniversalScreen()
        case .universalBinaryDetail(let path): ProtectionUniversalDetailScreen(path: path)
        }
    }

    static func title(_ route: ProtectionRoute) -> String {
        switch route {
        case .profiles: return "Scan Profiles"
        case .profileDetail(let id): return ProtectionProfile.find(id)?.title ?? "Profile"
        case .scanRun: return "Scan"
        case .findings: return "Findings"
        case .findingsSeverity(let s): return "\(s.capitalized) Findings"
        case .findingsKind(let k): return k
        case .findingDetail: return "Finding"
        case .history: return "Scan History"
        case .quarantine: return "Quarantine"
        case .quarantineRecord: return "Quarantined Item"
        case .realtime: return "Realtime Monitor"
        case .watchedPaths: return "Watched Folders"
        case .alerts: return "Alerts"
        case .alertDetail: return "Alert"
        case .yaraRules: return "YARA Rules"
        case .yaraRuleFile(let name): return name
        case .corpus: return "Malware Corpus"
        case .deepScan: return "Deep Scan"
        case .mailTrash: return "Mail Trash"
        case .mailbox: return "Mailbox"
        case .photosDuplicates: return "Photos Duplicates"
        case .photoGroup: return "Duplicate Group"
        case .photoLibraries: return "Photos Libraries"
        case .documentVersions: return "Document Versions"
        case .documentVersionFile(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .deletedUsers: return "Deleted Users"
        case .systemCaches: return "System Caches & Logs"
        case .storeItem(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .universalBinaries: return "Universal Binaries"
        case .universalBinaryDetail(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}
