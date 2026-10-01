import SwiftUI
import AVFoundation
import FoundationModels

/// First-run checklist and, with `prepareOnly`, the model preparation screen (pwhisper://prepare, cold Core ML cache).
struct OnboardingView: View {
    let prepareOnly: Bool
    @ObservedObject private var setup = ModelSetup.shared
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var kbSeen = AppGroup.defaults.object(forKey: Keys.kbSeenAt) != nil
    @State private var tryText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !prepareOnly { micStep }
            modelStep
            if !prepareOnly {
                keyboardStep
                intelligenceStep
                Section("5 · Try it") {
                    TextEditor(text: $tryText).frame(minHeight: 90)
                    Text("Tap here, switch to Private Whisper with the globe key, and tap the microphone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(prepareOnly ? "Prepare speech model" : "Setup")
        .toolbar { if prepareOnly { Button("Close") { dismiss() } } }
        .onAppear {
            refresh()
            if prepareOnly, ASREngine.isInstalled(Settings.modelVariant), !ModelWarmth.isWarm(Settings.modelVariant) {
                setup.prepare()                                // foreground compile starts (or is re-joined) here
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        mic = AVAudioApplication.shared.recordPermission
        kbSeen = AppGroup.defaults.object(forKey: Keys.kbSeenAt) != nil
    }

    private var micStep: some View {
        Section("1 · Microphone") {
            switch mic {
            case .granted: Label("Microphone allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Button("Open Settings to allow the microphone") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
            default:
                Button("Allow microphone") {
                    Task {
                        _ = await AVAudioApplication.requestRecordPermission()
                        mic = AVAudioApplication.shared.recordPermission
                        await SessionController.shared.warmUp()
                    }
                }
            }
        }
    }

    private var modelStep: some View {
        Section(prepareOnly ? "Speech model" : "2 · Speech model") {
            let v = Settings.modelVariant
            Text(ModelCatalog.displayName(v)).font(.subheadline)
            switch setup.phase {
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%") }
                Text("About 630 MB. Wi-Fi recommended. The download continues briefly if you switch apps.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .compiling(let since):
                ProgressView()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Preparing the speech model for this iPhone. About 4 minutes, once. Keep Private Whisper open. (\(Int(ctx.date.timeIntervalSince(since)))s)")
                        .font(.footnote)
                }
            case .failed(let kind, let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Retry") { setup.installAndPrepare() }
                if kind == .compile { Button("Use alternative model") { setup.useAlternative() } }
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if prepareOnly { Button("Done") { dismiss() } }
            case .idle:
                if ASREngine.isInstalled(v) && ModelWarmth.isWarm(v) {
                    Label("Installed and prepared", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if ASREngine.isInstalled(v) {
                    Button("Prepare (about 4 min, keep the app open)") { setup.prepare() }
                } else {
                    Button("Download (about 630 MB)") { setup.installAndPrepare() }
                }
            }
        }
    }

    private var keyboardStep: some View {
        Section("3 · Keyboard") {
            if kbSeen {
                Label("Keyboard + Full Access verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text("Settings › General › Keyboard › Keyboards › Add New Keyboard › Private Whisper, then tap it and turn on Allow Full Access.")
                .font(.footnote)
            Text("Full Access lets the keyboard talk to this app on your iPhone. Nothing is sent anywhere.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
        }
    }

    private var intelligenceStep: some View {
        Section("4 · Apple Intelligence (cleanup)") {
            switch SystemLanguageModel.default.availability {
            case .available:
                Label("Available: dictations are cleaned up on device", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unavailable(let reason):
                Text("Cleanup is off until Apple Intelligence is on. Dictation still works.").font(.footnote)
                Text(String(describing: reason)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
