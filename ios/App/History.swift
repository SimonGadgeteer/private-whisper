// Last 50 dictations, JSON in Application Support. The app adds the raw transcript (it never loses text);
// the keyboard's `pw.lastResult` is merged in by requestId (final text, cleaned, inserted, reason, timings).
import Foundation

@MainActor
final class History: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var requestId: String?
        var at: Date
        var language: String
        var raw: String
        var final: String?
        var cleaned: Bool?
        var inserted: Bool?
        var reason: String?
        var source: String              // "keyboard", "app", "recovered"
        var audioSeconds: Double?
        var model: String?
        var computePath: String?
        var asrMs: Int?
        var stopToAsrMs: Int?
        var cleanupMs: Int?
        var stopToInsertMs: Int?

        var displayText: String { final ?? raw }
    }

    static let shared = History()
    @Published private(set) var entries: [Entry] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entry].self, from: data) { entries = e }
    }

    func contains(requestId: String) -> Bool { entries.contains { $0.requestId == requestId } }

    func add(raw: String, language: DictationLanguage, requestId: String?, source: String, timing: AppTiming?) {
        var e = Entry(requestId: requestId, at: Date(), language: language.rawValue, raw: raw, source: source)
        if let t = timing {
            e.audioSeconds = t.audioSeconds; e.model = t.model; e.computePath = t.computePath; e.asrMs = t.asrMs
            e.stopToAsrMs = Int((t.asrDoneAt - t.stopReceivedAt) * 1000)
        }
        entries.insert(e, at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        save()
    }

    func mergeKeyboardResult() {
        let d = AppGroup.defaults
        d.synchronize()
        guard let r = d.codable(KeyboardResult.self, forKey: Keys.lastResult) else { return }
        guard let i = entries.firstIndex(where: { $0.requestId == r.requestId }) else {
            Log.info("history", "keyboard result for unknown request \(r.requestId.prefix(8))")
            return
        }
        entries[i].final = r.text
        entries[i].cleaned = r.cleaned
        entries[i].inserted = r.inserted
        entries[i].reason = r.reason
        entries[i].cleanupMs = r.cleanupMs
        entries[i].stopToInsertMs = r.stopToInsertMs
        save()
    }

    func delete(_ offsets: IndexSet) { entries.remove(atOffsets: offsets); save() }
    func clear() { entries = []; save() }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
