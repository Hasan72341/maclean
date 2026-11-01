import Foundation

public struct ClamAVSummary: Codable, Sendable {
    public let enginePath: String?
    public let databasePath: String?
    public let matches: Int
    public let note: String?

    public init(enginePath: String?, databasePath: String?, matches: Int, note: String?) {
        self.enginePath = enginePath
        self.databasePath = databasePath
        self.matches = matches
        self.note = note
    }
}

public struct ClamAVRunResult: Sendable {
    public let findings: [ProtectionFinding]
    public let summary: ClamAVSummary

    public init(findings: [ProtectionFinding], summary: ClamAVSummary) {
        self.findings = findings
        self.summary = summary
    }
}

public enum ClamAVScanner {
    static let engineCandidates = [
        "/opt/homebrew/bin/clamscan",
        "/usr/local/bin/clamscan",
        "/usr/bin/clamscan",
    ]

    public static func run(
        paths: [URL],
        database: URL? = nil,
        maxFileSize: Int64 = 50 * 1024 * 1024,
        fileManager: FileManager = .default
    ) -> ClamAVRunResult {
        guard !paths.isEmpty else {
            return ClamAVRunResult(
                findings: [],
                summary: ClamAVSummary(
                    enginePath: nil,
                    databasePath: database?.path,
                    matches: 0,
                    note: "No scan paths provided; pass --path with --clamav."
                )
            )
        }

        guard let engine = engineCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        }) else {
            return ClamAVRunResult(
                findings: [],
                summary: ClamAVSummary(
                    enginePath: nil,
                    databasePath: database?.path,
                    matches: 0,
                    note: "clamscan not found. Install ClamAV with `brew install clamav` and run `freshclam`."
                )
            )
        }

        if let database, !fileManager.fileExists(atPath: database.path) {
            return ClamAVRunResult(
                findings: [],
                summary: ClamAVSummary(
                    enginePath: engine,
                    databasePath: database.path,
                    matches: 0,
                    note: "ClamAV database path does not exist."
                )
            )
        }

        var arguments = [
            "-r",
            "--infected",
            "--no-summary",
            "--max-filesize=\(maxFileSize)",
        ]
        if let database {
            arguments.append(contentsOf: ["-d", database.path])
        }
        arguments.append(contentsOf: paths.map(\.path))

        let result = ProcessRunner.run(engine, arguments, timeout: 600)
        let findings = parse(output: result.stdout, engine: engine)

        var note: String?
        if result.status == 2 {
            let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            note = error.isEmpty ? "clamscan failed (exit 2)." : String(error.prefix(500))
        } else if result.status == 1, findings.isEmpty {
            note = "clamscan reported an infection but the output could not be parsed."
        }

        return ClamAVRunResult(
            findings: findings,
            summary: ClamAVSummary(
                enginePath: engine,
                databasePath: database?.path,
                matches: findings.count,
                note: note
            )
        )
    }

    static func parse(output: String, engine: String) -> [ProtectionFinding] {
        var findings: [ProtectionFinding] = []
        var seen = Set<String>()

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix("FOUND") else { continue }
            guard let separator = line.range(of: ": ", options: .backwards) else { continue }

            let path = String(line[..<separator.lowerBound])
            var signature = String(line[separator.upperBound...])
            if signature.hasSuffix(" FOUND") {
                signature.removeLast(6)
            }
            guard !path.isEmpty, !signature.isEmpty else { continue }
            guard seen.insert(path + "\u{0}" + signature).inserted else { continue }

            findings.append(
                ProtectionFinding(
                    path: path,
                    kind: "clamav",
                    title: "ClamAV detection: \(signature)",
                    detail: "engine: \(engine)",
                    severity: .high,
                    requiresRoot: false
                )
            )
            if findings.count >= 1000 { break }
        }
        return findings
    }
}
