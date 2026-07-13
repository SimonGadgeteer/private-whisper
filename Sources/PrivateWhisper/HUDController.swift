import AppKit
import SwiftUI

/// Floating, non-activating panels for transient feedback:
/// - result HUD with the text + Copy button (when injection isn't possible)
/// - brief "Nothing heard" / warning flashes
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func showText(_ text: String, reason: String) {
        show(width: 420, height: 220, autoDismiss: 15) {
            ResultHUDView(text: text, reason: reason)
        }
    }

    /// Correction-learning suggestions with one-click Add.
    func showSuggestions(_ terms: [String], onAdd: @escaping (String) -> Void) {
        show(width: 300, height: CGFloat(56 + terms.count * 34), autoDismiss: 14) {
            SuggestionHUDView(terms: terms, onAdd: onAdd) { [weak self] in
                // Everything added — no reason to linger.
                Task { try? await Task.sleep(nanoseconds: 900_000_000)
                       self?.dismiss() }
            }
        }
    }

    func flash(_ message: String, seconds: Double = 1.5) {
        show(width: 260, height: 60, autoDismiss: seconds) {
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func show<Content: View>(
        width: CGFloat, height: CGFloat, autoDismiss: Double, @ViewBuilder content: () -> Content
    ) {
        dismiss()

        let hosting = NSHostingView(rootView: AnyView(
            content()
                .padding(12)
                .frame(width: width, height: height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - width / 2,
                y: frame.maxY - height - 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(autoDismiss * 1_000_000_000))
            if !Task.isCancelled { self?.dismiss() }
        }
    }
}

private struct SuggestionHUDView: View {
    let terms: [String]
    let onAdd: (String) -> Void
    let onAllAdded: () -> Void
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Add to your dictionary?", systemImage: "character.book.closed")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(terms, id: \.self) { term in
                HStack {
                    Text(term).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(added.contains(term) ? "Added ✓" : "Add") {
                        onAdd(term)
                        added.insert(term)
                        if added.count == terms.count { onAllAdded() }
                    }
                    .disabled(added.contains(term))
                }
            }
        }
    }
}

private struct ResultHUDView: View {
    let text: String
    let reason: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(copied ? "Copied ✓" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
            }
        }
    }
}
