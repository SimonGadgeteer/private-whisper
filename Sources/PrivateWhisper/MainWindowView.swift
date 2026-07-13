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
            DictionaryView(configStore: configStore)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SettingsView(configStore: configStore)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 600)
    }
}

/// Personal dictionary: names, jargon, and Swiss terms. Terms are fed to
/// whisper as a recognition bias AND to the cleanup model as a glossary.
private struct DictionaryView: View {
    @ObservedObject var configStore: ConfigStore
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, jargon, and product terms you dictate often. Whisper is biased toward these spellings, and the cleanup model enforces them (e.g. \"Sonepar\", \"Müller-Weber\", \"Winterthur\", \"ERP-Migration\").")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Add a term…", text: $newTerm)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if configStore.config.dictionary.isEmpty {
                Spacer()
                Text("No terms yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(configStore.config.dictionary, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button(role: .destructive) {
                                configStore.config.dictionary.removeAll { $0 == term }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset)
                Text("\(configStore.config.dictionary.count) terms (the first 80 are used for whisper biasing)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !configStore.config.dictionary.contains(term) else { return }
        configStore.config.dictionary.append(term)
        configStore.config.dictionary.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        newTerm = ""
    }
}

private struct StatisticsView: View {
    @ObservedObject var statsStore: StatsStore

    private var stats: DictationStats { statsStore.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Hero: the number that makes dictation worth it.
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeSavedString)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("saved vs. typing (est. 40 words/min)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 10) {
                    StatTile(value: "\(stats.totalDictations)", label: "Dictations")
                    StatTile(value: "\(stats.totalWords)", label: "Words")
                    StatTile(value: String(format: "%.1f s", stats.averageLatency), label: "Avg. latency")
                    StatTile(value: wordsPerMinute, label: "Words/min")
                }

                GroupBox("Last 14 days") {
                    DayColumnsChart(days: lastDays(14))
                        .frame(height: 120)
                        .padding(.top, 6)
                }

                if !stats.byLanguage.isEmpty {
                    GroupBox("Languages") {
                        LanguageShareBar(byLanguage: stats.byLanguage)
                            .padding(.vertical, 6)
                    }
                }

                Text("Counters only — transcript text is never stored unless history logging is enabled in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var timeSavedString: String {
        // Typing the same words at ~40 wpm vs. the time actually spent
        // speaking + waiting for the pipeline.
        let typingMinutes = Double(stats.totalWords) / 40.0
        let dictationMinutes = stats.totalAudioSeconds / 60.0
            + (stats.totalTranscriptionSeconds + stats.totalCleanupSeconds) / 60.0
        let saved = max(0, typingMinutes - dictationMinutes)
        if saved < 1 { return String(format: "%.0f s", saved * 60) }
        if saved < 90 { return String(format: "%.0f min", saved) }
        return String(format: "%.1f h", saved / 60)
    }

    private var wordsPerMinute: String {
        guard stats.totalAudioSeconds > 5 else { return "–" }
        return String(format: "%.0f", Double(stats.totalWords) / (stats.totalAudioSeconds / 60))
    }

    private func lastDays(_ n: Int) -> [DayCount] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEEE" // single-letter weekday
        return (0..<n).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())
            else { return nil }
            let key = formatter.string(from: date)
            return DayCount(
                id: key,
                weekdayLetter: weekday.string(from: date),
                dayNumber: Calendar.current.component(.day, from: date),
                count: stats.byDay[key] ?? 0,
                isToday: offset == 0)
        }
    }
}

private struct DayCount: Identifiable {
    let id: String
    let weekdayLetter: String
    let dayNumber: Int
    let count: Int
    let isToday: Bool
}

/// Vertical columns, baseline-anchored, rounded tops; value labels only on
/// non-zero days; today at full tint.
private struct DayColumnsChart: View {
    let days: [DayCount]

    var body: some View {
        let maxCount = max(1, days.map(\.count).max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    Text(day.count > 0 ? "\(day.count)" : "")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(height: 10)
                    UnevenRoundedRectangle(
                        topLeadingRadius: 3, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: 3)
                        .fill(day.isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                        .frame(height: day.count == 0
                            ? 2
                            : max(6, 62 * CGFloat(day.count) / CGFloat(maxCount)))
                        .frame(maxHeight: 64, alignment: .bottom)
                    Text(day.weekdayLetter)
                        .font(.system(size: 9))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                    Text("\(day.dayNumber)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One stacked share bar + legend chips. Hues are fixed per language (color
/// follows the entity, never its rank); counts are always shown as text.
private struct LanguageShareBar: View {
    let byLanguage: [String: Int]

    private static let hues: [String: Color] = [
        "en": Color(red: 0.31, green: 0.65, blue: 1.0),
        "de": Color(red: 0.62, green: 0.42, blue: 1.0),
        "fr": Color(red: 1.0, green: 0.45, blue: 0.66),
        "it": Color(red: 0.2, green: 0.78, blue: 0.65),
    ]
    private static let fallback = Color.gray

    private var entries: [(code: String, count: Int)] {
        byLanguage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        let total = max(1, entries.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(entries, id: \.code) { entry in
                        Capsule()
                            .fill(color(entry.code))
                            .frame(width: max(8, (geo.size.width - CGFloat(entries.count - 1) * 2)
                                * CGFloat(entry.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(entries, id: \.code) { entry in
                    HStack(spacing: 5) {
                        Circle().fill(color(entry.code)).frame(width: 7, height: 7)
                        Text("\(name(entry.code)) \(entry.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ code: String) -> Color { Self.hues[code] ?? Self.fallback }

    private func name(_ code: String) -> String {
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
