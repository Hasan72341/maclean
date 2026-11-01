import Foundation
import MacLeanCore

struct ArtifactCommandPayload: Encodable {
    let title: String
    let apply: Bool
    let totalBytes: Int64
    let artifacts: [Artifact]
    let planned: [String]
    let movedToTrash: [String]
    let deleted: [String]
    let skipped: [FailurePayload]
    let failed: [FailurePayload]
    let reclaimedBytes: Int64
    let trashedBytes: Int64
}

struct UninstallPayload: Encodable {
    let app: AppInfo
    let result: ArtifactCommandPayload
}

struct PerformancePayload: Encodable {
    let startupItems: [StartupItem]
    let localSnapshots: [String]
    let memory: MemoryStats?
}

struct DuplicatesPayload: Encodable {
    let similarImages: Bool
    let duplicateGroups: [DuplicateGroup]
    let similarImageGroups: [SimilarImageGroup]
    let wastedBytes: Int64
}

struct CloudPayload: Encodable {
    let locations: [CloudLocation]
    let largeFiles: [CloudFile]
}

struct UpdatesPayload: Encodable {
    let updates: [String]
}

struct ArtifactRun {
    let apply: Bool
    let includeCaution: Bool
    let result: ArtifactCleanResult
}

func runArtifacts(_ artifacts: [Artifact], args: ParsedArgs, home: URL) throws -> ArtifactRun {
    let apply = args.flags.contains("--apply")
    let confirmed = args.flags.contains("--yes")
    let permanent = args.flags.contains("--permanent")
    let includeCaution = args.flags.contains("--include-caution")

    if apply, !confirmed {
        throw CLIError("--apply requires --yes. Run without --apply for a dry run.", code: 2)
    }

    let result = ArtifactCleaner(home: home).clean(
        artifacts,
        apply: apply,
        permanent: permanent,
        includeCaution: includeCaution
    )
    return ArtifactRun(
        apply: apply,
        includeCaution: includeCaution,
        result: result
    )
}

func artifactPayload(
    title: String,
    artifacts: [Artifact],
    run: ArtifactRun
) -> ArtifactCommandPayload {
    ArtifactCommandPayload(
        title: title,
        apply: run.apply,
        totalBytes: artifacts.reduce(0) { $0 + $1.bytes },
        artifacts: artifacts,
        planned: run.result.planned.map(\.path),
        movedToTrash: run.result.movedToTrash.map(\.path),
        deleted: run.result.deleted.map(\.path),
        skipped: run.result.skipped.map { FailurePayload(path: $0.path, reason: $0.reason) },
        failed: run.result.failed.map { FailurePayload(path: $0.path, reason: $0.reason) },
        reclaimedBytes: run.result.reclaimedBytes,
        trashedBytes: run.result.trashedBytes
    )
}

func printArtifacts(
    _ artifacts: [Artifact],
    title: String,
    home: URL,
    includeCaution: Bool,
    limit: Int = 50
) {
    guard !artifacts.isEmpty else {
        print("\(title): nothing found.")
        return
    }

    let sorted = artifacts.sorted { $0.bytes > $1.bytes }
    let total = sorted.reduce(0) { $0 + $1.bytes }
    let selected = sorted.filter { $0.autoselect || includeCaution }
    let selectedBytes = selected.reduce(0) { $0 + $1.bytes }

    print("\(color("1;36", title)) \(color("2", "— \(humanBytes(total)), \(sorted.count) items"))")

    for artifact in sorted.prefix(limit) {
        let marker = artifact.autoselect ? color("32", "●") : color("33", "○")
        let detail = artifact.detail.isEmpty ? artifact.group : "\(artifact.group) · \(artifact.detail)"
        print("  \(marker) \(padded(humanBytes(artifact.bytes), to: 10))  \(abbreviated(artifact.path, home: home))")
        print("      \(color("2", detail))")
    }
    if sorted.count > limit {
        print("  \(color("2", "… and \(sorted.count - limit) more (use --json for the full list)"))")
    }

    print("")
    print("\(color("1", "Selected:")) \(humanBytes(selectedBytes)) across \(selected.count) items")
    if selected.count < sorted.count, !includeCaution {
        print(color("2", "\(sorted.count - selected.count) items need --include-caution."))
    }
}

func printArtifactRun(
    title: String,
    artifacts: [Artifact],
    run: ArtifactRun,
    home: URL
) {
    if run.apply {
        let targets = run.result.movedToTrash + run.result.deleted
        if targets.isEmpty {
            print("Nothing selected.")
            if !run.includeCaution, artifacts.contains(where: { !$0.autoselect }) {
                print(color("2", "Pass --include-caution to include review items."))
            }
            for failure in run.result.skipped.prefix(10) {
                print("  \(color("33", abbreviated(failure.path, home: home))) — \(failure.reason)")
            }
            return
        }
        print("\(color("1", "Cleaned \(targets.count) items"))")
        if run.result.reclaimedBytes > 0 {
            print("  Reclaimed: \(humanBytes(run.result.reclaimedBytes))")
        }
        if !run.result.movedToTrash.isEmpty {
            print("  Moved to Trash: \(humanBytes(run.result.trashedBytes))")
            print(color("2", "  Empty the Trash to reclaim that space."))
        }
        if !run.result.skipped.isEmpty {
            print("  Skipped: \(run.result.skipped.count)")
            for failure in run.result.skipped.prefix(10) {
                print("    \(color("33", abbreviated(failure.path, home: home))) — \(failure.reason)")
            }
        }
        if !run.result.failed.isEmpty {
            print("  Failed: \(run.result.failed.count)")
            for failure in run.result.failed.prefix(10) {
                print("    \(color("31", abbreviated(failure.path, home: home))) — \(failure.reason)")
            }
        }
    } else {
        printArtifacts(artifacts, title: title, home: home, includeCaution: run.includeCaution)
        print("")
        print("\(color("1", "Dry run:")) \(run.result.planned.count) items, \(humanBytes(run.result.planned.reduce(0) { $0 + $1.bytes })). Nothing was changed.")
        print(color("2", "Re-run with --apply --yes to move them to the Trash (or add --permanent to delete)."))
    }
}

