import AppKit

/// Reads the frontmost app's selected text by simulating Cmd+C against a
/// temporarily cleared pasteboard, then restoring the previous contents.
enum SelectionCapture {
    @MainActor
    static func selectedText() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general

        let snapshot: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                var entry: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { entry[type] = data }
                }
                return entry
            }

        pasteboard.clearContents()
        let baseline = pasteboard.changeCount

        postCmdC()
        // Give the target app time to service the copy.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != baseline { break }
        }

        let selection = pasteboard.changeCount != baseline
            ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }

        return selection?.isEmpty == false ? selection : nil
    }

    private static func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
