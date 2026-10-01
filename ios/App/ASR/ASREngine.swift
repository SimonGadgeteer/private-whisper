// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusApp/SpeechModelProtocol.swift (WhisperKitEngine), DictusApp/DictationCoordinator.swift (ensureWhisperKitEngineReady),
// DictusCore/WarmInference.swift, DictusApp/ModelManager.swift. MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// WhisperKit (argmax-oss-swift 1.1.0, MIT, (c) Argmax, Inc.) is linked into the app only.
//
// Compute paths (v1 self-diagnosis for R1):
//   "ane"          foreground, encoder/decoder on the Neural Engine
//   "ane-bg"       app in the background, Neural Engine accepted the request
//   "cpu-fallback" the ANE attempt failed (or returned nothing for real speech) → same utterance, CPU only
//   "cpu-sticky"   this process already saw the ANE refuse a background request → straight to CPU
//   "cpu-cold"     background with a cold Core ML cache → CPU (never a 20-min background ANE compile, #472)
@preconcurrency import WhisperKit
import CoreML
import UIKit

/// WhisperKit is not Sendable; one instance only ever runs one job at a time (FIFO below), on this actor's behalf.
final class KitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

@MainActor
final class ASREngine {
    struct Transcript {
        let text: String
        let language: DictationLanguage       // gsw kept distinct from de
        let model: String
        let computePath: String
        let asrMs: Int
        let fallback: Bool
    }
    enum ASRError: LocalizedError {
        case notInstalled(String)
        var errorDescription: String? {
            switch self { case .notInstalled(let v): return "Speech model \(ModelCatalog.displayName(v)) is not installed." }
        }
    }

    private(set) var inFallback = false

    var variant: String { Settings.modelVariant }

