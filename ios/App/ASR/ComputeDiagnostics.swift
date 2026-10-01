// Self-diagnosis for the reviewer's BLOCKER (R1): does WhisperKit get the Neural Engine while the app is in the
// background on iOS 27 (free team, no Background Inference entitlement)? Every transcription records its compute
// path here; the Diagnostics screen shows it, and every event is also a line in pw.log.
import Foundation

@MainActor
enum ComputeDiagnostics {
    struct Fallback: Codable {
        var at: Double
        var trigger: String          // "aneError", "emptyOnANE", "sticky", "coldCacheInBackground", "aneErrorForeground"
        var error: String            // first 240 chars of the ANE-side error ("" when none)
        var aneMs: Int               // time spent on the failed ANE attempt
        var cpuMs: Int               // CPU-only retry wall time
        var cpuModel: String
        var audioSeconds: Double
        var succeeded: Bool
    }
    struct State: Codable {
        var lastPath: String = "–"
        var lastAt: Double = 0
        var lastBackground = false
        var bgAneOK = 0
        var bgAneFail = 0
        var fgAneOK = 0
        var cpuFallbackOK = 0
        var cpuFallbackFail = 0
        var suspiciousEmpty = 0
        var suspectedSilentCPU = 0
        var fgRTF: Double?           // exponential moving average, foreground (x real time)
        var lastBgRTF: Double?
        var lastFallback: Fallback?
        var stickyCPUSince: Double?  // this process saw the ANE refuse a background request
    }

    static var state: State {
        get { AppGroup.defaults.codable(State.self, forKey: Keys.diagCompute) ?? State() }
        set { AppGroup.defaults.setCodable(newValue, forKey: Keys.diagCompute) }
    }

    static func update(_ body: (inout State) -> Void) {
        var s = state
        body(&s)
        state = s
    }

    static func reset() { AppGroup.defaults.removeObject(forKey: Keys.diagCompute) }

    /// Human summary for the Diagnostics screen.
    static var headline: String {
        let s = state
        if s.bgAneFail > 0 || s.cpuFallbackOK + s.cpuFallbackFail > 0 {
            return "Neural Engine refused in background \(s.bgAneFail)× · CPU fallback used \(s.cpuFallbackOK + s.cpuFallbackFail)×"
        }
        if s.bgAneOK > 0 { return "Background Neural Engine OK (\(s.bgAneOK)×)" }
        return "No background transcription measured yet"
    }
}
