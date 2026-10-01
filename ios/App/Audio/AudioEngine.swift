// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusApp/Audio/UnifiedAudioEngine.swift and DictusCore policy files (IdleRelease, AudioInputFormat,
// AudioStartReadiness, SystemCallObserver). MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
@preconcurrency import AVFoundation
import CallKit

@MainActor
final class AudioEngine {
    enum EngineError: LocalizedError {
        case callActive, permissionDenied, hardwareUnavailable(String), objc(String)
        var errorDescription: String? {
            switch self {
            case .callActive: return "Dictation is paused during phone calls."
            case .permissionDenied: return "Microphone access is off. Enable it in Settings > Private Whisper."
            case .hardwareUnavailable(let r): return "Microphone unavailable (\(r))."
            case .objc(let r): return "Audio engine error (\(r))."
            }
        }
    }

    /// Idle release, interruption, media reset, user stop. `salvaged` carries the samples of a dictation that
    /// was recording when the interruption hit (reviewer: never throw captured speech away).
    var onWarmStateEnded: ((_ reason: String, _ salvaged: [Float]?) -> Void)?
    var idleReleaseInterval: TimeInterval = Timing.idleReleaseDefault
    /// Veto for the idle-timeout release while a transcription is queued or running: the running engine is what
    /// keeps a backgrounded process alive through a long CPU-fallback job. Bounded, so a hung job cannot hold the mic.
    var shouldDeferIdleRelease: (() -> Bool)?
    private var idleDeferredSince: Date?
    private(set) var isRecording = false
    var isRunning: Bool { engine.isRunning }
    var recordedSampleCount: Int { tap.sampleCount }

    private var engine = AVAudioEngine()
    private let tap = TapState()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let callObserver = CXCallObserver()        // retain from launch: `.calls` fills in asynchronously
    private var sessionConfigured = false
    private var routeWentEmpty = false
    private var idleWork: DispatchWorkItem?
    private var idleSince: Date?
    private var observers: [NSObjectProtocol] = []

    init() { registerObservers() }

    var callActive: Bool { callObserver.calls.contains { !$0.hasEnded } }

