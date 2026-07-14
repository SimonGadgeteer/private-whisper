import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore

    @State private var availableCleanupModels: [String] = []
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var accessibilityGranted = Permissions.checkAccessibility(prompt: false)
    @State private var connectionTestResult: String?
    @State private var newToneBundleID = ""
    @State private var newToneHint = ""

    private let whisperModels = ["large-v3-turbo", "large-v3"]

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: $configStore.config.hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("Command-mode key (edit selection by voice)", selection: Binding(
                    get: { configStore.config.commandHotkey?.rawValue ?? "off" },
                    set: { configStore.config.commandHotkey = HotkeyChoice(rawValue: $0) }
                )) {
                    Text("Disabled").tag("off")
                    ForEach(HotkeyChoice.allCases.filter { $0 != configStore.config.hotkey }) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                Picker("Microphone", selection: Binding(
                    get: { configStore.config.microphoneUID ?? "" },
                    set: { configStore.config.microphoneUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section("Transcription") {
                Picker("Whisper model", selection: $configStore.config.whisperModel) {
                    ForEach(whisperModels, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                if !FileManager.default.fileExists(
                    atPath: configStore.config.whisperModelPath.path) {
                    Label(
                        "Model file missing: \(configStore.config.whisperModelPath.path)",
                        systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Cleanup (LM Studio)") {
                Toggle("Cleanup enabled", isOn: $configStore.config.cleanupEnabled)
                TextField("Server URL", text: $configStore.config.lmStudioURL)
                Text("Local: http://localhost:1234/v1 — or a machine on your network, e.g. http://mac-mini.local:1234/v1 (enable \"Serve on Local Network\" in LM Studio's server settings there).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test Connection") {
                        connectionTestResult = "Testing…"
                        Task {
                            let models = await CleanupService.availableModels(
                                baseURL: configStore.config.lmStudioURL)
                            connectionTestResult = models.isEmpty
                                ? "✗ Unreachable (is the LM Studio server running?)"
                                : "✓ Connected — \(models.count) models available"
                            availableCleanupModels = models
                        }
                    }
                    if let connectionTestResult {
                        Text(connectionTestResult)
                            .font(.caption)
                            .foregroundStyle(connectionTestResult.hasPrefix("✓") ? .green : .secondary)
                    }
                }
                HStack {
                    Picker("Model", selection: $configStore.config.cleanupModel) {
                        if !availableCleanupModels.contains(configStore.config.cleanupModel) {
                            Text(configStore.config.cleanupModel)
                                .tag(configStore.config.cleanupModel)
                        }
                        ForEach(availableCleanupModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Button("Refresh") { Task { await refreshModels() } }
                }
                HStack {
                    Text("Timeout")
                    Slider(value: $configStore.config.cleanupTimeoutSeconds, in: 3...60, step: 1)
                    Text("\(Int(configStore.config.cleanupTimeoutSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Embedded cleanup (no LM Studio needed)") {
                DownloadRow(key: "cleanup-llm", required: false, downloader: ModelDownloader.shared)
                Text("Used automatically whenever LM Studio is unreachable. Runs a bundled llama-server on demand; stops after 10 minutes idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-app tone") {
                ForEach(configStore.config.appTones.keys.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.caption)
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TextField("tone", text: Binding(
                            get: { configStore.config.appTones[bundleID] ?? "" },
                            set: { configStore.config.appTones[bundleID] = $0 }
                        ))
                        .font(.caption)
                        Button(role: .destructive) {
                            configStore.config.appTones.removeValue(forKey: bundleID)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("bundle id (e.g. com.apple.mail)", text: $newToneBundleID)
                        .font(.caption)
                    TextField("tone hint", text: $newToneHint)
                        .font(.caption)
                    Button("Add") {
                        let key = newToneBundleID.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty, !newToneHint.isEmpty else { return }
                        configStore.config.appTones[key] = newToneHint
                        newToneBundleID = ""; newToneHint = ""
                    }
                }
                Text("The frontmost app's bundle id decides the register hint sent to the cleanup model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Notch activity indicator", isOn: $configStore.config.notchIndicatorEnabled)
                Toggle("Learn from corrections (experimental)", isOn: $configStore.config.correctionLearningEnabled)
                Toggle("Log dictation history (local JSONL)", isOn: $configStore.config.historyLoggingEnabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { configStore.config.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            }

            Section("Permissions") {
                HStack {
                    Label(
                        accessibilityGranted ? "Accessibility granted" : "Accessibility required",
                        systemImage: accessibilityGranted ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(accessibilityGranted ? .green : .red)
                    Spacer()
                    if !accessibilityGranted {
                        Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task {
            inputDevices = AudioDevices.inputDevices()
            await refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Permissions.checkAccessibility(prompt: false)
        }
    }

    private func modelLabel(_ model: String) -> String {
        model == "large-v3-turbo" ? "large-v3-turbo (faster)" : "large-v3 (best quality)"
    }

    private func refreshModels() async {
        availableCleanupModels = await CleanupService.availableModels(
            baseURL: configStore.config.lmStudioURL)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            configStore.config.launchAtLogin = enabled
        } catch {
            dlog("Launch at login failed: \(error.localizedDescription)")
        }
    }
}
