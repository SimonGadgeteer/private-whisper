import AVFoundation
import Foundation

/// Headless pipeline runner for automated testing:
///   LocalDictation --test-file <audio> [--no-cleanup] [--json]
/// Loads any audio file AVFoundation can read, resamples to 16 kHz mono,
/// runs whisper + (optionally) the LM Studio cleanup pass, prints the result.
enum TestMode {
    static func run(arguments: [String]) {
        guard let fileIndex = arguments.firstIndex(of: "--test-file"),
              arguments.count > fileIndex + 1
        else {
            FileHandle.standardError.write(Data("usage: --test-file <audio> [--no-cleanup]\n".utf8))
            exit(2)
        }
        let audioPath = arguments[fileIndex + 1]
        let cleanupEnabled = !arguments.contains("--no-cleanup")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            defer { semaphore.signal() }
            do {
                let config = AppConfig.load()
                let samples = try loadSamples(path: audioPath)

                guard AudioGate.passes(samples) else {
                    print(#"{"raw": "", "discarded": "below audio gate (too short or silent)"}"#)
                    return
                }

                let transcriber = WhisperCppTranscriber(modelPath: config.whisperModelPath)
                let loadStart = Date()
                try await transcriber.preload()
                let modelLoadSeconds = Date().timeIntervalSince(loadStart)
                let tStart = Date()
                let result = try await transcriber.transcribe(samples: samples)
                let transcriptionSeconds = Date().timeIntervalSince(tStart)

                var output: [String: Any] = [
                    "raw": result.text,
                    "language": result.language,
                    "audio_seconds": Double(samples.count) / 16000.0,
                    "transcription_seconds": transcriptionSeconds,
                    "model_load_seconds": modelLoadSeconds,
                ]

                if cleanupEnabled && !result.text.isEmpty {
                    let cleanup = CleanupService(
                        baseURL: config.lmStudioURL,
                        model: config.cleanupModel,
                        timeout: config.cleanupTimeoutSeconds)
                    let cStart = Date()
                    do {
                        let cleaned = try await cleanup.cleanup(
                            transcript: result.text, language: result.language)
                        output["cleaned"] = cleaned
                        output["cleanup_seconds"] = Date().timeIntervalSince(cStart)
                        output["cleanup_model"] = config.cleanupModel
                    } catch {
                        output["cleanup_error"] = error.localizedDescription
                    }
                }

                let data = try JSONSerialization.data(
                    withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }

        semaphore.wait()
        exit(exitCode)
    }

    private static func loadSamples(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "TestMode", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot convert \(file.processingFormat) to 16kHz mono"])
        }

        let sourceCapacity: AVAudioFrameCount = 32768
        var samples: [Float] = []
        var reachedEnd = false

        while !reachedEnd {
            let outCapacity = AVAudioFrameCount(
                Double(sourceCapacity) * target.sampleRate / file.processingFormat.sampleRate) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity)
            else { break }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                guard let inBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: sourceCapacity),
                    (try? file.read(into: inBuffer)) != nil,
                    inBuffer.frameLength > 0
                else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .endOfStream || status == .error { reachedEnd = true }
            if let error = conversionError { throw error }

            if let channel = outBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(outBuffer.frameLength)))
            }
            if outBuffer.frameLength == 0 && status != .haveData { reachedEnd = true }
        }
        return samples
    }
}
