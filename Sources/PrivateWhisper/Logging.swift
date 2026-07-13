import Foundation

/// Plain-file diagnostics log (~/Library/Application Support/PrivateWhisper/app.log).
/// NSLog also fires, but the file survives unified-log privacy filtering and is
/// trivially readable while debugging.
func dlog(_ message: String) {
    NSLog("%@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let url = AppConfig.supportDir.appendingPathComponent("app.log")
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? FileManager.default.createDirectory(at: AppConfig.supportDir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
