import Foundation

public struct DeepReport: Codable, Sendable {
    public let generated: Date
    public let permissions: PermissionReport
    public let photos: PhotosDuplicateReport
    public let mailTrash: MailTrashReport
    public let protectedStores: ProtectedStoreReport
    public let documentVersions: DocumentVersionsReport

    public init(
        generated: Date = Date(),
        permissions: PermissionReport,
        photos: PhotosDuplicateReport,
        mailTrash: MailTrashReport,
        protectedStores: ProtectedStoreReport,
        documentVersions: DocumentVersionsReport
    ) {
        self.generated = generated
        self.permissions = permissions
        self.photos = photos
        self.mailTrash = mailTrash
        self.protectedStores = protectedStores
        self.documentVersions = documentVersions
    }
}

public enum DeepScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includePermissions: Bool = true,
        includePhotos: Bool = true,
        includeMailTrash: Bool = true,
        includeProtectedStores: Bool = true,
        includeDocumentVersions: Bool = true,
        includeSimilarPhotos: Bool = false
    ) -> DeepReport {
        DeepReport(
            permissions: includePermissions
                ? PermissionsScanner.scan(home: home)
                : .empty,
            photos: includePhotos
                ? PhotosDuplicateScanner.scan(
                    home: home,
                    includeSimilar: includeSimilarPhotos
                )
                : .empty,
            mailTrash: includeMailTrash
                ? MailTrashScanner.scan(home: home)
                : .empty,
            protectedStores: includeProtectedStores
                ? ProtectedStoreScanner.scan()
                : .empty,
            documentVersions: includeDocumentVersions
                ? DocumentVersionsScanner.scan(home: home)
                : .empty
        )
    }
}
