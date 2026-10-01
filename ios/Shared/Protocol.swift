// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/DictationStatus.swift, DictusCore/KeyboardDictationURL.swift, DictusCore/DictationSessionLiveness.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import Foundation

enum DictationStatus: String {
    case idle, requested, recording, transcribing, ready, failed
    var isActive: Bool { self == .requested || self == .recording || self == .transcribing }
}

enum SessionState: String {
    case warming, warmIdle = "warm_idle", recording, transcribing, dead
    var isWarm: Bool { self == .warmIdle || self == .recording || self == .transcribing }
}

enum ModelState: String { case notInstalled, downloading, compiling, installed, failed }

enum DictationLanguage: String, CaseIterable {
    case auto, en, de, gsw, fr
    var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .en: return "en"
        case .de, .gsw: return "de"
        case .fr: return "fr"
        }
    }
    var nlCode: String { self == .en ? "en" : self == .fr ? "fr" : "de" }   // NLLanguageRecognizer code
    var chip: String {
        switch self { case .auto: return "Auto"; case .en: return "EN"; case .de: return "DE"; case .gsw: return "CH"; case .fr: return "FR" }
    }
    var next: DictationLanguage {
        switch self { case .en: return .de; case .de: return .gsw; case .gsw: return .fr; case .fr: return .auto; case .auto: return .en }
    }
}

/// Model constants live here so both processes use the same default (reviewer minor).
/// Reviewer minor applied: turbo_632 (device-proven by Dictus on iPhone16,2) is the primary;
/// 626MB (Argmax's recommendation, unmeasured on A17 Pro) is the alternative.
enum ModelCatalog {
    static let primary = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let alternative = "openai_whisper-large-v3-v20240930_626MB"
    static let small = "openai_whisper-small"
    static let base = "openai_whisper-base"
    static var selectable: [String] {
        #if DEBUG
        return [primary, alternative, small]
        #else
        return [primary, alternative]
        #endif
    }
    /// Candidates for the background CPU-only fallback (smaller = faster on CPU, less memory).
    static let cpuFallbackChoices = [small, base]
    static func displayName(_ v: String) -> String {
        switch v {
        case primary: return "Large v3 turbo (632 MB)"
        case alternative: return "Large v3 (626 MB, experimental)"
        case small: return "Whisper small (dev / CPU fallback)"
        case base: return "Whisper base (CPU fallback)"
        default: return v
        }
    }
}

enum DictationURL {
    static let scheme = "pwhisper"
    enum Intent: String { case record, prepare, open }
    static func make(_ intent: Intent, requestId: String? = nil) -> URL {
        var c = URLComponents(); c.scheme = scheme; c.host = intent.rawValue
        c.queryItems = [URLQueryItem(name: "source", value: "keyboard")]
            + (requestId.map { [URLQueryItem(name: "req", value: $0)] } ?? [])
        return c.url!
    }
    static func parse(_ url: URL) -> (intent: Intent, requestId: String?)? {
        guard url.scheme?.lowercased() == scheme,
              let intent = url.host.flatMap({ Intent(rawValue: $0.lowercased()) }) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard intent == .open || items.contains(where: { $0.name == "source" && $0.value == "keyboard" }) else { return nil }
        return (intent, items.first { $0.name == "req" }?.value)
    }
}