func uninstallCommand(_ args: ParsedArgs) throws -> Int32 {
    guard let query = args.positionals.first else {
        throw CLIError("usage: maclean uninstall <app name, bundle id, or .app path>", code: 2)
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let apps = Uninstaller.apps(home: home)
    let matches = Uninstaller.find(query, in: apps)

    guard !matches.isEmpty else {
        throw CLIError("no application matching '\(query)'", code: 2)
    }
    if matches.count > 1 {
        print("Multiple applications match '\(query)':")
        for app in matches.prefix(20) {
            print("  \(app.name)  \(app.bundleID ?? "unknown")  \(app.path)")
        }
        throw CLIError("use a more specific name or the full .app path", code: 2)
    }

    let app = matches[0]
    if args.flags.contains("--apply"), !args.flags.contains("--force") {
        let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        if processes.stdout.lowercased().contains(app.path.lowercased()) {
            throw CLIError(
                "\(app.name) is running. Quit it before uninstalling, or pass --force.",
                code: 2
            )
        }
    }
    let artifacts = Uninstaller.plan(for: app, home: home)
    let run = try runArtifacts(artifacts, args: args, home: home)

    if args.flags.contains("--json") {
        try printJSON(UninstallPayload(
            app: app,
            result: artifactPayload(title: "Uninstall \(app.name)", artifacts: artifacts, run: run)
        ))
    } else {
        print("\(color("1;36", "Uninstall \(app.name)")) \(color("2", "— \(app.bundleID ?? app.path)"))")
        printArtifactRun(title: "Uninstall \(app.name)", artifacts: artifacts, run: run, home: home)
    }

    return run.result.failed.isEmpty ? 0 : 1
}

func privacyCommand(_ args: ParsedArgs) throws -> Int32 {
    let apply = args.flags.contains("--apply")
    if apply, !args.flags.contains("--force") {
        let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        let running = ["google chrome", "safari", "firefox", "microsoft edge", "brave browser", "/arc.app/"]
            .filter { processes.stdout.lowercased().contains($0) }
        if !running.isEmpty {
            throw CLIError(
                "Quit \(running.joined(separator: ", ")) before cleaning privacy data, or pass --force.",
                code: 2
            )
        }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let artifacts = PrivacyScanner.scan(home: home)
    let run = try runArtifacts(artifacts, args: args, home: home)

    if args.flags.contains("--json") {
        try printJSON(artifactPayload(title: "Privacy", artifacts: artifacts, run: run))
    } else {
        printArtifactRun(title: "Privacy", artifacts: artifacts, run: run, home: home)
    }
    return run.result.failed.isEmpty ? 0 : 1
}

func mailCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if args.flags.contains("--trash") {
        let report = MailTrashScanner.scan(
            home: home,
            includeJunk: args.flags.contains("--include-junk")
        )
        let apply = args.flags.contains("--apply")
        if apply, !args.flags.contains("--yes") {
            throw CLIError("--apply requires --yes", code: 2)
        }
        if apply, !args.flags.contains("--force") {
            let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
            if processes.stdout.lowercased().contains("/mail.app/") {
                throw CLIError("Quit Mail before cleaning Mail Trash, or pass --force.", code: 2)
            }
        }
        let permanent = args.flags.contains("--permanent")
        if !apply {
            if args.flags.contains("--json") {
                try printJSON(report)
            } else {
                printMailTrash(report, home: home)
            }
            return 0
        }
        let result = DeepCleaner.cleanMailTrash(
            report: report,
            apply: apply,
            permanent: permanent,
            home: home
        )
        if args.flags.contains("--json") {
            try printJSON(result)
        } else {
            printDeepCleanResult(
                title: permanent ? "Deleted Mail Trash" : "Moved Mail Trash to Trash",
                result: result
            )
            if apply {
                print("Mail may rebuild its index when it next opens.")
            }
        }
        return result.failed.isEmpty ? 0 : 1
    }

    if args.flags.contains("--apply"), !args.flags.contains("--force") {
        let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        if processes.stdout.lowercased().contains("/mail.app/") {
            throw CLIError("Quit Mail before cleaning attachments, or pass --force.", code: 2)
        }
    }
    let artifacts = MailScanner.scan(home: home)
    let run = try runArtifacts(artifacts, args: args, home: home)

    if args.flags.contains("--json") {
        try printJSON(artifactPayload(title: "Mail attachments", artifacts: artifacts, run: run))
    } else {
        printArtifactRun(title: "Mail attachments", artifacts: artifacts, run: run, home: home)
    }
    return run.result.failed.isEmpty ? 0 : 1
}

func diskImagesCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let minBytes = args.values["--min-size"] == nil
        ? 100 * 1024 * 1024
        : try parseMinBytes(args)
    let olderThan = Int(args.values["--older-than"]?.last ?? "30") ?? 30
    let artifacts = DiskImageScanner.scan(
        home: home,
        olderThanDays: max(0, olderThan),
        minBytes: minBytes
    )
    let run = try runArtifacts(artifacts, args: args, home: home)

    if args.flags.contains("--json") {
        try printJSON(artifactPayload(title: "Unused disk images", artifacts: artifacts, run: run))
    } else {
        printArtifactRun(title: "Unused disk images", artifacts: artifacts, run: run, home: home)
    }
    return run.result.failed.isEmpty ? 0 : 1
}

func performanceCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser

    if let path = args.values["--remove"]?.first {
        guard args.flags.contains("--yes") else {
            throw CLIError("--remove requires --yes", code: 2)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let artifact = ArtifactBuilder.make(
            path: url.path,
            allowedRoot: url.deletingLastPathComponent().path,
            group: "Startup item",
            detail: url.lastPathComponent,
            risk: .caution,
            autoselect: true
        ) else {
            throw CLIError("not found: \(url.path)", code: 2)
        }

        let result = ArtifactCleaner(home: home).clean(
            [artifact],
            apply: true,
            permanent: args.flags.contains("--permanent"),
            includeCaution: true
        )
        if args.flags.contains("--json") {
            try printJSON(artifactPayload(title: "Remove startup item", artifacts: [artifact], run: ArtifactRun(
                apply: true, includeCaution: true, result: result
            )))
        } else if !result.failed.isEmpty {
            for failure in result.failed {
                print("\(color("31", "failed:")) \(failure.path) — \(failure.reason)")
            }
        } else {
            print("Removed \(url.lastPathComponent).")
        }
        return result.failed.isEmpty ? 0 : 1
    }

    if args.flags.contains("--flush-dns") {
        guard args.flags.contains("--yes") else {
            throw CLIError("--flush-dns requires --yes", code: 2)
        }
        let output = PerformanceScanner.flushDNS()
        if args.flags.contains("--json") {
            try printJSON(["output": output])
        } else {
            print(output)
        }
        return 0
    }

    let items = PerformanceScanner.startupItems(home: home)
    let snapshots = PerformanceScanner.localSnapshots()
    let memory = PerformanceScanner.memory()

    if args.flags.contains("--json") {
        try printJSON(PerformancePayload(
            startupItems: items,
            localSnapshots: snapshots,
            memory: memory
        ))
        return 0
    }

    print("\(color("1;36", "Startup items")) \(color("2", "— \(items.count)"))")
    for item in items {
        let marker = item.broken ? color("33", "!") : color("32", "●")
        let broken = item.broken ? color("33", "  broken") : ""
        let root = item.requiresRoot ? color("2", "  (root)") : ""
        print("  \(marker) \(item.label)\(broken)\(root)")
        print("      \(color("2", "\(item.kind) · \(item.scope) · \(item.program.isEmpty ? item.path : item.program)"))")
    }

    print("")
    print("\(color("1;36", "Local snapshots")) \(color("2", "— \(snapshots.count)"))")
    if snapshots.isEmpty {
        print("  \(color("2", "none"))")
    } else {
        for snapshot in snapshots.prefix(30) {
            print("  \(snapshot)")
        }
    }

    if let memory {
        print("")
        print("\(color("1;36", "Memory"))")
        print("  Total: \(humanBytes(Int64(memory.totalBytes)))")
        print("  Available: \(humanBytes(Int64(memory.freeBytes)))")
        print("  Wired: \(humanBytes(Int64(memory.wiredBytes)))")
        print("  Compressed: \(humanBytes(Int64(memory.compressedBytes)))")
    }

    return 0
}

func duplicatesCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let similar = args.flags.contains("--similar-images")
    let minBytes = args.values["--min-size"] == nil
        ? 1024 * 1024
        : try parseMinBytes(args)

    let directories = (args.values["--path"] ?? []).map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let roots = directories.isEmpty
        ? [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Movies"),
        ]
        : directories

    if similar {
        let groups = SimilarImageScanner.scan(
            directories: roots,
            minBytes: max(minBytes, 16 * 1024)
        )

        if args.flags.contains("--json") {
            try printJSON(DuplicatesPayload(
                similarImages: true,
                duplicateGroups: [],
                similarImageGroups: groups,
                wastedBytes: groups.reduce(0) { $0 + $1.bytes }
            ))
            return 0
        }

        guard !groups.isEmpty else {
            print("No similar image groups found.")
            return 0
        }

        print("\(color("1;36", "Similar images")) \(color("2", "— \(groups.count) groups"))")
        for group in groups.prefix(50) {
            print("  \(padded(humanBytes(group.bytes), to: 10))  \(group.paths.count) images")
            for path in group.paths.prefix(6) {
                print("      \(abbreviated(path, home: home))")
            }
            if group.paths.count > 6 { print("      \(color("2", "…"))") }
        }

        let artifacts = artifactsForRemovingCopies(
            pathGroups: groups.map(\.paths),
            roots: roots,
            group: "Similar image",
            autoselect: false
        )
        let run = try runArtifacts(artifacts, args: args, home: home)
        print("")
        if run.apply {
            let targets = run.result.movedToTrash + run.result.deleted
            if targets.isEmpty {
                print("Nothing selected. Pass --include-caution --apply --yes to remove similar images.")
            } else {
                print("\(color("1", "Cleaned \(targets.count) similar images"))")
                print("  Reclaimed: \(humanBytes(run.result.reclaimedBytes + run.result.trashedBytes))")
            }
        } else {
            print("\(color("1", "Dry run:")) \(run.result.planned.count) files, \(humanBytes(run.result.planned.reduce(0) { $0 + $1.bytes })). Nothing was changed.")
            print(color("2", "Similar-image deletion needs --include-caution --apply --yes. Review the groups above first."))
        }
        return run.result.failed.isEmpty ? 0 : 1
    }

    let groups = DuplicateScanner.scan(directories: roots, minBytes: minBytes)

    if args.flags.contains("--json") {
        try printJSON(DuplicatesPayload(
            similarImages: false,
            duplicateGroups: groups,
            similarImageGroups: [],
            wastedBytes: groups.reduce(0) { $0 + $1.wastedBytes }
        ))
        return 0
    }

    guard !groups.isEmpty else {
        print("No duplicates found.")
        return 0
    }

    print("\(color("1;36", "Duplicates")) \(color("2", "— \(groups.count) groups, \(humanBytes(groups.reduce(0) { $0 + $1.wastedBytes })) reclaimable"))")
    for group in groups.prefix(50) {
        print("  \(padded(humanBytes(group.size), to: 10))  \(group.paths.count) copies  \(color("2", String(group.hash.prefix(12))))")
        for path in group.paths.prefix(6) {
            print("      \(abbreviated(path, home: home))")
        }
    }

    let artifacts = artifactsForRemovingCopies(
        pathGroups: groups.map(\.paths),
        roots: roots,
        group: "Duplicate",
        autoselect: true
    )
    let run = try runArtifacts(artifacts, args: args, home: home)
    print("")
    if run.apply {
        print("\(color("1", "Cleaned \(run.result.movedToTrash.count + run.result.deleted.count) duplicate files"))")
        print("  Reclaimed: \(humanBytes(run.result.reclaimedBytes + run.result.trashedBytes))")
    } else {
        print("\(color("1", "Dry run:")) \(run.result.planned.count) duplicate files, \(humanBytes(run.result.planned.reduce(0) { $0 + $1.bytes })). Nothing was changed.")
        print(color("2", "Re-run with --apply --yes to move all but the first copy of each group to the Trash."))
    }
    return run.result.failed.isEmpty ? 0 : 1
}