    static let base: URL = {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisperkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v)
        return u
    }()
    static func folder(_ variant: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }
    static func isInstalled(_ variant: String) -> Bool {
        ["AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/weights/weight.bin",
         "MelSpectrogram.mlmodelc", "config.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: folder(variant).appendingPathComponent($0).path) }
    }
    /// Mel on the CPU (0.4 MB; removes the only GPU model path, #268). Encoder/decoder on the ANE, or all CPU.
    static func compute(cpuOnly: Bool) -> ModelComputeOptions {
        cpuOnly ? ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
                : ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                      textDecoderCompute: .cpuAndNeuralEngine)
    }

    private var kit: WhisperKit?
    private var kitVariant: String?
    private var loading: Task<KitBox, Error>?
    private var loadingVariant: String?
    /// A load abandoned by unload(): Core ML cannot cancel it, so the next load waits for it (no overlapping compiles).
    private var retiring: Task<KitBox, Error>?
    private var cpuKit: WhisperKit?
    private var cpuKitVariant: String?
    private var tail: Task<Void, Never>?            // FIFO: one transcription at a time, never refuse (reviewer)
    private var stickyCPUInBackground = false

    var isLoaded: Bool { kit != nil && kitVariant == variant }
    var isLoading: Bool { loading != nil }
    var isInstalled: Bool { Self.isInstalled(variant) }
    var cpuKitLoaded: Bool { cpuKit != nil }

    // MARK: download / load

    func download(variant: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        ModelWarmth.clear(variant)
        let url = try await WhisperKit.download(variant: variant, downloadBase: Self.base, useBackgroundSession: true) {
            progress($0.fractionCompleted)
        }
        if url.standardizedFileURL != Self.folder(variant).standardizedFileURL {
            Log.error("asr", "download landed at \(url.path)")
        }
    }

    /// Coalesced: all callers await one load, so two Core ML compiles never overlap (E5 bundle crash).
    /// `requested` pins the variant (ModelSetup prepares the variant it was started for, not whatever is current now).
    /// The loaded instance is published only while it is still the selected variant.
    @discardableResult
    func load(_ requested: String? = nil) async throws -> WhisperKit {
        let v = requested ?? variant
        if let kit, kitVariant == v { return kit }
        if let loading, loadingVariant == v { return try await loading.value.kit }
        if (kit != nil && kitVariant != v) || loading != nil { unload() }
        if let r = retiring {
            Log.info("asr", "waiting for an abandoned load to finish before loading \(v)")
            _ = try? await r.value
            if retiring == r { retiring = nil }
            return try await load(v)                                   // other callers may have run meanwhile
        }
        guard Self.isInstalled(v) else { throw ASRError.notInstalled(v) }
        if cpuKitVariant == v && !inFallback {                         // never two resident copies of one model
            Log.info("asr", "dropping CPU-only \(v) before the ANE load")
            cpuKit = nil; cpuKitVariant = nil
        }
        let started = Date()
        Log.info("asr", "load \(v) (warm cache=\(ModelWarmth.isWarm(v))) mem=\(physFootprintMB())MB")
        let task = Task { () throws -> KitBox in
            let cfg = WhisperKitConfig(model: v, modelFolder: Self.folder(v).path, tokenizerFolder: Self.base,
                                       computeOptions: Self.compute(cpuOnly: false), verbose: false,
                                       prewarm: true, load: true, download: false)   // local only
            let k = try await WhisperKit(cfg)
            // The ANE specialises per shape at the FIRST inference (#426: 5.5 s → 1.3 s). Warm on 2 s of silence
            // BEFORE publishing; ≤ 1 s runs zero encoder passes. One instance never runs two transcribes (#144).
            _ = try? await withMLTensorComputePolicy(.cpuOnly) {
                try await k.transcribe(audioArray: [Float](repeating: 0, count: 32_000),
                    decodeOptions: DecodingOptions(language: "en", temperatureFallbackCount: 0, sampleLength: 16,
                                                   usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true))
            }
            return KitBox(k)
        }
        loading = task; loadingVariant = v
        defer { if loading == task { loading = nil; loadingVariant = nil } }
        do {
            let k = try await task.value.kit
            ModelWarmth.markWarm(v)                                    // the on-disk Core ML cache is valid either way
            if v == Settings.modelVariant {
                kit = k; kitVariant = v
            } else {
                Log.info("asr", "loaded \(v) but the selected variant is now \(Settings.modelVariant): not published")
            }
            Log.info("asr", "loaded \(v) in \(Int(Date().timeIntervalSince(started) * 1000))ms mem=\(physFootprintMB())MB")
            return k
        } catch {
            Log.error("asr", "load \(v) failed after \(Int(Date().timeIntervalSince(started)))s: \(Self.describe(error).prefix(300))")
            throw error
        }
    }

    /// Reviewer: switching the variant must drop the cached instance.
    func unload() {
        if kit != nil { Log.info("asr", "unload \(kitVariant ?? "?")") }
        if let l = loading { retiring = l }                            // WhisperKit(cfg) ignores cancellation
        loading = nil; loadingVariant = nil
        kit = nil; kitVariant = nil
    }

    /// Cleared on every foreground: a new background session gets a fresh ANE attempt.
    func resetBackgroundPolicy() {
        if stickyCPUInBackground { Log.info("asr", "sticky background CPU policy cleared") }
        stickyCPUInBackground = false
    }

    /// Fetches (or finds on disk) the tokenizer so the ~4 min compile never needs the network (spec §5.2 step 1).
    func prefetchTokenizer(_ v: String) async throws {
        let tv: ModelVariant = v == ModelCatalog.small ? .small : v == ModelCatalog.base ? .base : .largev3
        _ = try await ModelUtilities.loadTokenizer(for: tv, tokenizerFolder: Self.base, additionalSearchPaths: [Self.folder(v)])
    }

    func unloadCPU() {
        guard cpuKit != nil, !inFallback else { return }
        Log.info("asr", "unload CPU fallback \(cpuKitVariant ?? "?") mem=\(physFootprintMB())MB")
        cpuKit = nil; cpuKitVariant = nil
    }

    private func loadCPU(_ v: String) async throws -> WhisperKit {
        if let cpuKit, cpuKitVariant == v { return cpuKit }
        cpuKit = nil; cpuKitVariant = nil
        guard Self.isInstalled(v) else { throw ASRError.notInstalled(v) }
        if kitVariant == v {                                           // spec §5.6: never two resident large-v3 copies
            Log.info("asr", "CPU fallback uses \(v): dropping the ANE instance first (reloaded on the next foreground)")
            unload()
        }
        let started = Date()
        let cfg = WhisperKitConfig(model: v, modelFolder: Self.folder(v).path, tokenizerFolder: Self.base,
                                   computeOptions: Self.compute(cpuOnly: true), verbose: false,
                                   prewarm: false, load: true, download: false)
        let k = try await WhisperKit(cfg)
        cpuKit = k; cpuKitVariant = v
        Log.info("asr", "CPU-only \(v) loaded in \(Int(Date().timeIntervalSince(started) * 1000))ms mem=\(physFootprintMB())MB")
        return k
    }

    /// Foreground, online: one CPU load so the fallback model's tokenizer is fetched while the network is there.
    func primeCPUFallback(_ v: String) async throws {
        _ = try await loadCPU(v)
        unloadCPU()
    }

    // MARK: transcribe (serial)

    /// `onStart` fires when the job leaves the FIFO (queue time is not inference time); `onFallback` when THIS
    /// job's CPU-only retry starts.
    func transcribe(_ samples: [Float], language: DictationLanguage, germanIsSwiss: Bool, dictionary: [String],
                    onStart: (() -> Void)? = nil, onFallback: (() -> Void)? = nil) async throws -> Transcript {
        let previous = tail
        let job = Task { () async throws -> Transcript in
            await previous?.value
            onStart?()
            return try await self.run(samples, language: language, germanIsSwiss: germanIsSwiss, dictionary: dictionary,
                                      onFallback: onFallback)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    private func run(_ samples: [Float], language: DictationLanguage, germanIsSwiss: Bool,
                     dictionary: [String], onFallback: (() -> Void)?) async throws -> Transcript {
        let background = UIApplication.shared.applicationState != .active
        let audioSeconds = Double(samples.count) / 16_000
        let v = variant
        let started = Date()

        if background && stickyCPUInBackground {
            Log.info("asr", "background: ANE already refused in this process → CPU directly")
            return try await runCPU(samples, language, germanIsSwiss, dictionary, trigger: "sticky", error: "",
                                    aneMs: 0, started: started, path: "cpu-sticky", onFallback: onFallback)
        }
        if background && !isLoaded && !ModelWarmth.isWarm(v) {
            Log.error("asr", "background with a cold Core ML cache for \(v): not compiling on the ANE in the background")
            return try await runCPU(samples, language, germanIsSwiss, dictionary, trigger: "coldCacheInBackground",
                                    error: "", aneMs: 0, started: started, path: "cpu-cold", onFallback: onFallback)
        }

        do {
            let k = try await load()
            let asrStart = Date()
            let (text, code) = try await decode(k, samples, language, dictionary)
            let asrMs = ms(since: asrStart)
            let rtf = audioSeconds / max(Double(asrMs) / 1000, 0.001)
            if background && text.isEmpty && Self.hasSpeechEnergy(samples) {
                // Possible silent ANE failure: a refused request can surface as an empty decode rather than a throw.
                Log.error("asr", "background ANE returned EMPTY for \(String(format: "%.1f", audioSeconds))s of speech-level audio → CPU retry")
                ComputeDiagnostics.update { $0.suspiciousEmpty += 1 }
                return try await runCPU(samples, language, germanIsSwiss, dictionary, trigger: "emptyOnANE", error: "",
                                        aneMs: asrMs, started: started, path: "cpu-fallback", onFallback: onFallback)
            }
            let fg = ComputeDiagnostics.state.fgRTF
            ComputeDiagnostics.update { s in
                s.lastPath = background ? "ane-bg" : "ane"; s.lastAt = Date().timeIntervalSince1970; s.lastBackground = background
                if background { s.bgAneOK += 1; s.lastBgRTF = rtf } else {
                    s.fgAneOK += 1
                    if audioSeconds >= 2 { s.fgRTF = s.fgRTF.map { 0.7 * $0 + 0.3 * rtf } ?? rtf }
                }
            }
            if background {
                stickyCPUInBackground = false
                Log.info("asr", "background ANE OK: \(asrMs)ms for \(String(format: "%.1f", audioSeconds))s rtf=\(String(format: "%.1f", rtf))x fg-rtf=\(fg.map { String(format: "%.1f", $0) } ?? "–") model=\(v) mem=\(physFootprintMB())MB")
                if let fg, audioSeconds >= 3, rtf < fg / 3 {
                    Log.error("asr", "background run is >3x slower than foreground: suspected silent CPU fallback inside Core ML")
                    ComputeDiagnostics.update { $0.suspectedSilentCPU += 1 }
                }
            } else {
                Log.info("asr", "foreground ANE OK: \(asrMs)ms for \(String(format: "%.1f", audioSeconds))s rtf=\(String(format: "%.1f", rtf))x")
            }
            return Transcript(text: text, language: Self.resolveLanguage(language, code, germanIsSwiss), model: v,
                              computePath: background ? "ane-bg" : "ane", asrMs: ms(since: started), fallback: false)
        } catch {
            if error is CancellationError || error is ASRError { throw error }
            let desc = Self.describe(error)
            let aneLike = Self.looksLikeANEFailure(desc)
            let aneMs = ms(since: started)
            Log.error("asr", "ANE path failed after \(aneMs)ms (background=\(background) aneSignature=\(aneLike)): \(desc.prefix(400))")
            guard background || aneLike else { throw error }
            if background {
                ComputeDiagnostics.update { $0.bgAneFail += 1 }
                if aneLike {                                           // only a real ANE refusal makes CPU sticky
                    stickyCPUInBackground = true
                    ComputeDiagnostics.update { $0.stickyCPUSince = Date().timeIntervalSince1970 }
                }
            }
            return try await runCPU(samples, language, germanIsSwiss, dictionary,
                                    trigger: background ? "aneError" : "aneErrorForeground", error: desc,
                                    aneMs: aneMs, started: started, path: "cpu-fallback", onFallback: onFallback)
        }
    }

    /// Same utterance, CPU-only compute units, optionally a smaller model (Settings › CPU fallback model).
    private func runCPU(_ samples: [Float], _ language: DictationLanguage, _ germanIsSwiss: Bool, _ dictionary: [String],
                        trigger: String, error: String, aneMs: Int, started: Date, path: String,
                        onFallback: (() -> Void)?) async throws -> Transcript {
        let audioSeconds = Double(samples.count) / 16_000
        var v = variant
        if let preferred = Settings.cpuFallbackVariant {
            if Self.isInstalled(preferred) { v = preferred }
            else { Log.error("asr", "CPU fallback model \(preferred) not installed; using \(v) on CPU") }
        }
        inFallback = true
        onFallback?()
        defer { inFallback = false }
        let cpuStart = Date()
        Log.info("asr", "CPU fallback start trigger=\(trigger) model=\(v) audio=\(String(format: "%.1f", audioSeconds))s mem=\(physFootprintMB())MB")
        var record = ComputeDiagnostics.Fallback(at: Date().timeIntervalSince1970, trigger: trigger,
                                                 error: String(error.prefix(240)), aneMs: aneMs, cpuMs: 0,
                                                 cpuModel: v, audioSeconds: audioSeconds, succeeded: false)
        do {
            let k = try await loadCPU(v)
            let (text, code) = try await decode(k, samples, language, dictionary)
            record.cpuMs = ms(since: cpuStart); record.succeeded = true
            let rec = record
            ComputeDiagnostics.update { s in
                s.cpuFallbackOK += 1; s.lastFallback = rec
                s.lastPath = path; s.lastAt = Date().timeIntervalSince1970
                s.lastBackground = UIApplication.shared.applicationState != .active
            }
            Log.info("asr", "CPU fallback OK trigger=\(trigger) model=\(v) cpu=\(record.cpuMs)ms ane-attempt=\(aneMs)ms rtf=\(String(format: "%.2f", audioSeconds / max(Double(record.cpuMs) / 1000, 0.001)))x empty=\(text.isEmpty) mem=\(physFootprintMB())MB")
            return Transcript(text: text, language: Self.resolveLanguage(language, code, germanIsSwiss), model: v,
                              computePath: path, asrMs: ms(since: started), fallback: true)
        } catch {
            record.cpuMs = ms(since: cpuStart)
            let rec = record
            ComputeDiagnostics.update { $0.cpuFallbackFail += 1; $0.lastFallback = rec; $0.lastPath = "\(path)-failed" }
            Log.error("asr", "CPU fallback FAILED after \(record.cpuMs)ms: \(Self.describe(error).prefix(300))")
            throw error
        }
    }

    private func decode(_ k: WhisperKit, _ samples: [Float], _ language: DictationLanguage,
                        _ dictionary: [String]) async throws -> (String, String?) {
        // Reviewer: GreedyTokenSampler uses MLTensor under the default policy, which may pick the GPU —
        // closed to backgrounded apps. Task-local, so it also covers WhisperKit's TaskGroup children.
        try await withMLTensorComputePolicy(.cpuOnly) {
            var code = language.whisperCode                              // gsw → "de": Swiss speech → Standard German text
            if code == nil, let detected = try? await k.detectLangauge(audioArray: samples).language {  // sic: WhisperKit spelling
                code = ["en", "de", "fr"].contains(detected) ? detected : "de"
            }
            // `detectLanguage` must be explicit: it defaults to !usePrefillPrompt, and nil+prefill silently forces <|en|>.
            var options = DecodingOptions(task: .transcribe, language: code, temperature: 0,
                                          usePrefillPrompt: true, detectLanguage: code == nil, skipSpecialTokens: true,
                                          promptTokens: Settings.vocabularyBias ? Self.promptTokens(dictionary, k.tokenizer) : nil,
                                          concurrentWorkerCount: 1,            // reviewer: predictable peak memory
                                          chunkingStrategy: .vad)
            options.clipTimestamps = []
            // Chunk here, not inside WhisperKit: its multi-window path logs and DROPS a failed chunk instead of
            // throwing, which would skip the CPU fallback and delete the pending audio. One window per call → throws.
            let win = k.featureExtractor.windowSamples ?? 480_000
            let chunks: [AudioChunk] = samples.count > win
                ? try await VADAudioChunker(vad: k.voiceActivityDetector ?? EnergyVAD())
                    .chunkAll(audioArray: samples, maxChunkLength: win, decodeOptions: options)
                : [AudioChunk(seekOffsetIndex: 0, audioSamples: samples)]
            var parts: [String] = []
            for c in chunks {
                try Task.checkCancellation()
                parts += try await k.transcribe(audioArray: c.audioSamples, decodeOptions: options).map(\.text)
            }
            var text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSilenceHallucination(text) { text = "" }
            return (text, code)
        }
    }

    // MARK: helpers

    private func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }

    static func resolveLanguage(_ language: DictationLanguage, _ code: String?, _ germanIsSwiss: Bool) -> DictationLanguage {
        switch (language, code) {
        case (.gsw, _): return .gsw
        case (.auto, "de"): return germanIsSwiss ? .gsw : .de
        default: return DictationLanguage(rawValue: code ?? "de") ?? .de
        }
    }

    /// WhisperKit's prompt and output share one 224-token context: a long prompt cuts the end off every 30 s
    /// window. Whole terms up to ~44 tokens leave ~175 for text + timestamps; TextPost/FM cover the rest.
    static let promptTokenBudget = 44
    private static func promptTokens(_ dictionary: [String], _ tokenizer: WhisperTokenizer?) -> [Int]? {
        guard !dictionary.isEmpty, let tok = tokenizer else { return nil }
        var ids: [Int] = []
        var used = 0
        for term in dictionary {
            let t = tok.encode(text: (ids.isEmpty ? " " : ", ") + term).filter { $0 < tok.specialTokens.specialTokenBegin }
            if ids.count + t.count > promptTokenBudget { break }
            ids += t; used += 1
        }
        if used < dictionary.count {
            Log.info("asr", "vocab prompt trimmed: \(used)/\(dictionary.count) terms, \(ids.count) tokens")
        }
        return ids.isEmpty ? nil : ids
    }

    private static let silencePhrases = ["untertitel im auftrag des zdf", "untertitel der amara.org-community",
        "sous-titres realises par la communaute d'amara.org", "thank you for watching", "vielen dank furs zuschauen"]
    static func isSilenceHallucination(_ t: String) -> Bool {
        let f = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return silencePhrases.contains { f == $0 || (f.contains($0) && f.count < $0.count + 12) }
    }

    /// At least 0.5 s of 30 ms frames above a speech-ish RMS: an empty decode here is suspicious.
    static func hasSpeechEnergy(_ samples: [Float]) -> Bool {
        let frame = 480
        var loud = 0
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if sqrt(sum / Float(frame)) > 0.02 { loud += 1; if loud >= 17 { return true } }
            i += frame
        }
        return false
    }

    /// Full error text including NSError domain/code and underlying errors (Core ML nests the ANE failure).
    static func describe(_ error: Error) -> String {
        var parts = [String(describing: error)]
        var ns: NSError? = error as NSError
        var depth = 0
        while let e = ns, depth < 4 {
            parts.append("\(e.domain) Code=\(e.code) \(e.localizedDescription)")
            ns = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " | ")
    }

    private static let aneSignatures = ["aneprogramprocessrequestdirect", "unable to compute the prediction", "e5rt",
                                        "e5 bundle", "code=8", "neural engine", "_ane", "anecompiler", "aneservices",
                                        "isentitledtorunbackgroundinference", "blocking inference", "notpermitted"]
    static func looksLikeANEFailure(_ description: String) -> Bool {
        let l = description.lowercased()
        return aneSignatures.contains { l.contains($0) } || l.range(of: #"\be5\b"#, options: .regularExpression) != nil
    }
}
