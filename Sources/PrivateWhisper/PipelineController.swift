import AppKit
import Foundation

/// Orchestrates key press → record → transcribe → cleanup → inject, plus
/// command mode (voice-edit the current selection).
///
/// Re-trigger policy (PRD §7.7): a new dictation started while the previous
/// one is still processing is REJECTED with a brief flash. Queuing would risk
/// injecting stale text into whatever app gained focus later.
@MainActor
final class PipelineController {
    private let configStore: ConfigStore
    private let statusItem: StatusItemController
    private let hud: HUDController
    private let recorder = AudioRecorder()

    private var transcriber: WhisperCppTranscriber
    private var loadedModelPath: URL

    /// What the current recording is for.
    private enum SessionKind {
        case dictation(toneHint: String?)
        case command(selection: String)
    }
    private var sessionKind: SessionKind = .dictation(toneHint: nil)

    /// Live mic RMS while recording, delivered on the main thread.
    var onAudioLevel: ((Float) -> Void)?
    /// Set by AppDelegate; watches injected fields for manual corrections.
    var correctionLearner: CorrectionLearner?

    init(configStore: ConfigStore, statusItem: StatusItemController, hud: HUDController) {
        self.configStore = configStore
        self.statusItem = statusItem
        self.hud = hud
        let path = configStore.config.whisperModelPath
        self.transcriber = WhisperCppTranscriber(modelPath: path)
        self.loadedModelPath = path
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.onAudioLevel?(level) }
        }
    }

    /// Loads the whisper model in the background so the first dictation is fast.
    func preloadModel() {
        let transcriber = currentTranscriber()
        Task.detached(priority: .userInitiated) {
            do {
                try await transcriber.preload()
            } catch {
                await MainActor.run {
                    // Don't clobber an in-flight recording state; the failure
                    // will surface when the transcription itself errors.
                    guard self.statusItem.state != .recording else { return }
                    self.statusItem.setState(.warning("Whisper model failed to load"))
                    self.hud.flash("Whisper model failed to load: \(error.localizedDescription)", seconds: 4)
                }
            }
        }
    }

    /// Swaps the transcriber when the model setting changed.
    private func currentTranscriber() -> WhisperCppTranscriber {
        let path = configStore.config.whisperModelPath
        if path != loadedModelPath {
            transcriber = WhisperCppTranscriber(modelPath: path)
            loadedModelPath = path
        }
        return transcriber
    }

    /// Only .recording and .processing block a new session; transient states
    /// (.injected, .warning) must never lock out the hotkey.
    private func canStartSession() -> Bool {
        switch statusItem.state {
        case .recording:
            return false
        case .processing:
            hud.flash("Still processing…")
            return false
        case .idle, .injected, .warning:
            return true
        }
    }

    private func startRecording() {
        do {
            try recorder.start(deviceUID: configStore.config.microphoneUID)
            statusItem.setState(.recording)
            dlog("Recording started")
        } catch {
            statusItem.setState(.warning("Microphone unavailable"))
            hud.flash("Could not start recording: \(error.localizedDescription)", seconds: 3)
        }
    }

    // MARK: - Dictation

    func hotkeyPressed() {
        guard canStartSession() else { return }
        // Capture the target app now — focus can change during processing.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let toneHint = bundleID.flatMap { configStore.config.appTones[$0] }
        sessionKind = .dictation(toneHint: toneHint)
        startRecording()
    }

    func hotkeyReleased() {
        finishRecording()
    }

    // MARK: - Command mode

    func commandPressed() {
        guard configStore.config.commandHotkey != nil, canStartSession() else { return }
        Task {
            guard let selection = await SelectionCapture.selectedText() else {
                hud.flash("Command mode: select some text first", seconds: 2)
                return
            }
            // Re-check: the async selection capture takes ~100ms and the user
            // may have released the key already — HotkeyMonitor still fires
            // onRelease, which no-ops if we never started recording.
            guard canStartSession() else { return }
            sessionKind = .command(selection: selection)
            startRecording()
        }
    }

    func commandReleased() {
        finishRecording()
    }

    // MARK: - Shared pipeline

    private func finishRecording() {
        // Keyed off the recorder, not the UI state: even if something clobbered
        // the .recording state, the mic must never be left running.
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        let audioSeconds = Double(samples.count) / 16000.0
        dlog(String(format: "Recording stopped: %.2fs audio, rms=%.4f", audioSeconds, samples.rmsLevel))

        // PRD §7.4: discard empty/near-silent recordings.
        guard AudioGate.passes(samples) else {
            statusItem.setState(.idle)
            hud.flash("Nothing heard")
            return
        }

        statusItem.setState(.processing)
        let config = configStore.config
        let kind = sessionKind
        let transcriber = currentTranscriber()

        Task {
            do {
                let tStart = Date()
                let result = try await transcriber.transcribe(
                    samples: samples, vocabulary: config.dictionary)
                let transcriptionSeconds = Date().timeIntervalSince(tStart)

                guard !result.text.isEmpty else {
                    statusItem.setState(.idle)
                    hud.flash("Nothing heard")
                    return
                }

                switch kind {
                case .dictation(let toneHint):
                    await finishDictation(
                        result: result, config: config, toneHint: toneHint,
                        audioSeconds: audioSeconds, transcriptionSeconds: transcriptionSeconds)
                case .command(let selection):
                    await finishCommand(instruction: result.text, selection: selection, config: config)
                }
            } catch {
                statusItem.setState(.warning("Transcription failed"))
                hud.flash("Transcription failed: \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    private func finishDictation(
        result: TranscriptionResult, config: AppConfig, toneHint: String?,
        audioSeconds: Double, transcriptionSeconds: Double
    ) async {
        var finalText = result.text
        var cleanupSeconds: Double?
        var fellBack = false

        if config.cleanupEnabled {
            let cleanup = CleanupService(
                baseURL: config.lmStudioURL,
                model: config.cleanupModel,
                timeout: config.cleanupTimeoutSeconds)
            let cStart = Date()
            do {
                finalText = try await cleanup.cleanup(
                    transcript: result.text, language: result.language,
                    glossary: config.dictionary, toneHint: toneHint)
                cleanupSeconds = Date().timeIntervalSince(cStart)
            } catch {
                // PRD §4.1-C: never lose the dictation — fall back to raw.
                fellBack = true
                dlog("Cleanup failed, using raw transcript: \(error.localizedDescription)")
            }
        }

        let delivery = deliver(finalText, fellBack: fellBack)
        if case .injected = delivery {
            correctionLearner?.watch(injected: finalText)
        }

        StatsStore.shared.record(
            words: finalText.split(whereSeparator: \.isWhitespace).count,
            language: result.language,
            audioSeconds: audioSeconds,
            transcriptionSeconds: transcriptionSeconds,
            cleanupSeconds: cleanupSeconds,
            fellBack: fellBack)

        if config.historyLoggingEnabled {
            HistoryLogger.append(.init(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                language: result.language,
                rawTranscript: result.text,
                cleanedText: fellBack || !config.cleanupEnabled ? nil : finalText,
                audioSeconds: audioSeconds,
                transcriptionSeconds: transcriptionSeconds,
                cleanupSeconds: cleanupSeconds))
        }
    }

    private func finishCommand(instruction: String, selection: String, config: AppConfig) async {
        // Command mode has no raw fallback that makes sense — the LLM *is* the
        // feature. Longer timeout: rewrites scale with selection length.
        let cleanup = CleanupService(
            baseURL: config.lmStudioURL,
            model: config.cleanupModel,
            timeout: max(30, config.cleanupTimeoutSeconds * 2))
        do {
            dlog("Command mode: \"\(instruction.prefix(60))\" on \(selection.count) chars")
            let rewritten = try await cleanup.rewrite(selection: selection, instruction: instruction)
            _ = deliver(rewritten, fellBack: false)
        } catch {
            statusItem.setState(.warning("Command mode failed"))
            hud.flash("Command mode failed: \(error.localizedDescription)", seconds: 4)
        }
    }

    /// Frees the whisper Metal context before process exit — ggml's static
    /// destructors abort if the context is still alive at that point.
    func shutdown() {
        let transcriber = self.transcriber
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await transcriber.unload()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }

    @discardableResult
    private func deliver(_ text: String, fellBack: Bool) -> InjectionOutcome {
        statusItem.lastDictation = text
        let outcome = TextInjector.inject(text)
        switch outcome {
        case .injected:
            dlog("Injected \(text.count) chars")
            statusItem.setState(
                fellBack ? .warning("Inserted raw transcript (cleanup offline)") : .injected)
        case .needsHUD(let reason):
            dlog("Injection fell back to HUD: \(reason)")
            statusItem.setState(
                fellBack ? .warning("Cleanup offline — raw transcript shown") : .idle)
            hud.showText(text, reason: reason)
        }
        return outcome
    }
}
