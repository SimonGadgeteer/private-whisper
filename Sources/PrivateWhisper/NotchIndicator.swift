import AppKit
import SwiftUI

/// Floating activity capsule below the notch — Siri-style: dark capsule with
/// a soft animated gradient glow, live waveform while recording, shimmer while
/// processing, brief checkmark on success. Click-through, all Spaces, visible
/// over fullscreen apps.
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

    private static let pillSize = NSSize(width: 172, height: 38)
    /// Extra canvas around the capsule so the glow shadow isn't clipped.
    private static let glowMargin: CGFloat = 24
    /// Gap between the bottom of the notch / menu bar and the capsule.
    private static let topGap: CGFloat = 12

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
        let canvas = NSSize(
            width: Self.pillSize.width + Self.glowMargin * 2,
            height: Self.pillSize.height + Self.glowMargin * 2)
        let hosting = NSHostingView(rootView: NotchPillView(model: model))
        hosting.frame = NSRect(origin: .zero, size: canvas)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI glow is the shadow
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        return panel
    }

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let topInset = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : (screen.frame.maxY - screen.visibleFrame.maxY)
        let canvas = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - canvas.width / 2,
            // glowMargin sits above the capsule, so subtract it back out.
            y: screen.frame.maxY - topInset - Self.topGap - canvas.height + Self.glowMargin))
    }
}

@MainActor
final class NotchIndicatorModel: ObservableObject {
    @Published var mode: NotchIndicatorController.Mode = .recording
    @Published var levels: [Float] = NotchIndicatorModel.emptyLevels

    static let barCount = 16
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

    private static let siriGradient = [
        Color(red: 0.31, green: 0.65, blue: 1.0),   // blue
        Color(red: 0.62, green: 0.42, blue: 1.0),   // purple
        Color(red: 1.0, green: 0.45, blue: 0.66),   // pink
        Color(red: 0.31, green: 0.65, blue: 1.0),
    ]

    var body: some View {
        content
            .frame(width: 172, height: 38)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(
                Capsule().strokeBorder(
                    AngularGradient(colors: Self.siriGradient, center: .center),
                    lineWidth: 1.5)
            )
            .shadow(color: glowColor.opacity(0.55), radius: 12, y: 2)
            .padding(24) // glow canvas margin
    }

    private var glowColor: Color {
        switch model.mode {
        case .recording: return Color(red: 0.62, green: 0.42, blue: 1.0)
        case .processing: return Color(red: 0.31, green: 0.65, blue: 1.0)
        case .success: return .green
        case .warning: return .yellow
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 9) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                WaveformBars(levels: model.levels)
            case .processing:
                Image(systemName: "ellipsis")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(
                        LinearGradient(colors: [Self.siriGradient[0], Self.siriGradient[1]],
                                       startPoint: .leading, endPoint: .trailing))
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
    }
}

private struct WaveformBars: View {
    let levels: [Float]

    private static let barGradient = LinearGradient(
        colors: [Color(red: 0.31, green: 0.65, blue: 1.0), Color(red: 0.62, green: 0.42, blue: 1.0)],
        startPoint: .bottom, endPoint: .top)

    var body: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Self.barGradient)
                    .frame(width: 3, height: barHeight(levels[i]))
            }
        }
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func barHeight(_ level: Float) -> CGFloat {
        // Speech chunk RMS is roughly 0.01–0.2; map to 3–22 pt.
        let normalized = min(1, CGFloat(level) * 10)
        return 3 + normalized * 19
    }
}
