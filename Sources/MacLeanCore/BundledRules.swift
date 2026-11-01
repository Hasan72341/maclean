import Foundation

public enum BundledRules {
    public static func directory(fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []

        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("rules/signature-base-macos", isDirectory: true)
            )
            candidates.append(
                resources.appendingPathComponent("Resources/rules/signature-base-macos", isDirectory: true)
            )
            candidates.append(
                resources.appendingPathComponent(
                    "maclean_MacLeanCore.bundle/Resources/rules/signature-base-macos",
                    isDirectory: true
                )
            )
            candidates.append(
                resources.appendingPathComponent(
                    "maclean_MacLeanCore.bundle/rules/signature-base-macos",
                    isDirectory: true
                )
            )
        }
        if let resources = Bundle.module.resourceURL {
            candidates.append(
                resources.appendingPathComponent("rules/signature-base-macos", isDirectory: true)
            )
            candidates.append(
                resources.appendingPathComponent("Resources/rules/signature-base-macos", isDirectory: true)
            )
        }
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(
                directory.appendingPathComponent("../Resources/rules/signature-base-macos", isDirectory: true)
            )
        }

        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return YaraScanner.ruleFiles(at: candidate, fileManager: fileManager).isEmpty == false
        }
    }

    public static func ruleCount(fileManager: FileManager = .default) -> Int {
        guard let directory = directory(fileManager: fileManager) else { return 0 }
        return YaraScanner.ruleFiles(at: directory, fileManager: fileManager).count
    }
}
