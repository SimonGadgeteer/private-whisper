import Foundation
import whisper

/// Shared gate for discarding empty/near-silent recordings (PRD §7.4).
/// Whisper hallucinates ("you", "Thank you.") on silence, and its
/// no_speech_prob is unreliable there — energy gating is the real defense.
enum AudioGate {
    static let minSeconds = 0.5
    static let minRMS: Float = 0.002

    static func passes(_ samples: [Float]) -> Bool {
        Double(samples.count) / 16000.0 >= minSeconds && samples.rmsLevel > minRMS
    }
}

struct TranscriptionResult {
    let text: String
    /// ISO 639-1 code as detected by whisper, e.g. "en", "de", "fr".
    let language: String
}

protocol Transcriber {
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
}

enum TranscriberError: Error, LocalizedError {
    case modelNotFound(String)
    case initFailed
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Whisper model not found at \(path)"
        case .initFailed: return "Failed to initialize whisper context"
        case .inferenceFailed: return "Whisper inference failed"
        }
    }
}

/// whisper.cpp (Metal) embedded in-process. The model stays loaded between
/// dictations; loading happens once on first use or at app start.
actor WhisperCppTranscriber: Transcriber {
    private var ctx: OpaquePointer?
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    /// Loads the model into memory (idempotent).
    func preload() throws {
        guard ctx == nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriberError.modelNotFound(modelPath.path)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath.path, cparams) else {
            throw TranscriberError.initFailed
        }
        ctx = context
    }

    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try preload()
        guard let ctx else { throw TranscriberError.initFailed }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false // hard requirement: never translate
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        let status = "auto".withCString { lang -> Int32 in
            params.language = lang
            params.detect_language = false // transcribe with auto-detected language
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        guard status == 0 else { throw TranscriberError.inferenceFailed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            // Whisper hallucinates fragments like "you"/"Thank you." on
            // near-silence; those segments carry a high no-speech probability.
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
            if ProcessInfo.processInfo.environment["LD_DEBUG"] != nil,
               let seg = whisper_full_get_segment_text(ctx, i) {
                FileHandle.standardError.write(Data(
                    "segment \(i): no_speech=\(noSpeechProb) text=\(String(cString: seg))\n".utf8))
            }
            guard noSpeechProb < 0.6 else { continue }
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }

        let langID = whisper_full_lang_id(ctx)
        let language = langID >= 0 ? String(cString: whisper_lang_str(langID)) : "unknown"

        return TranscriptionResult(text: Self.cleanRawTranscript(text), language: language)
    }

    /// Removes whisper artifacts like "[BLANK_AUDIO]", "(wind blowing)" and
    /// trims whitespace. Returns "" when nothing meaningful was heard.
    static func cleanRawTranscript(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"♪[^♪]*♪"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only punctuation left → treat as silence.
        if text.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) {
            return ""
        }
        return text
    }
}
