import CryptoKit
import Foundation

public enum CorpusYaraError: LocalizedError {
    case export(String)
    case engineMissing
    case scan(String)

    public var errorDescription: String? {
        switch self {
        case .export(let message): return "could not export corpus YARA rules: \(message)"
        case .engineMissing: return "bundled YARA engine not found"
        case .scan(let message): return "corpus YARA scan failed: \(message)"
        }
    }
}

public struct CorpusYaraRuleRef: Sendable {
    public let ruleID: String
    public let malwareID: Int

    public init(ruleID: String, malwareID: Int) {
        self.ruleID = ruleID
        self.malwareID = malwareID
    }
}

public struct CorpusYaraBundle: Sendable {
    public let rulesURL: URL
    public let references: [String: CorpusYaraRuleRef]

    public init(rulesURL: URL, references: [String: CorpusYaraRuleRef]) {
        self.rulesURL = rulesURL
        self.references = references
    }
}

public struct CorpusYaraRunResult: Sendable {
    public let findings: [ProtectionFinding]
    public let scannedFiles: Int
    public let summary: YaraSummary

    public init(findings: [ProtectionFinding], scannedFiles: Int, summary: YaraSummary) {
        self.findings = findings
        self.scannedFiles = scannedFiles
        self.summary = summary
    }
}

public enum CorpusYara {
    private static let rulePattern = try! NSRegularExpression(
        pattern: "(?m)^\\s*(?:private\\s+|global\\s+)?rule\\s+([A-Za-z_][A-Za-z0-9_]*)"
    )

    public static func export(
        corpus: PantherCorpus,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CorpusYaraBundle {
        guard !corpus.yaraRules.isEmpty else {
            throw CorpusYaraError.export("corpus has no YARA rules")
        }

        let directory = try ensureDirectory(cacheDirectory, fileManager: fileManager)
        var usedNames = Set<String>()
        for dependency in corpus.yaraDependencies {
            usedNames.formUnion(ruleNames(in: dependency))
        }

        var references: [String: CorpusYaraRuleRef] = [:]
        var exported: [String] = []

        for rule in corpus.yaraRules {
            guard let parsed = firstRule(in: rule.text) else { continue }
            var name = parsed.name
            if usedNames.contains(name) {
                var suffix = 2
                while usedNames.contains("\(name)__\(suffix)") {
                    suffix += 1
                }
                name = "\(name)__\(suffix)"
            }
            usedNames.insert(name)

            let rewritten = rule.text.replacingCharacters(in: parsed.range, with: name)
            exported.append(rewritten)
            references[name] = CorpusYaraRuleRef(ruleID: rule.ruleID, malwareID: rule.malwareID)
        }

        guard !exported.isEmpty else {
            throw CorpusYaraError.export("no valid rule declarations")
        }

        let dependencies = corpus.yaraDependencies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let combined = (dependencies + exported).joined(separator: "\n\n") + "\n"
        let digest = SHA256.hash(data: Data(combined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let rulesURL = directory.appendingPathComponent("\(digest).yar")

        if !fileManager.fileExists(atPath: rulesURL.path) {
            do {
                try Data(combined.utf8).write(to: rulesURL, options: [.atomic])
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: rulesURL.path
                )
            } catch {
                throw CorpusYaraError.export(error.localizedDescription)
            }
        }

        return CorpusYaraBundle(rulesURL: rulesURL, references: references)
    }

    public static func scan(
        corpus: PantherCorpus,
        bundle: CorpusYaraBundle,
        files: [URL],
        maxFileSize: Int64,
        fileManager: FileManager = .default
    ) -> CorpusYaraRunResult {
        guard let helper = YaraEngine.binary(named: "maclean-yara", fileManager: fileManager) else {
            return CorpusYaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: bundle.rulesURL.path,
                    enginePath: nil,
                    matches: 0,
                    note: CorpusYaraError.engineMissing.localizedDescription
                )
            )
        }

        guard !files.isEmpty else {
            return CorpusYaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: bundle.rulesURL.path,
                    enginePath: helper,
                    matches: 0,
                    note: "No files to scan."
                )
            )
        }

        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maclean-yara-\(UUID().uuidString).list")
        var list = Data()
        for file in files {
            list.append(contentsOf: file.path.utf8)
            list.append(0)
        }
        do {
            try list.write(to: listURL, options: [.atomic])
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: listURL.path
            )
        } catch {
            return CorpusYaraRunResult(
                findings: [],
                scannedFiles: 0,
                summary: YaraSummary(
                    rulesPath: bundle.rulesURL.path,
                    enginePath: helper,
                    matches: 0,
                    note: CorpusYaraError.scan(error.localizedDescription).localizedDescription
                )
            )
        }
        defer { try? FileManager.default.removeItem(at: listURL) }

        let result = ProcessRunner.run(
            helper,
            [bundle.rulesURL.path, listURL.path, String(maxFileSize)],
            timeout: 900
        )

        if result.status != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return CorpusYaraRunResult(
                findings: [],
                scannedFiles: files.count,
                summary: YaraSummary(
                    rulesPath: bundle.rulesURL.path,
                    enginePath: helper,
                    matches: 0,
                    note: message.isEmpty ? "YARA helper exited \(result.status)" : String(message.prefix(500))
                )
            )
        }

        var findings: [ProtectionFinding] = []
        var seen = Set<String>()

        for record in result.stdout.split(separator: "\0") {
            let line = String(record)
            guard let separator = line.firstIndex(of: "\t") else { continue }
            let ruleName = String(line[..<separator])
            let path = String(line[line.index(after: separator)...])
            guard let reference = bundle.references[ruleName],
                  !path.isEmpty else { continue }
            guard seen.insert("\(path)|\(reference.ruleID)|\(reference.malwareID)").inserted else {
                continue
            }

            let malware = corpus.malware[reference.malwareID]
            let title = malware.map { "\($0.name) (\($0.type))" }
                ?? "Unknown malware (rule \(reference.ruleID))"
            var detail = "YARA \(ruleName) · rule \(reference.ruleID)"
            if let link = malware?.infoLink, !link.isEmpty {
                detail += " · \(link)"
            }

            findings.append(
                ProtectionFinding(
                    path: path,
                    kind: "malware-yara",
                    title: title,
                    detail: detail,
                    severity: .high,
                    requiresRoot: false
                )
            )
            if findings.count >= 5_000 { break }
        }

        return CorpusYaraRunResult(
            findings: findings,
            scannedFiles: files.count,
            summary: YaraSummary(
                rulesPath: bundle.rulesURL.path,
                enginePath: helper,
                matches: findings.count,
                note: nil
            )
        )
    }

    private static func ensureDirectory(_ override: URL?, fileManager: FileManager) throws -> URL {
        let base = override
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let directory = base.appendingPathComponent("maclean/yara", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw CorpusYaraError.export(error.localizedDescription)
        }
        return directory
    }

    private static func ruleNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return rulePattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
    }

    private static func firstRule(in text: String) -> (name: String, range: Range<String.Index>)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = rulePattern.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return (String(text[nameRange]), nameRange)
    }
}
