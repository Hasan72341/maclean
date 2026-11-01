import Foundation

public enum YaraEngine {
    public static func binary(
        named name: String,
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [URL] = []

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/\(name)"))
            candidates.append(resources.appendingPathComponent("Resources/bin/\(name)"))
        }

        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent(name))
            candidates.append(directory.appendingPathComponent("../Resources/bin/\(name)"))
            candidates.append(directory.appendingPathComponent("../Resources/\(name)"))
        }

        if let bundled = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "bin"
        ) {
            candidates.append(bundled)
        }

        for path in [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ] {
            candidates.append(URL(fileURLWithPath: path))
        }

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: candidate.path
            )
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