enum Timing {
    static let darwinFallback: TimeInterval = 0.5      // keyboard: still `requested` → open URL
    static let micDebounce: TimeInterval = 1.5
    static let warmHeartbeatMaxAge: TimeInterval = 5   // keyboard warm gate (idle heartbeat is 3 s)
    static let darwinSkipHeartbeatAge: TimeInterval = 30 // reviewer: only skip the Darwin attempt past this
    static let idleHeartbeat: TimeInterval = 3         // app audio thread, gate closed
    static let recordingHeartbeat: TimeInterval = 1
    static let levelInterval: TimeInterval = 0.2
    static let watchdogTick: TimeInterval = 1
    static let watchdogStale: TimeInterval = 5         // no level/status signal …
    static let coldGrace: TimeInterval = 15            // … or 15 s while pw.coldStart
    static let requestedWarmDeadline: TimeInterval = 3 // reviewer: `requested` hard deadline (ignores heartbeat)
    static let livenessRecording: TimeInterval = 4     // must stay < watchdogStale (#261)
    static let livenessTranscribing: TimeInterval = 8
    static let transcriptRetry: TimeInterval = 0.1     // cross-process propagation lag
    static let transcriptClaimMaxAge: TimeInterval = 60
    static let transcriptSweepAge: TimeInterval = 300
    static let minClipSamples = 8_000                  // 0.5 s @ 16 kHz
    static let recordingCap: TimeInterval = 300        // app-side auto-stop
    static let zeroSampleCheck: TimeInterval = 2       // then one forceRestart, then 2 s more
    static let idleReleaseDefault: TimeInterval = 600
    /// Longest the idle release waits for in-flight transcriptions (≈ CPU fallback budget for a 300 s clip + slack).
    static let idleReleaseMaxDeferral: TimeInterval = 600
    /// A warm-cache model load that runs past this is really a compile (Core ML cache evicted, spec §5.2).
    static let slowLoadIsCompile: TimeInterval = 10
    /// Keyboard: a stop still unanswered (status `recording`) after this long is given up locally.
    static let stopUnanswered: TimeInterval = 5
    static func transcribeTimeout(audioSeconds: Double) -> TimeInterval { max(30, 10 + 0.3 * audioSeconds) }
    /// Extra budget once the CPU fallback has taken over (CPU large-v3 is several times slower than the ANE).
    static func cpuFallbackTimeout(audioSeconds: Double) -> TimeInterval { max(60, 20 + 1.5 * audioSeconds) }
}

enum Liveness {
    enum Verdict { case notActive, unproven, live, orphaned }
    static func evaluate(status: DictationStatus?, heartbeat: Double?, requestAt: Double?, now: Double) -> Verdict {
        guard let status, status.isActive else { return .notActive }
        let limit: TimeInterval
        switch status {
        case .recording: limit = Timing.livenessRecording
        case .transcribing: limit = Timing.livenessTranscribing
        default: return .unproven                       // never orphan `requested`
        }
        guard let heartbeat, heartbeat > 0 else { return .unproven }
        if let requestAt, heartbeat <= requestAt { return .unproven }   // corpse heartbeat from an older session (#261)
        return now - heartbeat > limit ? .orphaned : .live
    }
    static func appLooksWarm(session: SessionState?, heartbeat: Double?, now: Double) -> Bool {
        guard let session, session.isWarm, let heartbeat else { return false }
        return now - heartbeat < Timing.warmHeartbeatMaxAge
    }
    /// Reviewer minor (a): take the URL immediately only when the app is clearly not alive.
    static func shouldSkipDarwin(session: SessionState?, heartbeat: Double?, now: Double) -> Bool {
        guard let session, session != .dead, let heartbeat else { return true }
        return now - heartbeat > Timing.darwinSkipHeartbeatAge
    }
}

/// App-side timing of one dictation, handed to the keyboard with the transcript (v1 timing log).
struct AppTiming: Codable {
    var audioSeconds: Double
    var stopReceivedAt: Double      // epoch s, app received the stop (or cap / interruption)
    var asrDoneAt: Double           // epoch s
    var asrMs: Int                  // WhisperKit wall time, including any CPU retry
    var model: String
    var computePath: String         // "ane", "ane-bg", "cpu-fallback", "cpu-sticky"
    var fallback: Bool
}

/// Keyboard → app (`pw.lastResult`).
struct KeyboardResult: Codable {
    let requestId: String
    let text: String
    let cleaned: Bool
    let inserted: Bool
    let reason: String
    let at: Double
    var cleanupMs: Int?
    var stopToInsertMs: Int?
}

/// First 8 characters of a request id, for log lines.
func short(_ id: String?) -> String { id.map { String($0.prefix(8)) } ?? "nil" }

extension UserDefaults {
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func setCodable<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { set(data, forKey: key) } else { removeObject(forKey: key) }
    }
}