    func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        if !sessionConfigured {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        }
        try s.setActive(true)
        sessionConfigured = true
        allowHaptics("configureSession")
    }

    func warmUp() throws {                               // STOPPED → IDLE
        guard !isRecording else { return }
        cancelIdleRelease()
        if engine.isRunning { allowHaptics("warmUp-running") } else { try startEngine() }
        scheduleIdleRelease()
    }

    func startRecording() throws {                       // IDLE/STOPPED → RECORDING
        if callActive { throw EngineError.callActive }
        cancelIdleRelease()
        idleDeferredSince = nil
        if !engine.isRunning { try startEngine() }
        tap.beginRecording()
        isRecording = true
        allowHaptics("startRecording")
    }

    /// RECORDING → IDLE. The engine keeps running: it is what keeps this process alive in the background.
    func collectSamples() -> [Float] {
        isRecording = false
        let samples = tap.endRecording()
        if engine.isRunning { scheduleIdleRelease() }
        return samples
    }

    func forceRestart() {                                // zombie engine (#72/#515): always rebuild
        cancelIdleRelease()
        replaceEngine()
        sessionConfigured = false
        do { try configureSession(); try startEngine() }
        catch { Log.error("audio", "forceRestart failed: \(error.localizedDescription)") }
    }

    func releaseWarmState(reason: String) {
        guard !isRecording, engine.isRunning || sessionConfigured else { return }
        Log.info("audio", "release warm state: \(reason)")
        tearDown(deactivate: true)
        onWarmStateEnded?(reason, nil)
    }

    func enforceIdleReleaseIfDue() {                     // call FIRST in didBecomeActive
        guard let idleSince, !isRecording, idleReleaseInterval.isFinite,
              Date().timeIntervalSince(idleSince) >= idleReleaseInterval else { return }
        releaseWarmState(reason: "wallClockBackstop")
    }

    /// Re-arm with a new interval (Settings change) without touching the engine.
    func rescheduleIdleRelease() { if engine.isRunning && !isRecording { scheduleIdleRelease() } }

    // MARK: engine

    private func startEngine() throws {
        if callActive { throw EngineError.callActive }                       // before the format read (#483)
        if routeWentEmpty {                                                   // #515
            let s = AVAudioSession.sharedInstance()
            var waitedMs = 0
            while s.currentRoute.inputs.isEmpty && waitedMs < 1000 { usleep(10_000); waitedMs += 10 }
            Log.info("audio", "empty-route recovery waited=\(waitedMs)ms, rebuilding engine")
            replaceEngine(); usleep(50_000)
        }
        var input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {              // #123/#457: the node is latched
            Log.error("audio", "dead input format sr=\(format.sampleRate) ch=\(format.channelCount), rebuilding")
            replaceEngine(); usleep(50_000)
            input = engine.inputNode
            format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw EngineError.hardwareUnavailable("sr=\(format.sampleRate) ch=\(format.channelCount)")
            }
        }
        input.removeTap(onBus: 0)                                            // stale tap → installTap crash
        let block = AudioEngine.makeTapBlock(tap, generation: tap.generation, target: target)
        do {
            try PWExceptionCatcher.run { input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: block) }
        } catch { throw EngineError.objc("installTap: \(error.localizedDescription)") }
        var startError: Error?
        let eng = engine
        do {
            try PWExceptionCatcher.run { do { try eng.start() } catch { startError = error } }
        } catch { input.removeTap(onBus: 0); throw EngineError.objc("start: \(error.localizedDescription)") }
        if let startError { input.removeTap(onBus: 0); throw startError }
        routeWentEmpty = false
        allowHaptics("startEngine")
        Log.info("audio", "engine started sr=\(format.sampleRate) ch=\(format.channelCount)")
    }

    /// The single primitive behind every recovery: a brand-new AVAudioEngine.
    private func replaceEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap.invalidate()                                  // bumps generation: old tap blocks bail out
        isRecording = false                               // reviewer: the gate must never stay "recording"
        engine = AVAudioEngine()
    }

    /// Built outside any actor, so Swift never infers @MainActor for a block the audio thread calls.
    nonisolated private static func makeTapBlock(_ tap: TapState, generation: UInt64,
                                                 target: AVAudioFormat) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.process(buffer, generation: generation, target: target) }
    }

    private func tearDown(deactivate: Bool) {
        cancelIdleRelease()
        idleDeferredSince = nil
        isRecording = false
        tap.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionConfigured = false
        }
    }

    private func allowHaptics(_ context: String) {
        do { try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true) }
        catch { Log.error("audio", "haptics allowance failed (\(context)): \(error.localizedDescription)") }
    }

    // MARK: idle release

    private func scheduleIdleRelease() {
        cancelIdleRelease()
        idleSince = Date()
        guard idleReleaseInterval.isFinite else { return }        // "Never"
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.shouldDeferIdleRelease?() == true {
                    let since = self.idleDeferredSince ?? Date()
                    self.idleDeferredSince = since
                    if Date().timeIntervalSince(since) < Timing.idleReleaseMaxDeferral {
                        Log.info("audio", "idle release deferred: transcription in flight")
                        self.scheduleIdleRelease(); return
                    }
                    Log.error("audio", "idle release deferral exceeded \(Int(Timing.idleReleaseMaxDeferral))s → releasing anyway")
                }
                self.releaseWarmState(reason: "idleTimeout")
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleReleaseInterval, execute: work)
    }
    private func cancelIdleRelease() { idleWork?.cancel(); idleWork = nil; idleSince = nil }
    /// Called by the controller when the last transcription finished: the idle countdown starts from real idleness.
    func transcriptionsDrained() {
        idleDeferredSince = nil
        rescheduleIdleRelease()
    }

    // MARK: session notifications

    private func registerObservers() {
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.handleInterruption(n) }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty {
                        self?.routeWentEmpty = true
                        Log.info("audio", "route change: no input")
                    }
                }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Log.error("audio", "media services were reset")
                    let salvaged = self.isRecording ? self.tap.endRecording() : nil
                    self.cancelIdleRelease(); self.replaceEngine(); self.sessionConfigured = false
                    self.onWarmStateEnded?("mediaServicesReset", salvaged)
                }
            },
            // The system stops AND uninitializes the engine when the I/O format changes (wired/USB-C mic, some
            // Bluetooth routes, CarPlay). The tap goes silent without an interruption: salvage and report it.
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, (n.object as AnyObject?) === self.engine else { return }
                    guard !self.engine.isRunning else {       // documented to stop the engine; if not, nothing broke
                        Log.info("audio", "engine configuration change while still running: ignored"); return
                    }
                    let salvaged = self.isRecording ? self.tap.endRecording() : nil
                    Log.info("audio", "engine configuration change (recording=\(salvaged != nil) samples=\(salvaged?.count ?? 0) running=\(self.engine.isRunning))")
                    self.tearDown(deactivate: false)
                    self.onWarmStateEnded?("engineConfigChange", salvaged)
                }
            },
        ]
    }

    private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            // Reviewer: keep what was said before the call; the controller transcribes it normally.
            let salvaged = isRecording ? tap.endRecording() : nil
            Log.info("audio", "interruption began (recording=\(isRecording) salvaged=\(salvaged?.count ?? 0))")
            tearDown(deactivate: false)            // iOS already deactivated us; a fresh start rebuilds later
            onWarmStateEnded?("interrupted", salvaged)
        } else {
            Log.info("audio", "interruption ended (no resume, #106)")
        }
    }
}
