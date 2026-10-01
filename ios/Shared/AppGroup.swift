// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/AppGroup.swift, DictusCore/SharedKeys.swift. MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// Compiled into BOTH targets (app + keyboard). No UIApplication.shared here.
import Foundation

enum AppGroup {
    /// Never rename: a free-team group ID cannot move to a paid team later (spec §0, §11).
    static let id = "group.ch.simonschwarz.privatewhisper.ios"

    /// Falls back to `.standard` so an unsigned compile-check build does not crash (IPC will look broken there).
    static let defaults: UserDefaults = UserDefaults(suiteName: id) ?? .standard

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}

/// App Group keys (spec §3.1). Writers: see the protocol table.
enum Keys {
    static let status = "pw.status"
    static let session = "pw.session"
    static let heartbeat = "pw.heartbeat"
    static let requestId = "pw.requestId"
    static let requestAt = "pw.requestAt"
    static let stopRequested = "pw.stopRequested"
    static let stopRequestId = "pw.stopRequestId"          // reviewer: stop/cancel carry the requestId they target
    static let cancelRequested = "pw.cancelRequested"
    static let cancelRequestId = "pw.cancelRequestId"
    static let cancelByUser = "pw.cancelByUser"            // false: keyboard watchdog abandon (result still goes to History)
    static let level = "pw.level"
    static let elapsed = "pw.elapsed"
    static let coldStart = "pw.coldStart"
    static let transcript = "pw.transcript"
    static let transcriptRequestId = "pw.transcriptRequestId"
    static let transcriptLanguage = "pw.transcriptLanguage"
    static let transcriptDuration = "pw.transcriptDuration"
    static let transcriptAt = "pw.transcriptAt"
    static let transcriptAuto = "pw.transcriptAuto"        // false: late result, offer "Insert last" only
    static let transcriptTiming = "pw.transcriptTiming"    // JSON AppTiming
    static let error = "pw.error"
    static let lastResult = "pw.lastResult"
    static let modelState = "pw.model.state"
    static let modelProgress = "pw.model.progress"
    static let modelVariant = "pw.model.variant"
    static let modelWarm = "pw.model.warm"
    static let language = "pw.language"
    static let germanIsSwiss = "pw.germanIsSwiss"
    static let dictionary = "pw.dictionary"
    static let vocabBias = "pw.vocabBias"
    static let cleanupEnabled = "pw.cleanupEnabled"
    static let idleMinutes = "pw.idleMinutes"
    static let cpuFallbackVariant = "pw.cpuFallbackVariant"
    static let kbSeenAt = "pw.kbSeenAt"
    static let kbContainerOK = "pw.kbContainerOK"           // keyboard wrote: its containerURL was non-nil
    static let fmAvailability = "pw.fmAvailability"
    static let fmVariant = "pw.fmVariant"
    // Background compute diagnostics (written by the app, shown on the Diagnostics screen)
    static let diagCompute = "pw.diag.compute"             // JSON ComputeDiagnostics.State
}

/// Typed settings shared by both processes.
enum Settings {
    private static var d: UserDefaults { AppGroup.defaults }

    static var language: DictationLanguage {
        get { d.string(forKey: Keys.language).flatMap(DictationLanguage.init(rawValue:)) ?? .auto }
        set { d.set(newValue.rawValue, forKey: Keys.language); d.synchronize() }
    }
    static var germanIsSwiss: Bool {
        get { d.object(forKey: Keys.germanIsSwiss) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.germanIsSwiss) }
    }
    static var dictionary: [String] {
        get { d.stringArray(forKey: Keys.dictionary) ?? [] }
        set { d.set(newValue, forKey: Keys.dictionary) }
    }
    /// −1 means "never".
    static var idleMinutes: Int {
        get { d.object(forKey: Keys.idleMinutes) as? Int ?? 10 }
        set { d.set(newValue, forKey: Keys.idleMinutes) }
    }
    static var idleInterval: TimeInterval { idleMinutes < 0 ? .infinity : TimeInterval(idleMinutes * 60) }
    static var cleanupEnabled: Bool {
        get { d.object(forKey: Keys.cleanupEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.cleanupEnabled) }
    }
    static var vocabularyBias: Bool {
        get { d.object(forKey: Keys.vocabBias) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.vocabBias) }
    }
    /// The model used when the Neural Engine refuses a background request. `nil` = same variant, CPU only.
    static var cpuFallbackVariant: String? {
        get { d.string(forKey: Keys.cpuFallbackVariant).flatMap { $0.isEmpty ? nil : $0 } }
        set { d.set(newValue ?? "", forKey: Keys.cpuFallbackVariant) }
    }
    /// Same default in both processes (reviewer: the keyboard used to look up "" and never saw a warm model).
    static var modelVariant: String {
        get { d.string(forKey: Keys.modelVariant) ?? ModelCatalog.primary }
        set { d.set(newValue, forKey: Keys.modelVariant); d.synchronize() }
    }
}
