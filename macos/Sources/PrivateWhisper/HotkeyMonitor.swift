import AppKit

/// Push-to-talk on a single modifier key. Recording starts only after the key has been held for
/// `holdDelay` with nothing else pressed; any other key or mouse button while it is held means the
/// user is typing a combination (Option+G is "@" on Swiss layouts), see HoldGesture.
/// Requires Accessibility permission for the global monitors.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// The key turned out to be part of a combination after recording had started: discard it.
    var onCancel: (() -> Void)?

    var choice: HotkeyChoice
    var holdDelay: TimeInterval

    private var gesture = HoldGesture()
    private var activation: DispatchWorkItem?
    private var monitors: [Any] = []

    var isDown: Bool { gesture.phase != .up }

    init(choice: HotkeyChoice, holdDelay: TimeInterval) {
        self.choice = choice
        self.holdDelay = holdDelay
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        if let global { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
        dlog("HotkeyMonitor started: choice=\(choice.rawValue) holdDelay=\(Int(holdDelay * 1000))ms globalMonitor=\(global != nil)")
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        // Keep the press/release pairing intact if the key is held during a
        // hotkey change: fire the release so a recording never gets stuck.
        perform(gesture.keyUp())
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if event.keyCode == choice.keyCode {
                perform(isChosenKeyDown(in: event) ? gesture.keyDown() : gesture.keyUp())
            } else if isAnyModifierDown(event) {
                perform(gesture.otherInput(modifierOnly: true))
            }
        case .keyDown:
            // Our own Cmd+C / Cmd+V must not count as the user typing a combination.
            guard !SyntheticKeys.isOwn(event.cgEvent) else { return }
            perform(gesture.otherInput(modifierOnly: false))
        default:                                     // mouse button: Option-click, Option-drag
            perform(gesture.otherInput(modifierOnly: false))
        }
    }

    private func perform(_ action: HoldGesture.Action) {
        switch action {
        case .none:
            return
        case .scheduleActivation:
            activation?.cancel()
            guard holdDelay > 0 else { perform(gesture.holdDelayElapsed()); return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.perform(self.gesture.holdDelayElapsed())
            }
            activation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        case .cancelScheduled:
            activation?.cancel()
            activation = nil
            if gesture.phase == .combination { dlog("Hotkey \(choice.rawValue): key combination, not dictation") }
        case .start:
            activation = nil
            onPress?()
        case .stop:
            onRelease?()
        case .cancel:
            dlog("Hotkey \(choice.rawValue): key combination during recording, discarding")
            onCancel?()
        }
    }

    /// Another modifier went down (not up) while ours is held.
    private func isAnyModifierDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ours: NSEvent.ModifierFlags = {
            switch choice {
            case .leftOption, .rightOption: return .option
            case .rightCommand: return .command
            case .fnKey: return .function
            }
        }()
        return !flags.subtracting([ours, .capsLock, .numericPad, .function]).isEmpty
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
