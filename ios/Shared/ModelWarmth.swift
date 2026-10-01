// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/ModelWarmth.swift. MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import Foundation

/// "Is the Core ML specialisation cache warm for this install and this OS build?"
enum ModelWarmth {
    /// "<bundle-container-UUID>|<OS version+build>". Uses the FIRST ".app" component, so the keyboard at
    /// …/<uuid>/PrivateWhisper.app/PlugIns/PrivateWhisperKeyboard.appex computes the same value.
    static var identity: String? {
        let parts = Bundle.main.bundleURL.pathComponents
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }), i > 0 else { return nil }
        return "\(parts[i - 1])|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    static func isWarm(_ variant: String) -> Bool {
        guard let identity else { return true }
        return (AppGroup.defaults.dictionary(forKey: Keys.modelWarm) as? [String: String])?[variant] == identity
    }
    static func markWarm(_ variant: String) {
        guard let identity else { return }
        var m = AppGroup.defaults.dictionary(forKey: Keys.modelWarm) as? [String: String] ?? [:]
        m[variant] = identity
        AppGroup.defaults.set(m, forKey: Keys.modelWarm); AppGroup.defaults.synchronize()
    }
    static func clear(_ variant: String? = nil) {
        if let variant {
            var m = AppGroup.defaults.dictionary(forKey: Keys.modelWarm) as? [String: String] ?? [:]
            m[variant] = nil
            AppGroup.defaults.set(m, forKey: Keys.modelWarm)
        } else {
            AppGroup.defaults.removeObject(forKey: Keys.modelWarm)
        }
        AppGroup.defaults.synchronize()
    }
}
