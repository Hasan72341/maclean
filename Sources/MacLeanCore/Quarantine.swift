import Foundation

public struct QuarantineRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let originalPath: String
    public let quarantinedPath: String
    public let reason: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        originalPath: String,
        quarantinedPath: String,
        reason: String
    ) {
        self.id = id
        self.date = date
        self.originalPath = originalPath
        self.quarantinedPath = quarantinedPath
        self.reason = reason
    }
}

public enum QuarantineError: LocalizedError {
    case missing(String)
    case forbidden(String)
    case symbolicLink(String)
    case move(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): return "\(path) no longer exists"
        case .forbidden(let path): return "refusing to quarantine \(path)"
        case .symbolicLink(let path): return "\(path) is a symbolic link"
        case .move(let message): return "could not quarantine file: \(message)"
        }
    }
}

public enum QuarantineManager {
    public static var root: URL {
        MonitorDefaults.supportDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    public static func quarantine(
        path: String,
        reason: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        root: URL? = nil
    ) throws -> QuarantineRecord {
        let source = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: source.path) else {
            throw QuarantineError.missing(path)
        }
        let metadata = try fileManager.attributesOfItem(atPath: source.path)
        if metadata[.type] as? FileAttributeType == .typeSymbolicLink {
            throw QuarantineError.symbolicLink(path)
        }

        try Safety.validate(
            path: source.path,
            roots: [home, URL(fileURLWithPath: "/Applications")],
            home: home,
            fileManager: fileManager
        )

        let id = UUID()
        let container = (root ?? Self.root).appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: container.path
            )
            let destination = container.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                try fileManager.copyItem(at: source, to: destination)
                try fileManager.removeItem(at: source)
            }

            let record = QuarantineRecord(
                id: id,
                originalPath: PathCanon.resolve(path),
                quarantinedPath: destination.path,
                reason: reason
            )
            let data = try JSONEncoder().encode(record)
            let metadataURL = container.appendingPathComponent("metadata.json")
            try data.write(to: metadataURL, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadataURL.path
            )
            return record
        } catch let error as QuarantineError {
            throw error
        } catch {
            throw QuarantineError.move(error.localizedDescription)
        }
    }

    public static func records(
        fileManager: FileManager = .default,
        root: URL? = nil
    ) -> [QuarantineRecord] {
        let directory = root ?? Self.root
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { directory in
            let url = directory.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(QuarantineRecord.self, from: data)
        }.sorted { $0.date > $1.date }
    }
}
