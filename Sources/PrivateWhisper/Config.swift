import Foundation

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case rightOption
    case leftOption
    case rightCommand
    case fnKey

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .fnKey: return 63
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .fnKey: return "Fn / Globe"
        }
    }
}

struct AppConfig: Codable, Equatable {
    var hotkey: HotkeyChoice = .rightOption
    /// CoreAudio device UID; nil = system default
    var microphoneUID: String? = nil
    /// "large-v3" or "large-v3-turbo" — resolved to ggml-<name>.bin in the models dir
    var whisperModel: String = "large-v3-turbo"
    var lmStudioURL: String = "http://localhost:1234/v1"
    var cleanupModel: String = "qwen/qwen3.5-4b"
    var cleanupEnabled: Bool = true
    var cleanupTimeoutSeconds: Double = 15
    var historyLoggingEnabled: Bool = false
    var launchAtLogin: Bool = false
    var notchIndicatorEnabled: Bool = true
    /// Personal dictionary: names/jargon biased into whisper and enforced in cleanup.
    var dictionary: [String] = []
    /// Frontmost-app bundle id -> tone hint appended to the cleanup prompt.
    var appTones: [String: String] = AppConfig.defaultAppTones
    /// Hold-to-speak hotkey for command mode (voice-edit the selection). nil = disabled.
    var commandHotkey: HotkeyChoice? = .rightCommand

    static let defaultAppTones: [String: String] = [
        "com.apple.mail": "formal email register",
        "com.microsoft.Outlook": "formal email register",
        "com.tinyspeck.slackmacgap": "casual chat register",
        "com.microsoft.teams2": "professional chat register",
        "com.apple.MobileSMS": "casual chat register",
        "com.microsoft.VSCode": "technical, keep identifiers and code terms verbatim",
    ]

    static let supportDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PrivateWhisper")

    /// One-time migration from the pre-rename "LocalDictation" support dir
    /// (config + several GB of whisper models). Merge-style: moves items that
    /// don't already exist in the new dir. Called at process start.
    static func migrateLegacySupportDir() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalDictation")
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? [] {
            let src = legacy.appendingPathComponent(name)
            let dst = supportDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }

    static let configURL = supportDir.appendingPathComponent("config.json")
    static let modelsDir = supportDir.appendingPathComponent("models")
    static let historyURL = supportDir.appendingPathComponent("history.jsonl")

    var whisperModelPath: URL {
        Self.modelsDir.appendingPathComponent("ggml-\(whisperModel).bin")
    }

    // Tolerant decoding: missing keys fall back to defaults so config.json
    // survives app updates that add fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        hotkey = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? defaults.hotkey
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? defaults.whisperModel
        lmStudioURL = try c.decodeIfPresent(String.self, forKey: .lmStudioURL) ?? defaults.lmStudioURL
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel) ?? defaults.cleanupModel
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? defaults.cleanupEnabled
        cleanupTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .cleanupTimeoutSeconds) ?? defaults.cleanupTimeoutSeconds
        historyLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyLoggingEnabled) ?? defaults.historyLoggingEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        notchIndicatorEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchIndicatorEnabled) ?? defaults.notchIndicatorEnabled
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? defaults.dictionary
        appTones = try c.decodeIfPresent([String: String].self, forKey: .appTones) ?? defaults.appTones
        commandHotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .commandHotkey) ?? defaults.commandHotkey
    }

    init() {}

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }
}

/// Observable wrapper so SwiftUI settings and the pipeline share one config.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig {
        didSet { config.save() }
    }

    init() {
        config = AppConfig.load()
    }
}
