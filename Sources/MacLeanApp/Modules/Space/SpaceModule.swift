import MacLeanCore
import SwiftUI

enum SpaceRoute: Hashable {
    case lensHome
    case lens(String)
    case lensLargest(String)
    case lensTypes(String)
    case lensSmall(String)
    case fileDetail(String)
    case largeOldFiles
    case duplicates
    case duplicateGroup(String)
    case similarImages
    case similarGroup(String)
    case diskImages
    case projectArtifacts
    case downloads
    case downloadsBucket(String)
    case fileTypes
    case typeFiles(String)
    case extensions
    case cloud
    case cloudProvider(String)
    case cloudLargeFiles
    case mailAttachments
    case mailAccount(String)
    case emptyFolders
    case archives
    case trash
    case volumes
    case diskActivity
}

enum SpaceModule {
    @MainActor @ViewBuilder
    static func root() -> some View {
        SpaceOverviewScreen()
    }

    @MainActor @ViewBuilder
    static func destination(_ route: SpaceRoute) -> some View {
        switch route {
        case .lensHome: SpaceLensHomeScreen()
        case .lens(let path): SpaceLensScreen(path: path)
        case .lensLargest(let path): SpaceLensLargestScreen(path: path)
        case .lensTypes(let path): SpaceLensTypesScreen(path: path)
        case .lensSmall(let path): SpaceLensSmallScreen(path: path)
        case .fileDetail(let path): SpaceFileDetailScreen(path: path)
        case .largeOldFiles: SpaceLargeFilesScreen()
        case .duplicates: SpaceDuplicatesScreen()
        case .duplicateGroup(let hash): SpaceDuplicateGroupScreen(hash: hash)
        case .similarImages: SpaceSimilarScreen()
        case .similarGroup(let key): SpaceSimilarGroupScreen(key: key)
        case .diskImages: SpaceDiskImagesScreen()
        case .projectArtifacts: SpaceProjectArtifactsScreen()
        case .downloads: SpaceDownloadsScreen()
        case .downloadsBucket(let key): SpaceDownloadsBucketScreen(key: key)
        case .fileTypes: SpaceFileTypesScreen()
        case .typeFiles(let kind): SpaceTypeFilesScreen(kind: kind)
        case .extensions: SpaceExtensionsScreen()
        case .cloud: SpaceCloudScreen()
        case .cloudProvider(let path): SpaceCloudProviderScreen(path: path)
        case .cloudLargeFiles: SpaceCloudLargeFilesScreen()
        case .mailAttachments: SpaceMailScreen()
        case .mailAccount(let account): SpaceMailAccountScreen(account: account)
        case .emptyFolders: SpaceEmptyFoldersScreen()
        case .archives: SpaceArchivesScreen()
        case .trash: SpaceTrashScreen()
        case .volumes: SpaceVolumesScreen()
        case .diskActivity: SpaceDiskActivityScreen()
        }
    }

    static func title(_ route: SpaceRoute) -> String {
        switch route {
        case .lensHome: return "Space Lens"
        case .lens(let path): return path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent
        case .lensLargest: return "Largest Files"
        case .lensTypes: return "File Types"
        case .lensSmall: return "Smaller Items"
        case .fileDetail(let path): return (path as NSString).lastPathComponent
        case .largeOldFiles: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .duplicateGroup: return "Duplicate Group"
        case .similarImages: return "Similar Images"
        case .similarGroup: return "Similar Group"
        case .diskImages: return "Disk Images"
        case .projectArtifacts: return "Project Build Files"
        case .downloads: return "Downloads"
        case .downloadsBucket(let key): return SpaceDownloadsKey.title(key)
        case .fileTypes: return "File Types"
        case .typeFiles(let kind): return SpaceKind(rawValue: kind)?.title ?? kind
        case .extensions: return "Extensions"
        case .cloud: return "Cloud Storage"
        case .cloudProvider(let path): return (path as NSString).lastPathComponent
        case .cloudLargeFiles: return "Large Cloud Files"
        case .mailAttachments: return "Mail Attachments"
        case .mailAccount(let account): return account.isEmpty ? "Mail" : account
        case .emptyFolders: return "Empty Folders"
        case .archives: return "Archives & Installers"
        case .trash: return "Trash"
        case .volumes: return "Volumes"
        case .diskActivity: return "Disk Activity"
        }
    }
}

enum SpaceDownloadsKey {
    static func title(_ key: String) -> String {
        if key == "installers" { return "Old Installers" }
        if key == "folders" { return "Downloads · Folders" }
        if key.hasPrefix("kind:"), let k = SpaceKind(rawValue: String(key.dropFirst(5))) { return "Downloads · " + k.title }
        if key.hasPrefix("age:"), let a = SpaceAgeBucket(rawValue: String(key.dropFirst(4))) { return "Downloads · " + a.title }
        return "Downloads"
    }

    static func matches(_ key: String, _ f: SpaceFile) -> Bool {
        if key == "installers" { return SpaceStore.isStaleInstaller(f) }
        if key == "folders" { return f.isDirectory }
        if key.hasPrefix("kind:") { return !f.isDirectory && f.kind.rawValue == String(key.dropFirst(5)) }
        if key.hasPrefix("age:") { return SpaceAgeBucket.of(f.ageReference).rawValue == String(key.dropFirst(4)) }
        return true
    }
}
