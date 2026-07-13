import AppKit

enum AppState: Equatable {
    case idle
    case recording
    case processing
    case injected
    /// Cleanup fell back to the raw transcript (LM Studio unreachable/timeout).
    case warning(String)
}

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let stateMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private var revertTask: Task<Void, Never>?

    var onToggleCleanup: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?
    /// Fired on every state transition (drives the notch indicator).
    var onStateChange: ((AppState) -> Void)?

    /// Most recent dictation result; menu fallback in case injection no-ops.
    var lastDictation: String? {
        didSet {
            statusItem.menu?.item(withTag: 101)?.isEnabled = lastDictation != nil
        }
    }

    private(set) var state: AppState = .idle

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.autoenablesItems = false
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open Private Whisper…", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let cleanupItem = NSMenuItem(
            title: "Cleanup Enabled", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.tag = 100
        menu.addItem(cleanupItem)

        let copyLastItem = NSMenuItem(
            title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")
        copyLastItem.target = self
        copyLastItem.tag = 101
        copyLastItem.isEnabled = false
        menu.addItem(copyLastItem)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Private Whisper", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        statusItem.menu = menu
        setState(.idle)
    }

    func setCleanupChecked(_ enabled: Bool) {
        statusItem.menu?.item(withTag: 100)?.state = enabled ? .on : .off
    }

    func setState(_ newState: AppState) {
        revertTask?.cancel()
        state = newState
        onStateChange?(newState)

        let (symbol, description, tint): (String, String, NSColor?) = {
            switch newState {
            case .idle: return ("mic", "Idle — hold hotkey to dictate", nil)
            case .recording: return ("mic.fill", "Recording…", .systemRed)
            case .processing: return ("hourglass", "Processing…", nil)
            case .injected: return ("checkmark.circle.fill", "Inserted", .systemGreen)
            case .warning(let msg): return ("exclamationmark.triangle.fill", msg, .systemYellow)
            }
        }()

        if let button = statusItem.button {
            var image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: description)
            if let tint {
                image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
                image?.isTemplate = false
            } else {
                image?.isTemplate = true
            }
            button.image = image
            button.toolTip = description
        }
        stateMenuItem.title = description

        // Transient states revert to idle on their own.
        switch newState {
        case .injected:
            revertToIdle(after: 1.5)
        case .warning:
            revertToIdle(after: 4)
        default:
            break
        }
    }

    private func revertToIdle(after seconds: Double) {
        revertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.setState(.idle) }
        }
    }

    @objc private func toggleCleanup() { onToggleCleanup?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openMainWindow() { onOpenMainWindow?() }

    @objc private func copyLast() {
        guard let lastDictation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastDictation, forType: .string)
    }
}
