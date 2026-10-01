// openURL capture adapted from Dictus (https://github.com/getdictus/dictus-ios), DictusKeyboard/KeyboardRootView.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// Layout (spec §8.1): status strip 44 pt · primary key area · bottom row 52 pt; 260 pt total. SF Symbols only,
// no continuous animations (memory budget §8.4).
import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject private var state = KeyboardState.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            statusStrip.frame(height: 44)
            Divider()
            if state.hasFullAccess { primaryArea } else { fullAccessBanner }
            Divider()
            bottomRow.frame(height: 52)
        }
        .frame(maxWidth: .infinity)
        .onAppear { KeyboardState.shared.openURL = { openURL($0) } }   // re-captured on every appearance
    }

    // MARK: status strip

    private var statusStrip: some View {
        HStack(spacing: 10) {
            Button { state.cycleLanguage() } label: {
                Text(state.language.chip).font(.footnote.bold()).frame(minWidth: 40, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .secondarySystemFill)))
            }
            .buttonStyle(.plain)
            if state.phase == .recording {
                LevelBars(level: state.level)
                Text(String(format: "%d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(statusText).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if state.phase != .idle {
                Button { state.requestCancel() } label: {
                    Image(systemName: "xmark").font(.body.bold()).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel dictation")
            }
        }
        .padding(.horizontal, 10)
    }

    private var statusText: String {
        if let m = state.message { return m }
        switch state.phase {
        case .idle: return ""
        case .requested: return "Starting…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning…"
        }
    }

    // MARK: primary key

    private var primaryArea: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Button { state.micTapped() } label: {
                ZStack {
                    Circle().fill(primaryColor).frame(width: 96, height: 96)
                    primaryIcon
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.phase == .recording ? "Stop and insert" : "Dictate")
            if state.phase == .cleaning {
                chip("Insert raw now") { state.flushActiveAsRaw() }
            } else if state.insertableLast && state.phase == .idle {
                chip("Insert last dictation") { state.claimLast() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var primaryIcon: some View {
        switch state.phase {
        case .idle: Image(systemName: "mic.fill").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
        case .recording: Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
        case .requested, .transcribing, .cleaning: ProgressView().tint(.white).controlSize(.large)
        }
    }

    private var primaryColor: Color {
        switch state.phase {
        case .recording: return .red
        case .idle: return .accentColor
        default: return .gray
        }
    }

    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private var fullAccessBanner: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Allow Full Access: Settings › General › Keyboard › Keyboards › Private Whisper")
                .font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 16)
            Button("Open Private Whisper") { state.openApp() }.buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: bottom row

    private var bottomRow: some View {
        HStack(spacing: 8) {
            if state.needsGlobe, let controller = state.controller {
                GlobeKey(controller: controller).frame(width: 44, height: 40)
            }
            KeyCap { state.insert(" ") } label: { Text("space").font(.callout) }
                .frame(maxWidth: .infinity)
            DeleteKey().frame(width: 56, height: 40)
            KeyCap { state.insert("\n") } label: { Image(systemName: "return") }
                .frame(width: 64)
        }
        .padding(.horizontal, 6)
    }
}

/// 7 bars driven by one level value at 5 Hz.
private struct LevelBars: View {
    let level: Float
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                let shape: [CGFloat] = [0.35, 0.6, 0.85, 1, 0.85, 0.6, 0.35]
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red)
                    .frame(width: 3, height: max(3, 22 * CGFloat(level) * shape[i]))
            }
        }
        .frame(height: 24)
    }
}

private struct KeyCap<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var body: some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .systemBackground)))
                .shadow(color: .black.opacity(0.2), radius: 0, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Delete: tap deletes once; after a 0.4 s hold it repeats every 0.1 s.
private struct DeleteKey: View {
    @State private var timer: Timer?
    @State private var pressed = false
    var body: some View {
        Image(systemName: "delete.left")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: pressed ? .systemGray3 : .systemBackground)))
            .shadow(color: .black.opacity(0.2), radius: 0, x: 0, y: 1)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    KeyboardState.shared.deleteBackward()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                MainActor.assumeIsolated { KeyboardState.shared.deleteBackward() }
                            }
                        }
                    }
                }
                .onEnded { _ in pressed = false; timer?.invalidate(); timer = nil })
            .accessibilityLabel("Delete")
    }
}

/// Only shown when `needsInputModeSwitchKey` (false on Face ID iPhones, where the system draws its own globe).
private struct GlobeKey: UIViewRepresentable {
    let controller: UIInputViewController
    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return b
    }
    func updateUIView(_ uiView: UIButton, context: Context) {}
}
