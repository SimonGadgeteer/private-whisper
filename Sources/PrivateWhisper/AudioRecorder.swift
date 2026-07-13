import AVFoundation
import CoreAudio

/// Captures microphone audio via AVAudioEngine and accumulates a 16 kHz mono
/// Float32 buffer (whisper's expected input format).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    /// Incremented per recording session; late tap callbacks from a previous
    /// session are dropped so they can't bleed samples into the next one.
    private var session = 0

    /// Selects the capture device. nil = system default.
    func setInputDevice(uid: String?) {
        guard let uid, let deviceID = AudioDevices.deviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    func start(deviceUID: String?) throws {
        if isRecording { _ = stop() } // never stack sessions / leave a hot mic

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        session += 1
        let currentSession = session
        lock.unlock()

        setInputDevice(uid: deviceUID)
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "PrivateWhisper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No usable input device (sample rate 0)."])
        }
        // The converter is owned by the tap closure (captured by value): the
        // realtime tap thread never reads shared mutable state.
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw NSError(domain: "PrivateWhisper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot convert \(format) to 16 kHz mono."])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, session: currentSession)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns the accumulated 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, session: Int) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        lock.lock()
        if session == self.session {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        lock.unlock()
    }
}

extension Array where Element == Float {
    /// Root-mean-square level, used to discard silent recordings.
    var rmsLevel: Float {
        guard !isEmpty else { return 0 }
        let sum = reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(count)).squareRoot()
    }
}
