import Foundation

public struct UniversalThinResult: Codable, Sendable {
    public var planned: [String] = []
    public var thinned: [String] = []
    public var failed: [DeepCleanFailure] = []
    public var backups: [String] = []

    public init() {}
}

public enum UniversalThinner {
    public static func thin(
        report: ProtectedStoreReport,
        architecture: String,
        apply: Bool,
        resign: Bool = true,
        backupRoot: URL = MonitorDefaults.supportDirectory
            .appendingPathComponent("UniversalBackups", isDirectory: true),
        fileManager: FileManager = .default
    ) -> UniversalThinResult {
        var result = UniversalThinResult()
        for item in report.universalBinaries {
            guard item.archs.count > 1, item.archs.contains(architecture) else {
                continue
            }
            let path = PathCanon.resolve(item.path)
            guard let contentRange = path.range(of: "/Contents/") else {
                result.failed.append(DeepCleanFailure(
                    path: item.path,
                    reason: "not inside an app bundle"
                ))
                continue
            }
            let appPath = String(path[..<contentRange.lowerBound])
            let binary = URL(fileURLWithPath: path)
            guard !isSymbolicLink(path, fileManager: fileManager),
                  let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let mode = attributes[.posixPermissions] as? NSNumber else {
                result.failed.append(DeepCleanFailure(
                    path: item.path,
                    reason: "not a regular writable binary"
                ))
                continue
            }

            result.planned.append(path)
            guard apply else { continue }

            let container = backupRoot.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            let backup = container.appendingPathComponent(binary.lastPathComponent)
            let thin = container.appendingPathComponent("thin-\(binary.lastPathComponent)")
            do {
                try fileManager.createDirectory(
                    at: container,
                    withIntermediateDirectories: true
                )
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: container.path
                )
                try fileManager.copyItem(at: binary, to: backup)
                result.backups.append(backup.path)

                let lipo = ProcessRunner.run(
                    "/usr/bin/lipo",
                    ["-thin", architecture, path, "-output", thin.path],
                    timeout: 60
                )
                guard lipo.status == 0 else {
                    throw ThinnerError("lipo failed: \(lipo.stderr)")
                }
                try fileManager.removeItem(at: binary)
                try fileManager.copyItem(at: thin, to: binary)
                try fileManager.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: binary.path
                )

                if resign {
                    let codesign = ProcessRunner.run(
                        "/usr/bin/codesign",
                        ["--force", "--deep", "--sign", "-", appPath],
                        timeout: 120
                    )
                    guard codesign.status == 0 else {
                        throw ThinnerError("codesign failed: \(codesign.stderr)")
                    }
                }
                result.thinned.append(path)
                try? fileManager.removeItem(at: thin)
            } catch {
                try? fileManager.removeItem(at: binary)
                try? fileManager.copyItem(at: backup, to: binary)
                try? fileManager.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: binary.path
                )
                result.failed.append(DeepCleanFailure(
                    path: path,
                    reason: error.localizedDescription
                ))
            }
        }
        return result
    }

    private static func isSymbolicLink(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return true
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }
}

private struct ThinnerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
