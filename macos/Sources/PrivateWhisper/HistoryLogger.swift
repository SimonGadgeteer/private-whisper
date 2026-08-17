import Foundation

/// Optional transcript history as JSONL (settings toggle, default OFF).
enum HistoryLogger {
    struct Entry: Codable {
        let timestamp: String
        let language: String
        let rawTranscript: String
        let cleanedText: String?
        let audioSeconds: Double
        let transcriptionSeconds: Double
        let cleanupSeconds: Double?
    }

    static func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        let url = AppConfig.historyURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
