import AppKit
import SwiftUI

/// Activity pill that hangs flush under the MacBook notch (or under the menu
/// bar on external displays): live waveform while recording, animated dots
/// while processing, brief checkmark on success. Click-through, all Spaces,
/// visible over fullscreen apps.
@MainActor
final class NotchIndicatorController {
    enum Mode: Equatable {
        case recording
        case processing
        case success
        case warning
    }

    private let model = NotchIndicatorModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func update(state: AppState) {
        guard configStore.config.notchIndicatorEnabled else {
            hide()
            return
        }
        hideTask?.cancel()
        switch state {
        case .recording:
            model.mode = .recording
            model.resetLevels()
            show()
        case .processing:
            model.mode = .processing
            show()
        case .injected:
            model.mode = .success
            show()
            scheduleHide(after: 1.2)
        case .warning:
            model.mode = .warning
            show()
            scheduleHide(after: 2.5)
        case .idle:
            hide()
        }
    }

    /// Live RMS level from the audio tap (already hopped to the main thread).
    func pushLevel(_ level: Float) {
        guard model.mode == .recording else { return }
        model.push(level: level)
    }

    // MARK: - Panel

    private static let pillSize = NSSize(width: 210, height: 34)

    private func show() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func makePanel() -> NSPanel {
        let size = Self.pillSize
        let hosting = NSHostingView(rootView: NotchPillView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        return panel
    }

    /// Flush under the notch on the built-in display; flush under the menu bar
    /// on displays without a notch.
    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let topInset = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : (screen.frame.maxY - screen.visibleFrame.maxY)
        let size = Self.pillSize
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topInset - size.height))
    }
}

@MainActor
final class NotchIndicatorModel: ObservableObject {
    @Published var mode: NotchIndicatorController.Mode = .recording
    @Published var levels: [Float] = NotchIndicatorModel.emptyLevels

    static let barCount = 22
    private static var emptyLevels: [Float] { Array(repeating: 0, count: barCount) }

    func resetLevels() {
        levels = Self.emptyLevels
    }

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

private struct NotchPillView: View {
    @ObservedObject var model: NotchIndicatorModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                WaveformBars(levels: model.levels)
            case .processing:
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.white)
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Inserted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Check menu bar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 210, height: 34)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 14,
                bottomTrailingRadius: 14, topTrailingRadius: 0)
                .fill(.black)
        )
    }
}

private struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(levels[i]))
            }
        }
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func barHeight(_ level: Float) -> CGFloat {
        // Speech chunk RMS is roughly 0.01–0.2; map to 3–20 pt.
        let normalized = min(1, CGFloat(level) * 10)
        return 3 + normalized * 17
    }
}