func artifactsForRemovingCopies(
    pathGroups: [[String]],
    roots: [URL],
    group: String,
    autoselect: Bool
) -> [Artifact] {
    let standardRoots = roots.map { $0.standardizedFileURL.path }
    var artifacts: [Artifact] = []

    for paths in pathGroups where paths.count > 1 {
        let keep = paths.first ?? ""
        for path in paths.dropFirst() {
            let root = standardRoots.first { path.hasPrefix($0 + "/") }
                ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard let artifact = ArtifactBuilder.make(
                path: path,
                allowedRoot: root,
                group: group,
                detail: keep.isEmpty ? "" : "keep \(keep)",
                risk: .caution,
                autoselect: autoselect
            ) else { continue }
            artifacts.append(artifact)
        }
    }
    return artifacts
}

func lensCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let root = args.positionals.first.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    } ?? home
    let depth = max(0, min(10, Int(args.values["--depth"]?.last ?? "3") ?? 3))
    let top = max(1, Int(args.values["--top"]?.last ?? "20") ?? 20)

    guard FileManager.default.fileExists(atPath: root.path) else {
        throw CLIError("not found: \(root.path)", code: 2)
    }

    let progress = LensProgress()
    let verbose = args.flags.contains("--verbose")
    let ticker: DispatchSourceTimer? = verbose ? {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            let s = progress.snapshot
            FileHandle.standardError.write("\r\(s.files) files · \(s.folders) folders · \(humanBytes(s.bytes))    ".data(using: .utf8)!)
        }
        timer.resume()
        return timer
    }() : nil
    // Used by the app when it scans as administrator: live counters go to a
    // file it polls, and creating `<file>.cancel` stops the scan.
    let progressFile = args.values["--progress-file"]?.last
    let reporter: DispatchSourceTimer? = progressFile.map { file in
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler {
            if FileManager.default.fileExists(atPath: file + ".cancel") { progress.cancel() }
            let s = progress.snapshot
            try? "\(s.files)\t\(s.folders)\t\(s.bytes)\t\(s.unreadable)\t\(s.current)".write(toFile: file, atomically: true, encoding: .utf8)
        }
        timer.resume()
        return timer
    }
    let result = LensScanner.scan(root: root, progress: progress)
    ticker?.cancel()
    reporter?.cancel()
    if let archive = args.values["--archive"]?.last {
        if result.cancelled { throw CLIError("cancelled", code: 130) }
        let (data, _) = LensArchive.encode(result)
        guard let data else { throw CLIError("could not encode the map", code: 1) }
        try data.write(to: URL(fileURLWithPath: archive), options: .atomic)
        // Readable by the user who asked for the scan.
        if let owner = args.values["--owner"]?.last.flatMap({ uid_t($0) }) {
            chown(archive, owner, 20)
            if let progressFile { chown(progressFile, owner, 20) }
        }
        print("\(result.root.files) files · \(humanBytes(result.root.bytes)) · \(result.root.unreadable) unreadable")
        return 0
    }
    if verbose { FileHandle.standardError.write("\n".data(using: .utf8)!) }
    if args.flags.contains("--save") {
        let t0 = Date()
        if let url = LensArchive.write(result) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let t1 = Date()
            let loaded = LensArchive.read(url)
            let t2 = Date()
            let same = loaded.map { $0.result.root.bytes == result.root.bytes && $0.result.root.files == result.root.files && $0.header.items > 0 } ?? false
            FileHandle.standardError.write("saved map: \(humanBytes(Int64(size))) · \(loaded?.header.items ?? 0) items · write \(String(format: "%.2f", t1.timeIntervalSince(t0))) s · read \(String(format: "%.2f", t2.timeIntervalSince(t1))) s · round-trip \(same ? "identical" : "MISMATCH")\n".data(using: .utf8)!)
        }
    }
    let node = result.root.node(depth: depth)
    if args.flags.contains("--json") {
        try printJSON(node)
        return 0
    }

    let unreadable = result.root.unreadable > 0 ? " · \(result.root.unreadable) unreadable folders" : ""
    let fileSummary = "\(node.files) files · \(result.root.folders) folders · \(String(format: "%.1f", result.duration))s\(unreadable)"
    print("\(color("1;36", humanBytes(node.bytes)))  \(abbreviated(node.path, home: home))  \(color("2", "(" + fileSummary + ")"))")
    renderLens(node, home: home, top: top, maxDepth: depth)
    return 0
}

