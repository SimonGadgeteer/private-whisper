import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore!
    private var statusItem: StatusItemController!
    private var hud: HUDController!
    private var pipeline: PipelineController!
    private var hotkey: HotkeyMonitor!
    private var commandHotkey: HotkeyMonitor?
    private var notch: NotchIndicatorController!
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configStore = ConfigStore()
        configStore.config.save() // materialize config.json on first run

        statusItem = StatusItemController()
        hud = HUDController()
        pipeline = PipelineController(configStore: configStore, statusItem: statusItem, hud: hud)
        notch = NotchIndicatorController(configStore: configStore)
        let learner = CorrectionLearner(configStore: configStore)
        learner.onSuggestions = { [weak self] terms in
            guard let self else { return }
            hud.showSuggestions(terms) { term in
                guard !self.configStore.config.dictionary.contains(term) else { return }
                self.configStore.config.dictionary.append(term)
                self.configStore.config.dictionary.sort {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            }
        }
        pipeline.correctionLearner = learner
        statusItem.onStateChange = { [weak self] state in self?.notch.update(state: state) }
        pipeline.onAudioLevel = { [weak self] level in self?.notch.pushLevel(level) }

        statusItem.setCleanupChecked(configStore.config.cleanupEnabled)
        statusItem.onToggleCleanup = { [weak self] in
            guard let self else { return }
            configStore.config.cleanupEnabled.toggle()
            statusItem.setCleanupChecked(configStore.config.cleanupEnabled)
        }
        statusItem.onOpenSettings = { [weak self] in self?.showMainWindow() }
        statusItem.onOpenMainWindow = { [weak self] in self?.showMainWindow() }

        hotkey = HotkeyMonitor(choice: configStore.config.hotkey)
        hotkey.onPress = { [weak self] in self?.pipeline.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.pipeline.hotkeyReleased() }
        installCommandMonitor()

        Task { await self.requestPermissionsAndStart() }

        // First run without the whisper model → surface setup immediately.
        if !FileManager.default.fileExists(atPath: configStore.config.whisperModelPath.path) {
            showMainWindow()
        }
    }

    private func requestPermissionsAndStart() async {
        let micGranted = await Permissions.requestMicrophone()
        if !micGranted {
            statusItem.setState(.warning("Microphone permission required"))
            hud.flash("Microphone permission required — opening System Settings", seconds: 4)
            Permissions.openMicrophoneSettings()
        }

        let axGranted = Permissions.checkAccessibility(prompt: true)
        if !axGranted {
            statusItem.setState(.warning("Accessibility permission required"))
            // Global hotkey + injection won't work yet; user grants and relaunches
            // or we pick it up when they retry (monitors are installed regardless).
        }

        dlog("Permissions at startup: mic=\(micGranted) accessibility=\(axGranted)")
        hotkey.choice = configStore.config.hotkey
        hotkey.start()
        pipeline.preloadModel()

        // React to hotkey setting changes.
        observeHotkeyChanges()
    }

    private var hotkeyObservation: AnyCancellable?
    private func observeHotkeyChanges() {
        hotkeyObservation = configStore.$config.sink { [weak self] config in
            guard let self else { return }
            if hotkey.choice != config.hotkey {
                hotkey.choice = config.hotkey
                hotkey.start() // reinstall with new key
            }
            if commandHotkey?.choice != config.commandHotkey {
                installCommandMonitor()
            }
        }
    }

    private func installCommandMonitor() {
        commandHotkey?.stop()
        commandHotkey = nil
        guard let choice = configStore.config.commandHotkey,
              choice != configStore.config.hotkey else { return }
        let monitor = HotkeyMonitor(choice: choice)
        monitor.onPress = { [weak self] in self?.pipeline.commandPressed() }
        monitor.onRelease = { [weak self] in self?.pipeline.commandReleased() }
        monitor.start()
        commandHotkey = monitor
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedLLMServer.shared.stop()
        pipeline?.shutdown()
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Private Whisper"
            window.contentView = NSHostingView(rootView: MainWindowView(
                configStore: configStore, statsStore: StatsStore.shared))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
