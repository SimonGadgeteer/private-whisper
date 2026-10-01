import SwiftUI
import AVFoundation

struct RootView: View {
    @ObservedObject private var session = SessionController.shared
    @State private var setupComplete = RootView.isSetupComplete

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                    if session.session.isWarm {
                        Button(role: .destructive) { session.stopListening() } label: {
                            Label("Stop listening", systemImage: "mic.slash")
                        }
                    }
                    if let e = session.lastError {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                    }
                    if session.pendingCount > 0 {
                        Button { session.recoverPendingAudio() } label: {
                            Label("Finish \(session.pendingCount) saved recording(s)", systemImage: "waveform.badge.exclamationmark")
                        }
                    }
                }
                Section {
                    NavigationLink { OnboardingView(prepareOnly: false) } label: {
                        Label(setupComplete ? "Setup (complete)" : "Finish setup", systemImage: setupComplete ? "checkmark.seal" : "list.bullet.clipboard")
                    }
                    NavigationLink { HistoryView() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                    NavigationLink { DiagnosticsView() } label: { Label("Diagnostics", systemImage: "stethoscope") }
                }
                Section {
                    Text("Dictate in any app: switch to the Private Whisper keyboard with the globe key and tap the microphone. Everything runs on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Private Whisper")
            .onAppear { setupComplete = RootView.isSetupComplete }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(session.session.isWarm ? Color.orange : Color.secondary).frame(width: 10, height: 10)
                Text(headline).font(.headline)
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var headline: String {
        switch session.status {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        default: return session.session.isWarm ? "Listening in the background" : "Not listening"
        }
    }

    private var detail: String {
        if session.session.isWarm {
            let m = Settings.idleMinutes
            return m < 0 ? "The orange dot stays on until you tap Stop listening."
                         : "The orange dot shows the microphone is ready. Stops after \(m) min idle."
        }
        return "The next dictation opens this app once, then works in place."
    }

    static var isSetupComplete: Bool {
        AVAudioApplication.shared.recordPermission == .granted
            && ASREngine.isInstalled(Settings.modelVariant)
            && AppGroup.defaults.object(forKey: Keys.kbSeenAt) != nil
    }
}
