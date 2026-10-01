// Diagnostics log shared by both processes (v1 extra).
//
// One append-only file `pw.log` in the App Group container. Each line is
//   2026-09-30 14:03:07.123 [app] I session: message
// and is written with a single write(2) on an O_APPEND descriptor, which the kernel appends atomically,
// so lines from the app and the keyboard interleave but never tear. Nothing holds a lock (a file lock held
// in a shared container at suspension is a 0xdead10cc kill). Only the app rotates, by an atomic rename
// (pw.log → pw.1.log) at launch/foreground; a keyboard write racing the rename lands in either file.
//
// Never log transcript text or FM debugDescriptions (they can quote the dictation).
import Foundation
import os

enum Log {
    static let process: String = Bundle.main.bundleURL.pathExtension == "appex" ? "kb" : "app"
    private static let logger = Logger(subsystem: "ch.simonschwarz.privatewhisper.ios", category: process)
    private static let queue = DispatchQueue(label: "pw.log", qos: .utility)
    private static let maxBytes = 1_000_000

    static var fileURL: URL? { AppGroup.containerURL?.appendingPathComponent("pw.log") }
    static var rotatedURL: URL? { AppGroup.containerURL?.appendingPathComponent("pw.1.log") }

    static func info(_ category: String, _ message: String) { write("I", category, message) }
    static func error(_ category: String, _ message: String) { write("E", category, message) }

    private static func write(_ level: String, _ category: String, _ message: String) {
        if level == "E" { logger.error("\(category, privacy: .public): \(message, privacy: .public)") }
        else { logger.info("\(category, privacy: .public): \(message, privacy: .public)") }
        let now = Date()
        queue.async {
            let line = "\(stamp(now)) [\(process)] \(level) \(category): \(message)\n"
            append(line)
        }
    }

    /// Blocks until queued lines are on disk (call before an expected termination).
    static func flush() { queue.sync {} }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static func stamp(_ d: Date) -> String { formatter.string(from: d) }   // only used on `queue`

    private static func append(_ line: String) {
        guard let path = fileURL?.path else { return }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes = Array(line.utf8)
        _ = bytes.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// App only: keep at most ~2 × maxBytes on disk.
    static func rotateIfNeeded() {
        queue.async {
            guard let url = fileURL, let rotated = rotatedURL,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size > maxBytes else { return }
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
    }

    /// The last `count` lines across the rotated and the current file (newest last).
    static func tail(_ count: Int = 200) -> [String] {
        func lines(_ url: URL?) -> [String] {
            guard let url, let h = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let window: UInt64 = 96_000
            try? h.seek(toOffset: size > window ? size - window : 0)
            let data = (try? h.readToEnd()) ?? Data()
            var ls = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if size > window, !ls.isEmpty { ls.removeFirst() }       // first line is probably cut
            return ls
        }
        var all = lines(fileURL)
        if all.count < count { all = lines(rotatedURL) + all }
        return Array(all.suffix(count))
    }

    /// Files to attach when sharing the log.
    static var shareURLs: [URL] {
        [rotatedURL, fileURL].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// TASK_VM_INFO phys_footprint in MB (what jetsam counts). −1 on failure.
func physFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}
