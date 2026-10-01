import SwiftUI

struct SettingsView: View {
    @ObservedObject private var setup = ModelSetup.shared
    @State private var language = Settings.language
    @State private var swiss = Settings.germanIsSwiss
    @State private var idle = Settings.idleMinutes
    @State private var cleanup = Settings.cleanupEnabled
    @State private var bias = Settings.vocabularyBias
    @State private var dictionary = Settings.dictionary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    @State private var newTerm = ""
    @State private var variant = Settings.modelVariant
    @State private var cpuFallback = Settings.cpuFallbackVariant ?? ""

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Default language", selection: $language) {
                    ForEach(DictationLanguage.allCases, id: \.self) { Text($0 == .auto ? "Auto" : $0.chip).tag($0) }
                }
                .onChange(of: language) { _, v in Settings.language = v }
                Toggle("Treat German as Swiss (ss)", isOn: $swiss)
                    .onChange(of: swiss) { _, v in Settings.germanIsSwiss = v }
                Toggle("Clean up with Apple Intelligence", isOn: $cleanup)
                    .onChange(of: cleanup) { _, v in Settings.cleanupEnabled = v }
                Toggle("Bias recognition to my dictionary", isOn: $bias)
                    .onChange(of: bias) { _, v in Settings.vocabularyBias = v }
            }
            Section {
                Picker("Stop listening after", selection: $idle) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min idle").tag($0) }
                    Text("Never").tag(-1)
                }
                .onChange(of: idle) { _, v in
                    Settings.idleMinutes = v
                    let a = SessionController.shared.audio
                    a.idleReleaseInterval = Settings.idleInterval
                    a.rescheduleIdleRelease()
                }
            } header: { Text("Background listening") } footer: {
                Text("While listening (orange dot) the battery drops about 3.3% per hour.")
            }
            Section("Personal dictionary") {
                HStack {
                    TextField("Add a word or name", text: $newTerm).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { addTerm() }.disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(dictionary, id: \.self) { Text($0) }
                    .onDelete { idx in dictionary.remove(atOffsets: idx); Settings.dictionary = dictionary }
            }
            Section {
                Picker("Model", selection: $variant) {
                    ForEach(ModelCatalog.selectable, id: \.self) { Text(ModelCatalog.displayName($0)).tag($0) }
                }
                .onChange(of: variant) { _, v in setup.switchVariant(to: v) }
                .disabled(setup.isWorking)
                if setup.isWorking { Text(workingText).font(.footnote).foregroundStyle(.secondary) }
                if !ASREngine.isInstalled(variant) {
                    Button("Download and prepare") { setup.installAndPrepare() }.disabled(setup.isWorking)
                } else if !ModelWarmth.isWarm(variant) {
                    Button("Prepare (about 4 min)") { setup.prepare() }.disabled(setup.isWorking)
                }
                Button("Re-download", role: .destructive) { setup.redownload() }.disabled(setup.isBusy)
            } header: { Text("Speech model") }
            Section {
                Picker("CPU fallback model", selection: $cpuFallback) {
                    Text("Same model, CPU only").tag("")
                    ForEach(ModelCatalog.cpuFallbackChoices, id: \.self) { Text(ModelCatalog.displayName($0)).tag($0) }
                }
                .onChange(of: cpuFallback) { _, v in
                    if v.isEmpty { Settings.cpuFallbackVariant = nil }
                    else if ASREngine.isInstalled(v) { Settings.cpuFallbackVariant = v }
                    else { setup.installCPUFallback(v) }
                }
                if let m = setup.fallbackMessage { Text(m).font(.footnote) }
            } header: { Text("Background fallback") } footer: {
                Text("If iOS refuses the Neural Engine while Private Whisper is in the background, the same recording is transcribed again on the CPU. A smaller model is faster there. See Diagnostics.")
            }
            Section("About") {
                Text("Private Whisper transcribes on this iPhone with WhisperKit (Argmax, MIT) and cleans text with Apple Foundation Models. No audio or text leaves the device. Portions adapted from Dictus (MIT, © 2026 PIVI Solutions). Full notices: THIRD_PARTY_NOTICES.md in the repository.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .onAppear { variant = Settings.modelVariant }
    }

    private var workingText: String {
        switch setup.phase {
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .compiling: return "Preparing the model (about 4 min). Keep Private Whisper open."
        default: return ""
        }
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !dictionary.contains(t) else { newTerm = ""; return }
        dictionary.append(t)
        dictionary.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        Settings.dictionary = dictionary
        newTerm = ""
    }
}
