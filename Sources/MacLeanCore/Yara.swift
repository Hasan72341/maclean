import Foundation

public struct YaraSummary: Codable, Sendable {
    public let rulesPath: String?
    public let enginePath: String?
    public let matches: Int
    public let note: String?

    public init(rulesPath: String?, enginePath: String?, matches: Int, note: String?) {
        self.rulesPath = rulesPath
        self.enginePath = enginePath
        self.matches = matches
        self.note = note
    }
}

public struct YaraRunResult: Sendable {
    public let findings: [ProtectionFinding]
    public let scannedFiles: Int
    public let summary: YaraSummary

    public init(findings: [ProtectionFinding], scannedFiles: Int, summary: YaraSummary) {
        self.findings = findings
        self.scannedFiles = scannedFiles
        self.summary = summary
    }
}

public enum YaraScanner {
    public static func ruleFiles(at url: URL, fileManager: FileManager = .default) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            let ext = url.pathExtension.lowercased()
            return ["yar", "yara", "yarac", "yarc"].contains(ext) ? [url] : []
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [URL] = []
        for case let candidate as URL in enumerator {
            guard files.count < 1000 else { break }
            let ext = candidate.pathExtension.lowercased()
            guard ext == "yar" || ext == "yara" else { continue }
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            files.append(candidate)
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func run(
        rules: URL,
        paths: [URL],
        maxFileSize: Int64,
        fileManager: FileManager = .default
    ) -> YaraRunResult {
        guard fileManager.fileExists(atPath: rules.path) else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: nil,
                    matches: 0,
                    note: "YARA rules file not found."
                )
            )
        }

        guard let engine = YaraEngine.binary(named: "yara", fileManager: fileManager) else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: nil,
                    matches: 0,
                    note: "yara binary not found."
                )
            )
        }

        guard !paths.isEmpty else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: engine,
                    matches: 0,
                    note: "No scan paths provided; pass --path with --yara-rules."
                )
            )
        }

        let ruleFiles = ruleFiles(at: rules, fileManager: fileManager)
        guard !ruleFiles.isEmpty else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: engine,
                    matches: 0,
                    note: "No .yar/.yara rule files found."
                )
            )
        }

        var activeRuleFiles = ruleFiles
        var ruleArguments = activeRuleFiles.map(\.path)
        let externalArguments = [
            "-d", "file_path=",
            "-d", "file_name=",
            "-d", "file_extension=",
            "-d", "filename=",
            "-d", "filepath=",
            "-d", "filetype=",
            "-d", "extension=",
            "-d", "owner=",
        ]
        var compiledRules: URL?
        var compileNote: String?
        var skippedCount = 0

        if !activeRuleFiles.isEmpty,
           let compiler = YaraEngine.binary(named: "yarac", fileManager: fileManager) {
            for _ in 0..<3 {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("maclean-yara-\(UUID().uuidString).yarc")
                let compile = ProcessRunner.run(
                    compiler,
                    externalArguments + activeRuleFiles.map(\.path) + [output.path],
                    timeout: 180
                )
                if compile.status == 0 {
                    try? fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: output.path
                    )
                    compiledRules = output
                    ruleArguments = [output.path]
                    break
                }

                let failed = failedRuleFiles(
                    in: compile.stderr,
                    candidates: activeRuleFiles
                )
                guard !failed.isEmpty else {
                    let message = compile.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    compileNote = "yarac could not compile the rule set; scanning uncompiled files."
                    if !message.isEmpty {
                        compileNote = (compileNote ?? "") + " \(message.prefix(300))"
                    }
                    break
                }
                let skipped = activeRuleFiles.filter { failed.contains($0.path) }
                skippedCount += skipped.count
                compileNote = "Skipped \(skippedCount) open-source rule file(s) with unsupported features."
                activeRuleFiles.removeAll { failed.contains($0.path) }
                ruleArguments = activeRuleFiles.map(\.path)
                if activeRuleFiles.isEmpty { break }
            }
        }
        defer {
            if let compiledRules {
                try? fileManager.removeItem(at: compiledRules)
            }
        }

        guard !ruleArguments.isEmpty else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: engine,
                    matches: 0,
                    note: compileNote ?? "No compatible rules remained after compilation."
                )
            )
        }

        var candidates: [URL] = []
        for root in paths {
            candidates.append(contentsOf: files(
                under: root,
                maxFileSize: maxFileSize,
                limit: max(0, 20_000 - candidates.count),
                fileManager: fileManager
            ))
            if candidates.count >= 20_000 { break }
        }

        guard !candidates.isEmpty else {
            return YaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: rules.path,
                    enginePath: engine,
                    matches: 0,
                    note: "No files under the size cap were found."
                )
            )
        }

        if let helper = YaraEngine.binary(named: "maclean-yara", fileManager: fileManager),
           usesPerFileAliases(activeRuleFiles, fileManager: fileManager),
           let helperResult = scanWithPerFileAliases(
               helper: helper,
               rules: activeRuleFiles,
               candidates: candidates,
               maxFileSize: maxFileSize,
               note: compileNote,
               fileManager: fileManager
           ) {
            return helperResult
        }

        var findings: [ProtectionFinding] = []
        var seen = Set<String>()

        for start in stride(from: 0, to: candidates.count, by: 200) {
            let chunk = Array(candidates[start..<min(start + 200, candidates.count)])
            var arguments = ["-w", "-m"]
            arguments.append(contentsOf: externalArguments)
            if compiledRules != nil {
                arguments.append("-C")
            }
            arguments.append(contentsOf: ruleArguments)
            arguments.append(contentsOf: chunk.map(\.path))
            let result = ProcessRunner.run(
                engine,
                arguments,
                timeout: 300
            )
            guard result.status == 0 else { continue }

            for rawLine in result.stdout.split(separator: "\n") {
                guard let match = parseMatchLine(String(rawLine)) else { continue }
                guard seen.insert(match.rule + "\u{0}" + match.path).inserted else { continue }

                let detail = match.metadata.isEmpty
                    ? "rules: \(rules.path)"
                    : "\(match.metadata) — rules: \(rules.path)"

                findings.append(
                    ProtectionFinding(
                        path: match.path,
                        kind: "yara",
                        title: "YARA rule matched: \(match.rule)",
                        detail: detail,
                        severity: .high,
                        requiresRoot: false
                    )
                )
                if findings.count >= 500 { break }
            }
            if findings.count >= 500 { break }
        }

        return YaraRunResult(
            findings: findings,
            scannedFiles: candidates.count,
            summary: YaraSummary(
                rulesPath: rules.path,
                enginePath: engine,
                matches: findings.count,
                note: compileNote
            )
        )
    }

    static func failedRuleFiles(in stderr: String, candidates: [URL]) -> Set<String> {
        var failed = Set<String>()
        for line in stderr.split(separator: "\n") {
            for candidate in candidates where line.contains(candidate.path)
                || line.contains(candidate.lastPathComponent) {
                failed.insert(candidate.path)
            }
        }
        return failed
    }

    private static func usesPerFileAliases(
        _ files: [URL],
        fileManager: FileManager
    ) -> Bool {
        let aliases = ["filename", "filepath", "filetype", "extension"]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if aliases.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }

    private static func scanWithPerFileAliases(
        helper: String,
        rules: [URL],
        candidates: [URL],
        maxFileSize: Int64,
        note: String?,
        fileManager: FileManager
    ) -> YaraRunResult? {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("maclean-yara-alias-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fileManager.removeItem(at: directory) }

        let combined = directory.appendingPathComponent("combined.yar")
        var text = ""
        for file in rules {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text += contents
            text += "\n"
        }
        guard !text.isEmpty else { return nil }
        do {
            try text.write(to: combined, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let list = directory.appendingPathComponent("files.list")
        var listData = Data()
        for file in candidates {
            listData.append(contentsOf: file.path.utf8)
            listData.append(0)
        }
        do {
            try listData.write(to: list)
        } catch {
            return nil
        }

        let result = ProcessRunner.run(
            helper,
            [combined.path, list.path, String(maxFileSize)],
            timeout: 300
        )
        guard result.status == 0 else { return nil }

        var findings: [ProtectionFinding] = []
        var seen = Set<String>()
        for record in result.stdout.split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let rule = String(parts[0])
            let path = String(parts[1])
            guard seen.insert(rule + "\u{0}" + path).inserted else { continue }
            findings.append(
                ProtectionFinding(
                    path: path,
                    kind: "yara",
                    title: "YARA rule matched: \(rule)",
                    detail: "rules: \(rules.first?.deletingLastPathComponent().path ?? "")",
                    severity: .high,
                    requiresRoot: false
                )
            )
            if findings.count >= 500 { break }
        }

        return YaraRunResult(
            findings: findings,
            scannedFiles: candidates.count,
            summary: YaraSummary(
                rulesPath: rules.first?.deletingLastPathComponent().path,
                enginePath: helper,
                matches: findings.count,
                note: note ?? "Scanned with per-file filename/filepath/filetype/extension aliases."
            )
        )
    }

    static func parseMatchLine(_ rawLine: String) -> (rule: String, metadata: String, path: String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let separator = line.firstIndex(where: { $0 == "\t" || $0 == " " }) else {
            return nil
        }

        let rule = String(line[..<separator])
        var rest = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        var metadata = ""

        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            metadata = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard !rule.isEmpty, !rest.isEmpty else { return nil }
        return (rule, metadata, rest)
    }

    private static func files(
        under root: URL,
        maxFileSize: Int64,
        limit: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true || values.isRegularFile != true { continue }
            let size = Int64(values.fileSize ?? 0)
            if size > maxFileSize { continue }
            results.append(url)
        }
        return results
    }
}
