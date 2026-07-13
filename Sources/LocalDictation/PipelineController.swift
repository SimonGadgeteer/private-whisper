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
    private var recordingStartedAt: Date?

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
        guard statusItem.state == .idle || statusItem.state == .injected else {
            if statusItem.state == .processing { hud.flash("Still processing…") }
            return
        }
        do {
            try recorder.start(deviceUID: configStore.config.microphoneUID)
            recordingStartedAt = Date()
            statusItem.setState(.recording)
        } catch {
            statusItem.setState(.warning("Microphone unavailable"))
            hud.flash("Could not start recording: \(error.localizedDescription)", seconds: 3)
        }
    }

    func hotkeyReleased() {
        guard statusItem.state == .recording else { return }
        let samples = recorder.stop()
        let audioSeconds = Double(samples.count) / 16000.0

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
                        NSLog("Cleanup failed, using raw transcript: \(error.localizedDescription)")
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

    private func deliver(_ text: String, fellBack: Bool) {
        switch TextInjector.inject(text) {
        case .injected:
            statusItem.setState(
                fellBack ? .warning("Inserted raw transcript (cleanup offline)") : .injected)
        case .needsHUD(let reason):
            statusItem.setState(
                fellBack ? .warning("Cleanup offline — raw transcript shown") : .idle)
            hud.showText(text, reason: reason)
        }
    }
}
