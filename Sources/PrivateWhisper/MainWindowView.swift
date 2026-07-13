import SwiftUI

/// The app's main window: statistics dashboard + settings, opened from the
/// menu bar.
struct MainWindowView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var statsStore: StatsStore

    var body: some View {
        TabView {
            StatisticsView(statsStore: statsStore)
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
            SettingsView(configStore: configStore)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 600)
    }
}

private struct StatisticsView: View {
    @ObservedObject var statsStore: StatsStore

    private var stats: DictationStats { statsStore.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())],
                          spacing: 12) {
                    StatTile(value: "\(stats.totalDictations)", label: "Dictations")
                    StatTile(value: "\(stats.totalWords)", label: "Words")
                    StatTile(value: minutesString(stats.totalAudioSeconds), label: "Audio dictated")
                    StatTile(value: String(format: "%.1f s", stats.averageLatency),
                             label: "Avg. latency")
                    StatTile(value: wordsPerMinute, label: "Words/min speaking")
                    StatTile(value: "\(stats.cleanupFallbacks)", label: "Cleanup fallbacks")
                }

                if !stats.byLanguage.isEmpty {
                    GroupBox("Languages") {
                        VStack(spacing: 6) {
                            let total = max(1, stats.totalDictations)
                            ForEach(stats.byLanguage.sorted { $0.value > $1.value }, id: \.key) { lang, count in
                                BarRow(
                                    label: languageName(lang),
                                    count: count,
                                    fraction: Double(count) / Double(total))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !stats.byDay.isEmpty {
                    GroupBox("Last 14 days") {
                        VStack(spacing: 6) {
                            let days = lastDays(14)
                            let maxCount = max(1, days.map(\.count).max() ?? 1)
                            ForEach(days, id: \.day) { entry in
                                BarRow(
                                    label: entry.day.suffix(5).replacingOccurrences(of: "-", with: "."),
                                    count: entry.count,
                                    fraction: Double(entry.count) / Double(maxCount))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Text("Counters only — transcript text is never stored unless history logging is enabled in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var wordsPerMinute: String {
        guard stats.totalAudioSeconds > 5 else { return "–" }
        return String(format: "%.0f", Double(stats.totalWords) / (stats.totalAudioSeconds / 60))
    }

    private func minutesString(_ seconds: Double) -> String {
        seconds < 120 ? String(format: "%.0f s", seconds) : String(format: "%.1f min", seconds / 60)
    }

    private func lastDays(_ n: Int) -> [(day: String, count: Int)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return (0..<n).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())
            else { return nil }
            let key = formatter.string(from: date)
            return (key, stats.byDay[key] ?? 0)
        }
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BarRow: View {
    let label: String
    let count: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                if count > 0 {
                    Capsule()
                        .fill(.tint.opacity(0.75))
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
