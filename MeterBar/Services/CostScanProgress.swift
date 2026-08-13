import Foundation

/// What a refresh is about to read — or is already reading — so the Costs page
/// can say "42 files, 180 MB, last 30 days" instead of a silent hang.
///
/// Listed counts come from the mtime-filtered walk, not the whole home
/// directory. A 10 GB archive that has not been touched inside the window does
/// not appear here.
nonisolated struct CostScanProgress: Equatable, Sendable {
    var windowDays: Int
    var listedFiles: Int
    var listedBytes: Int64
    var processedFiles: Int
    var bytesRead: Int
    var isComplete: Bool

    /// 1 GiB. Above this the banner warns that even the windowed corpus is huge.
    static let largeCorpusBytes: Int64 = 1_073_741_824

    init(
        windowDays: Int,
        listedFiles: Int = 0,
        listedBytes: Int64 = 0,
        processedFiles: Int = 0,
        bytesRead: Int = 0,
        isComplete: Bool = false
    ) {
        self.windowDays = windowDays
        self.listedFiles = listedFiles
        self.listedBytes = listedBytes
        self.processedFiles = processedFiles
        self.bytesRead = bytesRead
        self.isComplete = isComplete
    }

    var isLargeCorpus: Bool { listedBytes >= Self.largeCorpusBytes }

    var fraction: Double? {
        guard listedFiles > 0 else { return nil }
        return min(1, Double(processedFiles) / Double(listedFiles))
    }

    var formattedListedSize: String { Self.formatBytes(listedBytes) }

    var statusText: String {
        if listedFiles == 0 && !isComplete {
            return "Listing session files…"
        }
        if isComplete {
            return "Scanned \(listedFiles) files (\(formattedListedSize))"
        }
        if processedFiles > 0 {
            return "Scanning \(processedFiles) of \(listedFiles) files · \(formattedListedSize)"
        }
        return "Scanning \(listedFiles) files (\(formattedListedSize))"
    }

    var detailText: String {
        if isLargeCorpus {
            return "This \(windowDays)-day window is still \(formattedListedSize). Older archives are not scanned."
        }
        return "Only files touched in the last \(windowDays) days. Quota APIs do not include this history."
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