func renderLens(_ node: LensNode, home: URL, top: Int, maxDepth: Int) {
    func render(_ parent: LensNode, indent: Int, remaining: Int) {
        guard remaining > 0 else { return }
        for child in parent.children.prefix(top) {
            let prefix = String(repeating: "  ", count: indent)
            let suffix = child.isDirectory ? "/" : ""
            print("\(prefix)\(padded(humanBytes(child.bytes), to: 10))  \(child.name)\(suffix)")
            if child.isDirectory, !child.children.isEmpty {
                render(child, indent: indent + 1, remaining: remaining - 1)
            }
        }
    }
    render(node, indent: 1, remaining: maxDepth)
}

func cloudCommand(_ args: ParsedArgs) throws -> Int32 {
    let minBytes = args.values["--min-size"] == nil
        ? 100 * 1024 * 1024
        : try parseMinBytes(args)
    let scan = CloudScanner.scan(minLargeBytes: minBytes)

    if args.flags.contains("--json") {
        try printJSON(CloudPayload(locations: scan.locations, largeFiles: scan.largeFiles))
        return 0
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    guard !scan.locations.isEmpty else {
        print("No local cloud storage found.")
        return 0
    }

    print("\(color("1;36", "Cloud storage")) \(color("2", "— \(scan.locations.count) locations"))")
    for location in scan.locations {
        let count = "\(location.files) files"
        print("  \(padded(humanBytes(location.bytes), to: 10))  \(location.name)  \(color("2", "(" + count + ")"))")
        print("      \(color("2", abbreviated(location.path, home: home)))")
    }

    if !scan.largeFiles.isEmpty {
        print("")
        print("\(color("1;36", "Large cloud files")) \(color("2", "— \(scan.largeFiles.count))"))")
        for file in scan.largeFiles.prefix(50) {
            print("  \(padded(humanBytes(file.bytes), to: 10))  \(abbreviated(file.path, home: home))")
        }
    }
    return 0
}

func updatesCommand(_ args: ParsedArgs) throws -> Int32 {
    let updates = UpdateChecker.pendingSystemUpdates()
    if args.flags.contains("--json") {
        try printJSON(UpdatesPayload(updates: updates))
        return 0
    }

    print("\(color("1;36", "System updates"))")
    for update in updates {
        print("  \(update)")
    }
    print("")
    print(color("2", "Run `maclean scan --category updates` for downloaded update leftovers."))
    return 0
}

