import SwiftUI
import UIKit

struct HistoryView: View {
    @ObservedObject private var history = History.shared
    @State private var copiedId: UUID?

    var body: some View {
        List {
            if history.entries.isEmpty {
                Text("No dictations yet.").foregroundStyle(.secondary)
            }
            ForEach(history.entries) { e in
                Button {
                    UIPasteboard.general.string = e.displayText
                    copiedId = e.id
                } label: { row(e) }
                .buttonStyle(.plain)
            }
            .onDelete { history.delete($0) }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.entries.isEmpty { Button("Clear all", role: .destructive) { history.clear() } }
        }
    }

    private func row(_ e: History.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(e.at, style: .time)
                Text(e.language.uppercased())
                if e.cleaned == true { Text("cleaned") } else if e.final != nil { Text("not cleaned · \(e.reason ?? "?")") }
                Spacer()
                if copiedId == e.id { Text("Copied").foregroundStyle(.green) }
                else if let ins = e.inserted { Text(ins ? "inserted" : "not inserted") }
                else if e.source == "recovered" { Text("recovered") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(e.displayText).font(.body).lineLimit(6)
            if let path = e.computePath {
                Text(timingLine(e, path: path)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func timingLine(_ e: History.Entry, path: String) -> String {
        var parts = [path]
        if let a = e.audioSeconds { parts.append(String(format: "%.1fs audio", a)) }
        if let v = e.asrMs { parts.append("asr \(v) ms") }
        if let v = e.cleanupMs { parts.append("cleanup \(v) ms") }
        if let v = e.stopToInsertMs { parts.append("stop→insert \(v) ms") }
        return parts.joined(separator: " · ")
    }
}
