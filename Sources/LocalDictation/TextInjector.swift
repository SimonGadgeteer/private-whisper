import AppKit
import Carbon.HIToolbox

enum InjectionOutcome {
    case injected
    /// Text was not injected; the caller should show it in the HUD instead.
    case needsHUD(reason: String)
}

/// Injects text at the cursor of the frontmost app: pasteboard + synthetic
/// Cmd+V, then restores the previous pasteboard contents (PRD §4.1-D).
enum TextInjector {
    /// Roles that clearly cannot receive pasted text. Anything unknown is
    /// treated as paste-able — a stray Cmd+V into a non-text target is a no-op,
    /// while a false HUD would interrupt the flow. Heuristic, documented in
    /// DECISIONS.md.
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXMenuRole, kAXImageRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole,
    ]

    @MainActor
    static func inject(_ text: String) -> InjectionOutcome {
        guard AXIsProcessTrusted() else {
            return .needsHUD(reason: "Accessibility permission not granted")
        }
        if IsSecureEventInputEnabled() {
            return .needsHUD(reason: "A secure input field is active (e.g. a password field)")
        }
        switch focusedElementAssessment() {
        case .noFocus:
            return .needsHUD(reason: "No text field is focused")
        case .nonText(let role):
            return .needsHUD(reason: "Focused element (\(role)) is not a text field")
        case .textLikeOrUnknown:
            break
        }

        paste(text)
        return .injected
    }

    private enum FocusAssessment {
        case noFocus
        case nonText(role: String)
        case textLikeOrUnknown
    }

    private static func focusedElementAssessment() -> FocusAssessment {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return .noFocus }

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXRoleAttribute as CFString, &roleValue)
        if let role = roleValue as? String, nonTextRoles.contains(role) {
            return .nonText(role: role)
        }
        return .textLikeOrUnknown
    }

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot every item/type so we can restore rich content afterwards.
        let snapshot: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                var entry: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { entry[type] = data }
                }
                return entry
            }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCmdV()

        // Give the target app time to read the pasteboard before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            let items = snapshot.map { entry -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
