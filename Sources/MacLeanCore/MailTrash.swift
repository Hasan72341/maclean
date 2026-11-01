import Foundation

public struct MailTrashMailbox: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let account: String
    public let mailbox: String
    public let messageCount: Int
    public let bytes: Int64

    public init(
        path: String,
        account: String,
        mailbox: String,
        messageCount: Int,
        bytes: Int64
    ) {
        self.path = path
        self.account = account
        self.mailbox = mailbox
        self.messageCount = messageCount
        self.bytes = bytes
    }
}

public struct MailTrashReport: Codable, Sendable {
    public let mailboxes: [MailTrashMailbox]
    public let totalBytes: Int64
    public let error: String?

    public init(mailboxes: [MailTrashMailbox], totalBytes: Int64, error: String?) {
        self.mailboxes = mailboxes
        self.totalBytes = totalBytes
        self.error = error
    }

    public static let empty = MailTrashReport(mailboxes: [], totalBytes: 0, error: nil)
}

public enum MailTrashScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeJunk: Bool = false,
        fileManager: FileManager = .default
    ) -> MailTrashReport {
        let roots = [
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail"),
        ]
        var mailboxes: [MailTrashMailbox] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "mbox" else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                let isTrash = lower.contains("deleted messages") || lower.contains("trash")
                let isJunk = includeJunk && lower.contains("junk")
                guard isTrash || isJunk else { continue }
                enumerator.skipDescendants()

                let account = accountName(for: url)
                let (count, bytes) = messageStats(
                    mailbox: url,
                    fileManager: fileManager
                )
                mailboxes.append(
                    MailTrashMailbox(
                        path: url.path,
                        account: account,
                        mailbox: name,
                        messageCount: count,
                        bytes: bytes
                    )
                )
            }
        }

        mailboxes.sort { $0.bytes > $1.bytes }
        return MailTrashReport(
            mailboxes: mailboxes,
            totalBytes: mailboxes.reduce(0) { $0 + $1.bytes },
            error: nil
        )
    }

    private static func messageStats(
        mailbox: URL,
        fileManager: FileManager
    ) -> (Int, Int64) {
        guard let enumerator = fileManager.enumerator(
            at: mailbox,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return (0, 0) }

        var count = 0
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "emlx" else { continue }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    private static func accountName(for mailbox: URL) -> String {
        let components = mailbox.pathComponents
        guard let versionIndex = components.firstIndex(where: {
            $0.first == "V" && $0.dropFirst().allSatisfy(\.isNumber)
        }) else { return "Mail" }
        let next = versionIndex + 1
        if next < components.count {
            return components[next]
        }
        return "Mail"
    }
}
