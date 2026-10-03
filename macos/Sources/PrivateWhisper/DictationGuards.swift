import CoreGraphics
import Foundation

/// Push-to-talk on a modifier key, as a pure state machine (NSEvent plumbing lives in HotkeyMonitor).
///
/// A press becomes a dictation only after the key has been held for the hold delay with nothing else
/// pressed. On Swiss layouts Option+G is "@" and Option+7 is "|", so any other key or mouse button
/// while the modifier is down means "key combination": the press is ignored, and a recording that
/// already started is cancelled and discarded.
struct HoldGesture {
    enum Phase: Equatable { case up, pending, active, combination }
    enum Action: Equatable { case none, scheduleActivation, cancelScheduled, start, stop, cancel }

    private(set) var phase: Phase = .up

    mutating func keyDown() -> Action {
        guard phase == .up else { return .none }
        phase = .pending
        return .scheduleActivation
    }

    mutating func holdDelayElapsed() -> Action {
        guard phase == .pending else { return .none }
        phase = .active
        return .start
    }

    mutating func keyUp() -> Action {
        let was = phase
        phase = .up
        switch was {
        case .active: return .stop
        case .pending: return .cancelScheduled          // a quick tap: nothing happens
        case .up, .combination: return .none
        }
    }

    /// Another key, modifier or mouse button went down while the push-to-talk key is held.
    /// A lone modifier (Shift, Control) during an ongoing dictation is tolerated.
    mutating func otherInput(modifierOnly: Bool) -> Action {
        switch phase {
        case .pending:
            phase = .combination
            return .cancelScheduled
        case .active where !modifierOnly:
            phase = .combination
            return .cancel
        default:
            return .none
        }
    }
}

/// Speech presence for push-to-talk clips (16 kHz mono).
///
/// The old gate averaged loudness over the whole clip, so the click of a keystroke lifted a silent
/// 0.7 s clip over the threshold; Whisper then echoed its prompt (the personal dictionary) and that
/// text was typed. This counts 30 ms frames that are clearly louder than the clip's own background;
/// a keystroke spans one or two frames, a short word ("Ja") about eight.
enum VoiceActivity {
    static let frameSeconds = 0.03
    static let minVoicedSeconds = 0.15

    static func voicedSeconds(_ samples: [Float], sampleRate: Double = 16000) -> Double {
        let frame = Int(sampleRate * frameSeconds)
        guard frame > 0, samples.count >= frame else { return 0 }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        let background = levels.sorted()[levels.count / 5]          // 20th percentile
        // Floor for very quiet rooms; cap so a clip that is speech almost end to end (its 20th
        // percentile is already voice) can still pass.
        let threshold = max(Float(0.006), min(background * 3, Float(0.02)))
        return Double(levels.filter { $0 > threshold }.count) * frameSeconds
    }
}

/// Whisper repeats its prompt (we pass the personal dictionary) when it hears no real speech.
enum PromptEcho {
    /// True when the transcript is made only of dictionary words and contains at least two distinct
    /// dictionary terms. A single dictated name ("Küenzi") is still accepted.
    static func isEcho(_ text: String, vocabulary: [String]) -> Bool {
        let words = tokens(text)
        let vocabularyWords = Set(vocabulary.flatMap(tokens))
        guard !words.isEmpty, !vocabularyWords.isEmpty,
              words.allSatisfy(vocabularyWords.contains) else { return false }
        let present = Set(words)
        let termsPresent = vocabulary.filter { term in
            let t = tokens(term)
            return !t.isEmpty && t.allSatisfy(present.contains)
        }
        return termsPresent.count >= 2
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }
}

/// Marks keystrokes the app posts itself (Cmd+V to paste, Cmd+C to read the selection) so the
/// push-to-talk monitor does not mistake them for the user typing a key combination.
enum SyntheticKeys {
    static let marker: Int64 = 0x5057_4B45

    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isOwn(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == marker
    }
}
