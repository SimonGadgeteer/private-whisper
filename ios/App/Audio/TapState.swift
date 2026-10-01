// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusApp/Audio/UnifiedAudioEngine.swift (processBuffer, converterMatching) and DictusCore AudioConverterCachePolicy.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// Everything the audio thread touches. Two changes relative to Dictus: samples are appended under a lock on the
// audio thread (never via DispatchQueue.main, which is throttled in the background), and the converter's input
// block hands the buffer over ONCE (Dictus returns it on every pull, which can duplicate audio).
import AVFoundation

final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var _generation: UInt64 = 0          // lock-protected from here …
    private var recording = false
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var badFormat: AVAudioFormat?        // … to here
    private var lastHeartbeat: TimeInterval = 0  // audio thread only
    private var lastLevel: TimeInterval = 0      // audio thread only
    private var loggedFormat = false             // audio thread only

    var generation: UInt64 { lock.withLock { _generation } }
    var sampleCount: Int { lock.withLock { samples.count } }

    func beginRecording() {
        lock.withLock { samples.removeAll(keepingCapacity: true); converter = nil; recording = true }
    }
    func endRecording() -> [Float] {
        lock.withLock { recording = false; let s = samples; samples = []; return s }
    }
    func invalidate() {
        lock.withLock { _generation &+= 1; recording = false; samples = []; converter = nil; badFormat = nil }
    }

    func process(_ buffer: AVAudioPCMBuffer, generation: UInt64, target: AVAudioFormat) {
        let now = Date().timeIntervalSince1970
        let (live, rec, conv): (Bool, Bool, AVAudioConverter?) = lock.withLock {
            guard generation == _generation else { return (false, false, nil) }
            guard recording else { return (true, false, nil) }
            return (true, true, converterLocked(for: buffer.format, target: target))
        }
        guard live else { return }
        let d = AppGroup.defaults
        guard rec else {                                                   // idle fast path (#38)
            if now - lastHeartbeat >= Timing.idleHeartbeat { lastHeartbeat = now; d.set(now, forKey: Keys.heartbeat) }
            return
        }
        if !loggedFormat {
            loggedFormat = true
            Log.info("audio", "tap format sr=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) frames=\(buffer.frameLength)")
        }
        guard let conv, let mono = convert(buffer, with: conv, target: target) else { return }
        let total: Int = lock.withLock {
            guard recording, generation == _generation else { return -1 }
            samples.append(contentsOf: mono); return samples.count
        }
        guard total >= 0 else { return }
        if now - lastHeartbeat >= Timing.recordingHeartbeat { lastHeartbeat = now; d.set(now, forKey: Keys.heartbeat) }
        if now - lastLevel >= Timing.levelInterval {
            lastLevel = now
            let rms = sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(max(mono.count, 1)))
            d.set(min(rms * 15, 1), forKey: Keys.level)
            d.set(Double(total) / 16_000, forKey: Keys.elapsed)
            d.synchronize()                                                // reviewer: sync before the ping
            DarwinNotify.post(DarwinName.level)
        }
    }

    private func converterLocked(for format: AVAudioFormat, target: AVAudioFormat) -> AVAudioConverter? {
        if let c = converter, c.inputFormat == format { return c }        // keyed on buffer.format (#417)
        if let bad = badFormat, bad == format { return nil }
        guard let c = AVAudioConverter(from: format, to: target) else { badFormat = format; converter = nil; return nil }
        converter = c; badFormat = nil
        return c
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with c: AVAudioConverter, target: AVAudioFormat) -> [Float]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = c.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
