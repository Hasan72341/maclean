import Foundation

public enum UpdateChecker {
    public static func pendingSystemUpdates() -> [String] {
        let result = ProcessRunner.run("/usr/sbin/softwareupdate", ["-l"], timeout: 120)
        guard !result.timedOut else { return ["Timed out while querying softwareupdate."] }
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return [message.isEmpty ? "softwareupdate exited \(result.status)" : message]
        }

        var updates: [String] = []
        var currentLabel: String?

        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                currentLabel = line.replacingOccurrences(of: "* Label:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Title:") {
                if let currentLabel {
                    updates.append("\(currentLabel) — \(line.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces))")
                } else {
                    updates.append(line)
                }
            }
        }

        return updates.isEmpty ? ["No system updates available."] : updates
    }
}
