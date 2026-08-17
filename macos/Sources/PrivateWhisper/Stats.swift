import Foundation

/// Aggregate usage statistics — counters only, no transcript content (full
/// transcripts are stored only when history logging is explicitly enabled).
struct DictationStats: Codable {
    var totalDictations = 0
    var totalWords = 0
    var totalAudioSeconds = 0.0
    var totalTranscriptionSeconds = 0.0
    var totalCleanupSeconds = 0.0
    var cleanupFallbacks = 0
    /// ISO language code → dictation count
    var byLanguage: [String: Int] = [:]
    /// "yyyy-MM-dd" → dictation count (kept to the last 60 days)
    var byDay: [String: Int] = [:]

    var averageLatency: Double {
        guard totalDictations > 0 else { return 0 }
        return (totalTranscriptionSeconds + totalCleanupSeconds) / Double(totalDictations)
    }
}

@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var stats: DictationStats

    private static var url: URL { AppConfig.supportDir.appendingPathComponent("stats.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode(DictationStats.self, from: data) {
            stats = loaded
        } else {
            stats = DictationStats()
        }
    }

    func record(
        words: Int, language: String, audioSeconds: Double,
        transcriptionSeconds: Double, cleanupSeconds: Double?, fellBack: Bool
    ) {
        stats.totalDictations += 1
        stats.totalWords += words
        stats.totalAudioSeconds += audioSeconds
        stats.totalTranscriptionSeconds += transcriptionSeconds
        stats.totalCleanupSeconds += cleanupSeconds ?? 0
        if fellBack { stats.cleanupFallbacks += 1 }
        stats.byLanguage[language, default: 0] += 1

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let today = formatter.string(from: Date())
        stats.byDay[today, default: 0] += 1
        if stats.byDay.count > 60 {
            for key in stats.byDay.keys.sorted().dropLast(60) {
                stats.byDay.removeValue(forKey: key)
            }
        }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: AppConfig.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stats) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
