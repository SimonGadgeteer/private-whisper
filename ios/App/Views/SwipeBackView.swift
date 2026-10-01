// Concept from Dictus (https://github.com/getdictus/dictus-ios), DictusApp/Views/SwipeBackOverlayView.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md. Rewritten for this project.
import SwiftUI

/// v1 has no automatic return to the host app (spec §7): the user swipes back.
struct SwipeBackView: View {
    @ObservedObject private var session = SessionController.shared
    @State private var pulse = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 14, height: 14).opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                Text(session.status == .recording ? "Recording" : "Starting…").font(.title3.bold())
                if let since = session.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(since))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Text("Swipe right along the bottom edge to go back to your app")
                .font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("or tap ◀ at the top left").foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) { session.cancelDictation(byUser: true); dismiss() }
                    .buttonStyle(.bordered)
                Button("Done") { session.stopDictation(trigger: "swipeBackDone", autoInsert: false); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Done keeps the text in History and offers it in the keyboard as “Insert last dictation”.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .onAppear { pulse = true }
        .onChange(of: session.status) { _, s in
            if !(s == .recording || s == .requested) { dismiss() }
        }
    }
}