func permissionsCommand(_ args: ParsedArgs) throws -> Int32 {
    if let service = args.values["--reset"]?.last {
        guard let bundle = args.values["--bundle"]?.last else {
            throw CLIError("--reset requires --bundle <bundle id>", code: 2)
        }
        guard !service.isEmpty, !bundle.isEmpty else {
            throw CLIError("service and bundle must not be empty", code: 2)
        }
        let apply = args.flags.contains("--apply")
        if apply, !args.flags.contains("--yes") {
            throw CLIError("--apply requires --yes", code: 2)
        }
        guard apply else {
            print("Would reset \(service) for \(bundle). Pass --apply --yes to do it.")
            return 0
        }
        let result = PermissionsScanner.reset(service: service, bundle: bundle)
        guard result.status == 0 else {
            throw CLIError(
                "tccutil failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        print("Reset \(service) for \(bundle).")
        return 0
    }

    let report = PermissionsScanner.scan()
    if args.flags.contains("--json") {
        try printJSON(report)
    } else {
        printPermissions(report)
    }
    return 0
}

func photosCommand(_ args: ParsedArgs) throws -> Int32 {
    let libraries = (args.values["--library"] ?? []).map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let report = PhotosDuplicateScanner.scan(
        libraries: libraries.isEmpty ? nil : libraries,
        includeSimilar: args.flags.contains("--similar"),
        maxDistance: Int(args.values["--max-distance"]?.last ?? "10") ?? 10
    )
    if args.flags.contains("--apply") {
        guard args.flags.contains("--yes") else {
            throw CLIError("--apply requires --yes", code: 2)
        }
        if !args.flags.contains("--force") {
            let processes = ProcessRunner.run("/bin/ps", ["-axo", "comm="], timeout: 10)
            if processes.stdout.lowercased().contains("/photos.app/") {
                throw CLIError("Quit Photos before removing originals, or pass --force.", code: 2)
            }
        }
        let result = DeepCleaner.cleanPhotosDuplicates(
            report: report,
            apply: true,
            permanent: args.flags.contains("--permanent")
        )
        if args.flags.contains("--json") {
            try printJSON(result)
        } else {
            printDeepCleanResult(title: "Photos duplicates", result: result)
            print("Photos may need to repair its library; keep a backup of the library.")
        }
        return result.failed.isEmpty ? 0 : 1
    }
    if args.flags.contains("--json") {
        try printJSON(report)
    } else {
        printPhotos(report)
    }
    return 0
}

func systemCommand(_ args: ParsedArgs) throws -> Int32 {
    let report = ProtectedStoreScanner.scan()
    if let architecture = args.values["--thin"]?.last {
        let apply = args.flags.contains("--apply")
        if apply, !args.flags.contains("--yes") {
            throw CLIError("--apply requires --yes", code: 2)
        }
        let result = UniversalThinner.thin(
            report: report,
            architecture: architecture,
            apply: apply,
            resign: !args.flags.contains("--no-resign")
        )
        if args.flags.contains("--json") {
            try printJSON(result)
        } else {
            print("\(color("1;36", "Universal thinning")) \(color("2", "— \(architecture), \(result.thinned.count) thinned"))")
            if !result.planned.isEmpty {
                print("  Planned: \(result.planned.count)")
            }
            for failure in result.failed.prefix(12) {
                print("  \(color("1;31", failure.reason))  \(failure.path)")
            }
            if apply {
                print("  Backups: ~/Library/Application Support/MacLean/UniversalBackups")
            }
        }
        return result.failed.isEmpty ? 0 : 1
    }

    let apply = args.flags.contains("--apply")
    if apply {
        guard args.flags.contains("--yes") else {
            throw CLIError("--apply requires --yes", code: 2)
        }
        guard args.flags.contains("--permanent") else {
            throw CLIError("protected-store cleanup requires --permanent", code: 2)
        }
        guard geteuid() == 0 else {
            throw CLIError("protected-store cleanup requires root; run with sudo", code: 2)
        }
        let kinds = Set((args.values["--include"] ?? []).flatMap { $0.split(separator: ",") }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        let selected = kinds.isEmpty
            ? Set(["deleted-user", "system-cache"])
            : kinds
        var combined = DeepCleanResult()
        if selected.contains("document-version") {
            let documentReport = DocumentVersionsScanner.scan()
            let documentResult = DocumentVersionCleaner.clean(
                report: documentReport,
                apply: true
            )
            combined.planned.append(contentsOf: documentResult.planned)
            combined.movedToTrash.append(contentsOf: documentResult.movedToTrash)
            combined.deleted.append(contentsOf: documentResult.deleted)
            combined.failed.append(contentsOf: documentResult.failed)
        }
        let remaining = selected.subtracting(["document-version"])
        if !remaining.isEmpty {
            let result = DeepCleaner.cleanProtectedStores(
                report: report,
                kinds: remaining,
                apply: true,
                permanent: true
            )
            combined.planned.append(contentsOf: result.planned)
            combined.movedToTrash.append(contentsOf: result.movedToTrash)
            combined.deleted.append(contentsOf: result.deleted)
            combined.failed.append(contentsOf: result.failed)
        }
        if args.flags.contains("--json") {
            try printJSON(combined)
        } else {
            printDeepCleanResult(title: "Protected stores", result: combined)
        }
        return combined.failed.isEmpty ? 0 : 1
    }

    if args.flags.contains("--json") {
        try printJSON(report)
    } else {
        printProtectedStores(report)
    }
    return 0
}

func deepCommand(_ args: ParsedArgs) throws -> Int32 {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let report = DeepScanner.scan(
        home: home,
        includePermissions: !args.flags.contains("--no-permissions"),
        includePhotos: !args.flags.contains("--no-photos"),
        includeMailTrash: !args.flags.contains("--no-mail"),
        includeProtectedStores: !args.flags.contains("--no-system"),
        includeDocumentVersions: !args.flags.contains("--no-document-versions"),
        includeSimilarPhotos: args.flags.contains("--similar")
    )
    if args.flags.contains("--json") {
        try printJSON(report)
        return 0
    }

    print("\(color("1;36", "Deep scan")) \(color("2", "— \(report.generated.formatted(date: .abbreviated, time: .standard))"))")
    print("")
    printPermissions(report.permissions)
    print("")
    printPhotos(report.photos)
    print("")
    printMailTrash(report.mailTrash, home: home)
    print("")
    printDocumentVersions(report.documentVersions)
    print("")
    printProtectedStores(report.protectedStores)
    return 0
}

func printDocumentVersions(_ report: DocumentVersionsReport) {
    print("\(color("1;36", "Document versions")) \(color("2", "— \(report.files.count) files, \(humanBytes(report.totalBytes))"))")
    for file in report.files.prefix(20) {
        let selected = file.versions.filter(\.selected)
        print("  \(padded(humanBytes(file.bytes), to: 10))  \(file.app) · \(file.path)")
        if !selected.isEmpty {
            print("      \(color("2", "selected \(selected.count) versions, \(humanBytes(selected.reduce(0) { $0 + $1.bytes }))"))")
        }
    }
    if let error = report.error {
        print("  \(color("1;31", error))")
    }
}

func printDeepCleanResult(title: String, result: DeepCleanResult) {
    print("\(color("1;36", title)) \(color("2", "— \(result.removedCount) removed"))")
    if !result.planned.isEmpty {
        print("  Planned: \(result.planned.count)")
    }
    if !result.movedToTrash.isEmpty {
        print("  Moved to Trash: \(result.movedToTrash.count)")
    }
    if !result.deleted.isEmpty {
        print("  Deleted: \(result.deleted.count)")
    }
    for failure in result.failed.prefix(12) {
        print("  \(color("1;31", failure.reason))  \(failure.path)")
    }
}

func printPermissions(_ report: PermissionReport) {
    let allowed = report.grants.filter(\.allowed).count
    print("\(color("1;36", "Permissions")) \(color("2", "— \(allowed)/\(report.grants.count) granted"))")
    if let error = report.error {
        print("  \(color("1;31", error))")
        return
    }
    for grant in report.grants.prefix(40) {
        let state = grant.allowed ? color("1;32", "allow") : color("2", "deny ")
        let modified = grant.lastModified.map {
            " · \($0.formatted(date: .abbreviated, time: .omitted))"
        } ?? ""
        print("  \(state)  \(grant.service)  \(grant.client)\(modified)")
    }
    if report.grants.count > 40 {
        print("  \(color("2", "… \(report.grants.count - 40) more"))")
    }
}

func printPhotos(_ report: PhotosDuplicateReport) {
    let originals = report.libraries.reduce(0) { $0 + $1.originalFiles }
    print("\(color("1;36", "Photos duplicates")) \(color("2", "— \(report.libraries.count) libraries, \(originals) originals"))")
    if let error = report.error {
        print("  \(color("2", error))")
    }
    print("  Exact: \(report.exactGroups.count) groups, \(humanBytes(report.wastedBytes)) reclaimable")
    for group in report.exactGroups.prefix(8) {
        print("    \(humanBytes(group.size)) × \(group.paths.count)  \(group.paths[0])")
    }
    if report.similarGroups.isEmpty == false {
        print("  Similar: \(report.similarGroups.count) groups, \(humanBytes(report.similarBytes))")
    }
    print("  \(color("2", "Report only: remove photos in Photos to keep its database consistent."))")
}

func printMailTrash(_ report: MailTrashReport, home: URL) {
    print("\(color("1;36", "Mail Trash")) \(color("2", "— \(report.mailboxes.count) mailboxes, \(humanBytes(report.totalBytes))"))")
    for mailbox in report.mailboxes.prefix(20) {
        print("  \(padded(humanBytes(mailbox.bytes), to: 10))  \(mailbox.mailbox) · \(mailbox.messageCount) messages")
        print("      \(color("2", abbreviated(mailbox.path, home: home)))")
    }
    print("  \(color("2", "Report only: delete messages in Mail to keep its index consistent."))")
}

func printProtectedStores(_ report: ProtectedStoreReport) {
    print("\(color("1;36", "Protected stores")) \(color("2", report.isRoot ? "— running as root" : "— report only, root required for cleanup"))")
    print("  Deleted users: \(report.deletedUsers.count) items, \(humanBytes(report.deletedUsers.reduce(0) { $0 + $1.bytes }))")
    for item in report.deletedUsers.prefix(10) {
        print("    \(padded(humanBytes(item.bytes), to: 10))  \(item.path)")
    }
    print("  Document versions: \(report.documentVersions.count) items, \(humanBytes(report.documentVersions.reduce(0) { $0 + $1.bytes }))")
    for item in report.documentVersions.prefix(10) {
        print("    \(padded(humanBytes(item.bytes), to: 10))  \(item.path)")
    }
    print("  System caches/logs: \(report.systemCaches.count) items, \(humanBytes(report.systemCaches.reduce(0) { $0 + $1.bytes }))")
    for item in report.systemCaches.prefix(10) {
        print("    \(padded(humanBytes(item.bytes), to: 10))  \(item.path)")
    }
    print("  Universal binaries: \(report.universalBinaries.count) items, \(humanBytes(report.universalBytes)) total, ~\(humanBytes(report.universalSavings)) estimated savings")
    for item in report.universalBinaries.prefix(10) {
        print("    \(padded(humanBytes(item.estimatedSavings), to: 10))  \(item.name)  \(item.archs.joined(separator: " "))")
    }
    for error in report.errors.prefix(5) {
        print("  \(color("1;31", error))")
    }
    print("  \(color("2", "Protected-store cleanup is not automated; universal thinning can invalidate code signatures."))")
}

func documentVersionsCommand(_ args: ParsedArgs) throws -> Int32 {
    let report = DocumentVersionsScanner.scan()
    if args.flags.contains("--apply") {
        guard args.flags.contains("--yes") else {
            throw CLIError("--apply requires --yes", code: 2)
        }
        let result = DocumentVersionCleaner.clean(report: report, apply: true)
        if args.flags.contains("--json") {
            try printJSON(result)
        } else {
            printDeepCleanResult(title: "Document versions", result: result)
        }
        return result.failed.isEmpty ? 0 : 1
    }
    if args.flags.contains("--json") {
        try printJSON(report)
    } else {
        print("\(color("1;36", "Document versions")) \(color("2", "— \(report.files.count) files, \(humanBytes(report.totalBytes))"))")
        for file in report.files.prefix(25) {
            let selected = file.versions.filter(\.selected)
            print("  \(padded(humanBytes(file.bytes), to: 10))  \(file.app) · \(file.path)")
            if !selected.isEmpty {
                print("      \(color("2", "selected \(selected.count) versions, \(humanBytes(selected.reduce(0) { $0 + $1.bytes }))"))")
            }
        }
        if let error = report.error {
            print("  \(color("1;31", error))")
        }
    }
    return 0
}

func quarantineCommand(_ args: ParsedArgs) throws -> Int32 {
    guard let path = args.positionals.first else {
        throw CLIError("usage: maclean quarantine <path> [--reason <text>]", code: 2)
    }
    let expanded = (path as NSString).expandingTildeInPath
    let reason = args.values["--reason"]?.last ?? "manual quarantine"
    do {
        let record = try QuarantineManager.quarantine(path: expanded, reason: reason)
        if args.flags.contains("--json") {
            try printJSON(record)
        } else {
            print("Quarantined \(abbreviated(record.originalPath, home: FileManager.default.homeDirectoryForCurrentUser))")
            print(color("2", record.quarantinedPath))
        }
        return 0
    } catch {
        throw CLIError("quarantine failed: \(error.localizedDescription)")
    }
}

func protectionCommand(_ args: ParsedArgs) throws -> Int32 {
    let profile = (args.values["--profile"]?.last ?? "protected").lowercased()
    let extraPaths = (args.values["--path"] ?? []).map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }

    var configuration: ScanConfiguration
    switch profile {
    case "fast":
        configuration = .fast()
    case "default", "standard":
        configuration = .standard()
    case "smart":
        configuration = .smart()
    case "protected":
        configuration = .protectedScan()
    case "protected-dirs":
        configuration = .protectedWithDirectories(extraPaths)
    case "paranoid":
        configuration = .paranoid()
    case "paranoid-dirs":
        configuration = .paranoidWithDirectories(extraPaths)
    default:
        throw CLIError(
            "unknown profile '\(profile)'. Use fast, default, smart, protected, protected-dirs, paranoid, or paranoid-dirs.",
            code: 2
        )
    }

    if !extraPaths.isEmpty {
        configuration.scanOption.insert(.diskURLs)
        configuration.diskScanURLs = extraPaths.map(\.path)
    }

    let explicitYaraRules = args.values["--yara-rules"]?.last.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let yaraRules = explicitYaraRules ?? (
        args.flags.contains("--no-bundled-rules") ? nil : BundledRules.directory()
    )
    let useClamAV = args.flags.contains("--clamav")
    let clamAVDatabase = args.values["--clamav-db"]?.last.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    let runCorpusYara: Bool? = args.flags.contains("--corpus-yara")
        ? true
        : (args.flags.contains("--no-corpus-yara") ? false : nil)
    let corpus: PantherCorpus?
    if let corpusSource = args.values["--corpus"]?.last {
        do {
            let resolved = try CorpusFetcher.resolve(
                corpusSource,
                refresh: args.flags.contains("--corpus-refresh")
            )
            corpus = try PantherCorpus(
                path: resolved.path,
                includeExtended: configuration.extendedRulesUsageEnabled
            )
        } catch {
            throw CLIError("could not load corpus: \(error.localizedDescription)", code: 2)
        }
    } else {
        corpus = nil
    }

    let report = ProtectionScanner(configuration: configuration).scan(
        extraPaths: extraPaths,
        yaraRules: yaraRules,
        useClamAV: useClamAV,
        clamAVDatabase: clamAVDatabase,
        corpus: corpus,
        corpusYara: runCorpusYara
    )

    if args.flags.contains("--json") {
        try printJSON(report)
        return 0
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let counts = Dictionary(grouping: report.findings, by: \.severity)
    let high = counts[.high]?.count ?? 0
    let medium = counts[.medium]?.count ?? 0
    let low = counts[.low]?.count ?? 0
    let info = counts[.info]?.count ?? 0

    print("\(color("1;36", "Protection audit")) \(color("2", "— \(configuration.scanMode.title) (mode \(configuration.scanMode.rawValue), options 0x\(String(configuration.scanOption.rawValue, radix: 16, uppercase: true)))"))")
    print("  \(color("2", "Detectors: \(configuration.optionsDescription)"))")
    let depth = configuration.maxEnumerationDepth < 0
        ? "unlimited"
        : String(configuration.maxEnumerationDepth)
    print("  \(color("2", "Depth: \(depth) · extended rules: \(configuration.extendedRulesUsageEnabled) · privileged auth allowed: \(configuration.scanMode.canAskPrivilegedAgentAuthorizationOnScan) (never requested)"))")
    print("  \(color("2", "Scanned \(report.scannedFiles) files"))")
    if let corpus = report.corpus {
        let version = corpus.version.map { "v\($0)" } ?? "unknown version"
        print("  \(color("2", "Corpus: \(version), updated \(corpus.updateDate ?? "unknown") — \(corpus.hashRules) hash, \(corpus.pathRules) path, \(corpus.launchAgentRules) launch, \(corpus.teamIDRules) team, \(corpus.sectionHashRules) section, \(corpus.yaraRules) YARA, \(corpus.scanTargets) targets"))")
    }

    if report.findings.isEmpty {
        print("")
        print("No findings.")
    } else {
        print("")
        print("\(color("1", "Findings:")) \(high) high, \(medium) medium, \(low) low, \(info) info")
        let visible = report.findings.prefix(100)
        for finding in visible {
            let tag: String
            switch finding.severity {
            case .high: tag = color("31", "[HIGH]")
            case .medium: tag = color("33", "[MED ]")
            case .low: tag = color("36", "[LOW ]")
            case .info: tag = color("2", "[INFO]")
            }
            print("  \(tag) \(abbreviated(finding.path, home: home))")
            print("      \(finding.title)")
            if !finding.detail.isEmpty {
                print("      \(color("2", String(finding.detail.prefix(300))))")
            }
        }
        if report.findings.count > visible.count {
            print("  \(color("2", "… and \(report.findings.count - visible.count) more (use --json)"))")
        }
    }

    if let yara = report.yara {
        print("")
        print("\(color("1", "YARA:")) \(yara.matches) matches")
        if let note = yara.note { print("  \(color("2", note))") }
    } else {
        print("")
        print(color("2", "YARA: not requested (pass --yara-rules <file-or-directory> and --path <dir>)"))
    }

    if let corpusYara = report.corpusYara {
        print("")
        print("\(color("1", "Corpus YARA:")) \(corpusYara.matches) matches")
        if let note = corpusYara.note { print("  \(color("2", note))") }
    }

    if let clamav = report.clamav {
        print("")
        print("\(color("1", "ClamAV:")) \(clamav.matches) matches")
        if let note = clamav.note { print("  \(color("2", note))") }
    } else {
        print("")
        print(color("2", "ClamAV: not requested (pass --clamav; install with `brew install clamav`, update with `freshclam`)"))
    }

    return 0
}
