import AppKit
import Foundation

/// Orchestrates key press → record → transcribe → cleanup → inject.
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

    init(configStore: ConfigStore, statusItem: StatusItemController, hud: HUDController) {
        self.configStore = configStore
        self.statusItem = statusItem
        self.hud = hud
        let path = configStore.config.whisperModelPath
        self.transcriber = WhisperCppTranscriber(modelPath: path)
        self.loadedModelPath = path
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

    func hotkeyPressed() {
        // Only .recording and .processing block a new dictation; transient
        // states (.injected, .warning) must never lock out the hotkey.
        switch statusItem.state {
        case .recording:
            return
        case .processing:
            hud.flash("Still processing…")
            return
        case .idle, .injected, .warning:
            break
        }
        do {
            try recorder.start(deviceUID: configStore.config.microphoneUID)
            statusItem.setState(.recording)
            dlog("Recording started")
        } catch {
            statusItem.setState(.warning("Microphone unavailable"))
            hud.flash("Could not start recording: \(error.localizedDescription)", seconds: 3)
        }
    }

    func hotkeyReleased() {
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
        let transcriber = currentTranscriber()

        Task {
            do {
                let tStart = Date()
                let result = try await transcriber.transcribe(samples: samples)
                let transcriptionSeconds = Date().timeIntervalSince(tStart)

                guard !result.text.isEmpty else {
                    statusItem.setState(.idle)
                    hud.flash("Nothing heard")
                    return
                }

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
                            transcript: result.text, language: result.language)
                        cleanupSeconds = Date().timeIntervalSince(cStart)
                    } catch {
                        // PRD §4.1-C: never lose the dictation — fall back to raw.
                        fellBack = true
                        dlog("Cleanup failed, using raw transcript: \(error.localizedDescription)")
                    }
                }

                deliver(finalText, fellBack: fellBack)

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
            } catch {
                statusItem.setState(.warning("Transcription failed"))
                hud.flash("Transcription failed: \(error.localizedDescription)", seconds: 4)
            }
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

    private func deliver(_ text: String, fellBack: Bool) {
        statusItem.lastDictation = text
        switch TextInjector.inject(text) {
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
    }
}
