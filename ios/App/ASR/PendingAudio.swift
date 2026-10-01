// Never lose the audio (reviewer major). Every utterance is written here BEFORE WhisperKit runs and deleted only
// once History has its text (or it was silence). Anything left over — background failure, background-task expiry,
// CPU-monitor kill, jetsam — is transcribed in the foreground on the next didBecomeActive, into History + clipboard.
//
// Format: raw 16 kHz mono Float32 (native endian), `<requestId>.<language>.<s|n>.f32`, in Application Support/pending
// (not Caches, which iOS may purge; excluded from backup). The dictation's language settings ride in the filename (one
// atomic write) so recovery never forces a different language onto the audio (Whisper would translate). Files
// without them (older builds) recover with `.auto`.
import Foundation

enum PendingAudio {
    struct Item {
        let id: String; let url: URL; let bytes: Int; let modified: Date
        let language: DictationLanguage; let germanIsSwiss: Bool
    }

    static let dir: URL = {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v)
        return u
    }()

    private static func safe(_ id: String) -> String {
        let s = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return s.isEmpty ? UUID().uuidString : s
    }

    /// Writes off the main thread; returns once the file is on disk.
    @discardableResult
    static func save(_ samples: [Float], id: String, language: DictationLanguage, germanIsSwiss: Bool) async -> Bool {
        remove(id)                                        // one file per id
        let target = dir.appendingPathComponent("\(safe(id)).\(language.rawValue).\(germanIsSwiss ? "s" : "n").f32")
        return await Task.detached(priority: .userInitiated) {
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                Log.error("pending", "save failed: \(error.localizedDescription)")
                return false
            }
        }.value
    }

    static func remove(_ id: String) {
        let prefix = safe(id) + "."
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "f32" && f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    static func list() -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "f32" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let parts = u.deletingPathExtension().lastPathComponent.split(separator: ".").map(String.init)
            let lang = parts.count > 1 ? DictationLanguage(rawValue: parts[1]) ?? .auto : .auto
            let swiss = parts.count > 2 ? parts[2] == "s" : Settings.germanIsSwiss
            return Item(id: parts.first ?? "", url: u,
                        bytes: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast,
                        language: lang, germanIsSwiss: swiss)
        }.sorted { $0.modified < $1.modified }
    }

    static func load(_ item: Item) -> [Float]? {
        guard let data = try? Data(contentsOf: item.url), data.count >= 4, data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
