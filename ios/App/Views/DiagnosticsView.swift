// Diagnostics (v1 extra): background Neural Engine / CPU-fallback state, IPC health, recent dictation timings,
// and the last ~200 lines of the shared log (both processes) with a Share button. Simon reports field problems with it.
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var session = SessionController.shared
    @ObservedObject private var history = History.shared
    @State private var lines: [String] = []
    @State private var compute = ComputeDiagnostics.state
    @State private var snapshot = Snapshot()

    struct Snapshot {
        var status = "–", sessionState = "–", heartbeatAge = "–", modelState = "–", warm = false
        var kbSeen = "never", kbContainer = false, fm = "–", fmVariant = "–", pending = 0, mem = 0
    }

    var body: some View {
        List {
            Section("Background compute (R1)") {
                Text(ComputeDiagnostics.headline).font(.headline)
                    .foregroundStyle(compute.bgAneFail > 0 ? .orange : .primary)
                row("Last path", compute.lastPath + (compute.lastAt > 0 ? " · " + ago(compute.lastAt) : ""))
                row("Background ANE OK / refused", "\(compute.bgAneOK) / \(compute.bgAneFail)")
                row("Foreground ANE OK", "\(compute.fgAneOK)")
                row("CPU fallback OK / failed", "\(compute.cpuFallbackOK) / \(compute.cpuFallbackFail)")
                row("Empty on ANE (retried)", "\(compute.suspiciousEmpty)")
                row("Suspected silent CPU (>3× slower)", "\(compute.suspectedSilentCPU)")
                row("Speed fg / last bg", "\(fmt(compute.fgRTF))× / \(fmt(compute.lastBgRTF))×")
                if let since = compute.stickyCPUSince {
                    row("Background forced to CPU since", ago(since))
                }
                if let f = compute.lastFallback {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last fallback · \(ago(f.at)) · \(f.succeeded ? "succeeded" : "FAILED")").font(.subheadline.bold())
                        Text("trigger \(f.trigger) · \(String(format: "%.1f", f.audioSeconds))s audio · ANE attempt \(f.aneMs) ms · CPU \(f.cpuMs) ms · \(f.cpuModel)")
                            .font(.caption)
                        if !f.error.isEmpty { Text(f.error).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }
                }
                Button("Reset counters", role: .destructive) { ComputeDiagnostics.reset(); reload() }
            }
            Section("State") {
                row("Status / session", "\(snapshot.status) / \(snapshot.sessionState)")
                row("Heartbeat age", snapshot.heartbeatAge)
                row("Model", "\(ModelCatalog.displayName(Settings.modelVariant)) · \(snapshot.modelState) · \(snapshot.warm ? "warm" : "cold cache")")
                row("App Group (app / keyboard)", "\(AppGroup.containerURL != nil ? "OK" : "nil") / \(snapshot.kbContainer ? "OK" : "not seen")")
                row("Keyboard last seen", snapshot.kbSeen)
                row("Apple Intelligence (keyboard)", "\(snapshot.fm) · \(snapshot.fmVariant)")
                row("Saved recordings awaiting transcription", "\(snapshot.pending)")
                row("App footprint", "\(snapshot.mem) MB")
            }
            Section("Recent dictations") {
                ForEach(history.entries.prefix(8)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.at.formatted(date: .omitted, time: .standard)) · \(e.computePath ?? "–") · \(e.model.map(ModelCatalog.displayName) ?? "–")")
                            .font(.caption.bold())
                        Text(timing(e)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(l.contains(" E ") ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("Log (last \(lines.count) lines)")
                    Spacer()
                    Button("Refresh") { reload() }.font(.caption)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            if !Log.shareURLs.isEmpty {
                ShareLink(items: Log.shareURLs) { Label("Share log", systemImage: "square.and.arrow.up") }
            }
        }
        .onAppear { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        Log.flush()
        lines = Log.tail(200).reversed()
        compute = ComputeDiagnostics.state
        let d = AppGroup.defaults
        d.synchronize()
        var s = Snapshot()
        s.status = d.string(forKey: Keys.status) ?? "–"
        s.sessionState = d.string(forKey: Keys.session) ?? "–"
        if let hb = d.object(forKey: Keys.heartbeat) as? Double { s.heartbeatAge = String(format: "%.1f s", Date().timeIntervalSince1970 - hb) }
        s.modelState = d.string(forKey: Keys.modelState) ?? "–"
        s.warm = ModelWarmth.isWarm(Settings.modelVariant)
        if let seen = d.object(forKey: Keys.kbSeenAt) as? Double { s.kbSeen = ago(seen) }
        s.kbContainer = d.bool(forKey: Keys.kbContainerOK)
        s.fm = d.string(forKey: Keys.fmAvailability) ?? "–"
        s.fmVariant = d.string(forKey: Keys.fmVariant) ?? "–"
        s.pending = PendingAudio.list().count
        s.mem = physFootprintMB()
        snapshot = s
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.footnote)
            Spacer()
            Text(v).font(.footnote.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func timing(_ e: History.Entry) -> String {
        func v(_ x: Int?) -> String { x.map { "\($0)" } ?? "–" }
        return "audio \(e.audioSeconds.map { String(format: "%.1f", $0) } ?? "–")s · stop→asr \(v(e.stopToAsrMs)) · asr \(v(e.asrMs)) · cleanup \(v(e.cleanupMs)) · stop→insert \(v(e.stopToInsertMs)) ms"
    }

    private func fmt(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "–" }
    private func ago(_ t: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - t)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}
