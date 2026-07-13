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
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == choice.keyCode else { return }
        let flag = modifierFlag(for: choice)
        let down = event.modifierFlags.contains(flag)
        if down && !isDown {
            isDown = true
            onPress?()
        } else if !down && isDown {
            isDown = false
            onRelease?()
        }
    }

    private func modifierFlag(for choice: HotkeyChoice) -> NSEvent.ModifierFlags {
        switch choice {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .fnKey: return .function
        }
    }
}
