import AppKit

/// Push-to-talk detection for a single modifier key using NSEvent flagsChanged
/// monitors (global + local). Requires Accessibility permission for the global
/// monitor to receive events.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    var choice: HotkeyChoice

    private var monitors: [Any] = []
    private(set) var isDown = false

    init(choice: HotkeyChoice) {
        self.choice = choice
    }

    func start() {
        stop()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        // Keep the press/release pairing intact if the key is held during a
        // hotkey change: fire the release so a recording never gets stuck.
        if isDown {
            isDown = false
            onRelease?()
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == choice.keyCode else { return }
        let down = isChosenKeyDown(in: event)
        if down && !isDown {
            isDown = true
            onPress?()
        } else if !down && isDown {
            isDown = false
            onRelease?()
        }
    }

    /// Uses the device-dependent flag bits so left/right variants of the same
    /// modifier are distinguished — the generic .option flag stays set when
    /// the *other* Option key is still held, which would swallow the release.
    private func isChosenKeyDown(in event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch choice {
        case .leftOption: return raw & UInt(NX_DEVICELALTKEYMASK) != 0
        case .rightOption: return raw & UInt(NX_DEVICERALTKEYMASK) != 0
        case .rightCommand: return raw & UInt(NX_DEVICERCMDKEYMASK) != 0
        case .fnKey: return event.modifierFlags.contains(.function)
        }
    }
}
