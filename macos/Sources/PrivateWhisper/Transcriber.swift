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
    /// `vocabulary` biases recognition toward personal-dictionary terms.
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> TranscriptionResult
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
    /// Model load and whisper_full block for seconds — they run on this
    /// dedicated queue instead of pinning a cooperative-pool thread. The queue
    /// is serial, so the ctx is never used concurrently even across actor
    /// reentrancy.
    private let inferenceQueue = DispatchQueue(label: "PrivateWhisper.whisper", qos: .userInitiated)

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    /// Loads the model into memory (idempotent).
    func preload() async throws {
        guard ctx == nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriberError.modelNotFound(modelPath.path)
        }
        let path = modelPath.path
        let context: OpaquePointer? = await withCheckedContinuation { continuation in
            inferenceQueue.async {
                var cparams = whisper_context_default_params()
                cparams.use_gpu = true
                cparams.flash_attn = true
                continuation.resume(returning: whisper_init_from_file_with_params(path, cparams))
            }
        }
        guard let context else { throw TranscriberError.initFailed }
        ctx = context
    }

    /// Frees the whisper context (used at app termination; see PipelineController.shutdown).
    func unload() {
        if let ctx {
            inferenceQueue.sync { whisper_free(ctx) }
            self.ctx = nil
        }
    }

    func transcribe(samples: [Float], vocabulary: [String] = []) async throws -> TranscriptionResult {
        try await preload()
        guard let ctx else { throw TranscriberError.initFailed }

        // whisper conditions on the initial prompt as if it preceded the audio,
        // biasing recognition toward these spellings (cap to stay within n_ctx/2).
        let prompt = vocabulary.isEmpty ? nil : vocabulary.prefix(80).joined(separator: ", ")

        let outcome: (status: Int32, text: String, language: String) =
            await withCheckedContinuation { continuation in
                inferenceQueue.async {
                    continuation.resume(returning: Self.runInference(
                        ctx: ctx, samples: samples, prompt: prompt))
                }
            }
        guard outcome.status == 0 else { throw TranscriberError.inferenceFailed }

        return TranscriptionResult(
            text: Self.cleanRawTranscript(outcome.text), language: outcome.language)
    }

    private static func runInference(
        ctx: OpaquePointer, samples: [Float], prompt: String?
    ) -> (status: Int32, text: String, language: String) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false // hard requirement: never translate
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        let run: () -> Int32 = {
            "auto".withCString { lang -> Int32 in
                params.language = lang
                params.detect_language = false // transcribe with auto-detected language
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        let status: Int32
        if let prompt {
            status = prompt.withCString { p -> Int32 in
                params.initial_prompt = p
                return run()
            }
        } else {
            status = run()
        }
        guard status == 0 else { return (status, "", "unknown") }

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
        return (status, text, language)
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
