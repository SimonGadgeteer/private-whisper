// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusApp/DictationCoordinator.swift, DictusCore/ColdStartResolution.swift, DictusCore/DictationHandoff.swift,
// DictusApp/DictusApp.swift (handleIncomingURL), DictusCore/HostForegroundDebt.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
import UIKit
import AVFoundation

/// Holds a UIKit background task; the expiration handler may fire on the main actor at any time.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String, onExpire: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()
    @Published private(set) var status: DictationStatus = .idle
    @Published private(set) var session: SessionState = .dead
    @Published var showSwipeBack = false
    @Published var showPrepare = false
    @Published private(set) var lastError: String?
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var pendingCount = 0

    let audio = AudioEngine()
    let asr = ASREngine()
    private let d = AppGroup.defaults
    private var generation = 0                  // bumped on start AND abandon: late results never auto-insert (#267)
    private var userCancelledGeneration = -1
    private var pendingColdStart = false
    private var parkedRequestId: String?
    private var coldStartTask: BackgroundTask?
    private var hasBeenActive = false
    private var capWork: DispatchWorkItem?
    private var transcribeWork: DispatchWorkItem?
    private var transcribeJob: (gen: Int, seconds: Double, extended: Bool)?
    private var requestId: String?
    private var inFlight: Set<String> = []      // PendingAudio ids owned by a running job
    private var recoveringPending = false
    /// Requests the keyboard cancelled before this process started them (a late start or URL must never record them).
    private var cancelledRequestIds: [String] = []
    private var configRestarts: [Date] = []
    private var tickTimer: Timer?
    private var lastMem = (mb: 0, at: Date.distantPast)
    private var ticks = 0

    private init() {
        Log.rotateIfNeeded()
        Log.info("app", "launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") \(ProcessInfo.processInfo.operatingSystemVersionString) container=\(AppGroup.containerURL != nil) mem=\(physFootprintMB())MB")
        reconcileOrphanedState()
        Settings.modelVariant = Settings.modelVariant           // always written (reviewer: keyboard reads the same key)
        refreshModelState()
        audio.idleReleaseInterval = Settings.idleInterval
        audio.onWarmStateEnded = { [weak self] reason, salvaged in self?.warmStateEnded(reason, salvaged: salvaged) }
        audio.shouldDeferIdleRelease = { [weak self] in
            guard let self else { return false }
            return self.status == .transcribing || !self.inFlight.isEmpty
        }
        if AVAudioApplication.shared.recordPermission == .granted {  // still foreground at launch
            do { try audio.configureSession() } catch { Log.error("audio", "configureSession at launch: \(error.localizedDescription)") }
        }
        DarwinNotify.observe(DarwinName.start)  { onMain { SessionController.shared.darwinStart() } }
        DarwinNotify.observe(DarwinName.stop)   { onMain { SessionController.shared.consumeStop() } }
        DarwinNotify.observe(DarwinName.cancel) { onMain { SessionController.shared.consumeCancel() } }
        DarwinNotify.observe(DarwinName.result) { onMain { History.shared.mergeKeyboardResult() } }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.error("app", "memory warning mem=\(physFootprintMB())MB")
                self?.asr.unloadCPU()
            }
        }
        pendingCount = PendingAudio.list().count
        tickTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { SessionController.shared.tick() }
        }
    }

    // MARK: entry points

    func handleURL(_ url: URL, retried: Bool = false) {
        guard let parsed = DictationURL.parse(url) else { Log.error("session", "unrecognised URL"); return }
        Log.info("session", "url \(parsed.intent.rawValue) req=\(short(parsed.requestId)) state=\(appStateName)")
        switch parsed.intent {
        case .open: break
        case .prepare: showPrepare = true
        case .record:
            d.synchronize()
            let wasActive = UIApplication.shared.applicationState == .active
            // A late Darwin start already runs this request: keep the swipe-back UI, nothing else to do.
            if status == .recording || status == .transcribing, let r = parsed.requestId, r == requestId {
                hasBeenActive = true
                if !wasActive { showSwipeBack = true }
                Log.info("session", "record URL for \(short(r)) already running"); return
            }
            // Only a request the keyboard is still waiting on may start the mic (the URL is not authentication).
            let age = Date().timeIntervalSince1970 - d.double(forKey: Keys.requestAt)
            guard d.string(forKey: Keys.status) == DictationStatus.requested.rawValue,
                  let r = parsed.requestId, r == d.string(forKey: Keys.requestId),
                  !cancelledRequestIds.contains(r), age >= -1, age < Timing.coldGrace + 5 else {
                if !retried {                                  // cross-process lag: read once more after 100 ms
                    DispatchQueue.main.asyncAfter(deadline: .now() + Timing.transcriptRetry) {
                        MainActor.assumeIsolated { SessionController.shared.handleURL(url, retried: true) }
                    }
                    return
                }
                Log.info("session", "record URL for stale/cancelled req \(short(parsed.requestId)) ignored (status=\(d.string(forKey: Keys.status) ?? "nil") age=\(Int(age))s)")
                showSwipeBack = false; return
            }
            if !hasBeenActive || !audio.isRunning { d.set(true, forKey: Keys.coldStart); d.synchronize() }
            hasBeenActive = true
            if !wasActive { showSwipeBack = true }            // reviewer: no swipe-back screen if we were already on screen
            startDictation(fromURL: true, urlRequestId: r)
        }
    }

    private func didBecomeActive() {
        hasBeenActive = true
        Log.rotateIfNeeded()
        audio.idleReleaseInterval = Settings.idleInterval
        audio.enforceIdleReleaseIfDue()                   // BEFORE any warm-up
        refreshModelState()
        if pendingColdStart {
            pendingColdStart = false
            d.synchronize()
            if d.string(forKey: Keys.status) == DictationStatus.requested.rawValue {
                startDictation(fromURL: true, urlRequestId: parkedRequestId)
            } else {
                Log.info("session", "parked start dropped: status=\(d.string(forKey: Keys.status) ?? "nil")")
            }
            return
        }
        asr.unloadCPU()                                   // CPU fallback instance is for background work only
        asr.resetBackgroundPolicy()
        recoverPendingAudio()
        Task { await warmUp() }
    }

    func warmUp() async {
        guard AVAudioApplication.shared.recordPermission == .granted, asr.isInstalled else { return }
        if status == .recording && !audio.isRunning {      // the system stopped the engine mid-recording: keep the audio
            Log.error("audio", "recording without a running engine → stopping (engineLost)")
            stopDictation(trigger: "engineLost", autoInsert: false)
        }
        if !audio.isRunning {
            setSession(.warming)
            do {                                                                               // audio first (~100 ms) …
                try audio.configureSession(); try audio.warmUp()
                setSession(audio.isRunning ? (status == .transcribing ? .transcribing : .warmIdle) : .dead)
            }
            catch { Log.error("session", "warmUp: \(error.localizedDescription)"); setSession(.dead) }
        } else if !audio.isRecording {
            try? audio.warmUp()                                                            // re-arms idle release
        }
        guard !asr.isLoaded else { return }
        if ModelWarmth.isWarm(asr.variant) {
            // Spec §5.2: ModelWarmth cannot see a purged Core ML cache. A "warm" load past 10 s is a compile:
            // clear the flag (keyboard → prepare, background jobs → cpu-cold) and show the prepare screen, which
            // joins this same coalesced load (it owns the idle timer).
            let v = asr.variant
            let slow = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
                guard let self, !self.asr.isLoaded, self.asr.isLoading else { return }
                Log.error("asr", "warm load of \(v) > \(Int(Timing.slowLoadIsCompile))s → treating as compile (cache evicted)")
                ModelWarmth.clear(v)
                if UIApplication.shared.applicationState == .active { self.showPrepare = true }
            } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.slowLoadIsCompile, execute: slow)
            do { try await asr.load() } catch { Log.error("asr", "warm load failed: \(error.localizedDescription)") }   // … model second
            slow.cancel()
        } else {
            // Reviewer: never compile silently; show the prepare screen with the idle timer disabled.
            Log.info("asr", "Core ML cache cold for \(asr.variant) → prepare screen")
            showPrepare = true
        }
    }

    func didEnterBackground() {
        showSwipeBack = false
        if pendingColdStart {                                      // #311: user swiped back before .active
            pendingColdStart = false
            d.synchronize()
            guard d.string(forKey: Keys.status) == DictationStatus.requested.rawValue else { return }
            Log.info("session", "last-chance start in background (#311)")
            coldStartTask = BackgroundTask("pw.coldStartLastChance") { [weak self] in self?.coldStartTask = nil }
            startDictation(fromURL: true, allowInactive: true, urlRequestId: parkedRequestId)
            if status != .recording {
                endColdStartTask()
                if status != .failed { fail("Dictation could not start. Tap the microphone again.") }
            }
            return
        }
        if !status.isActive { d.set(false, forKey: Keys.coldStart); d.synchronize() }
    }

    // MARK: Darwin receivers

    /// Spec §3.2/§4.5: start only a request the keyboard is still waiting on (`requested`, tap < 2 s old), with the
    /// id that passed the check. One retry after 100 ms for cross-process lag; then ignore — the keyboard's 500 ms
    /// URL fallback covers every start dropped here.
    private func darwinStart(retried: Bool = false) {
        d.synchronize()
        let age = Date().timeIntervalSince1970 - d.double(forKey: Keys.requestAt)
        guard d.string(forKey: Keys.status) == DictationStatus.requested.rawValue, age >= -1, age < 2,
              let rid = d.string(forKey: Keys.requestId) else {
            if !retried {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.transcriptRetry) {
                    MainActor.assumeIsolated { SessionController.shared.darwinStart(retried: true) }
                }
            } else {
                Log.info("session", "Darwin start ignored (status=\(d.string(forKey: Keys.status) ?? "nil") age=\(String(format: "%.1f", age))s)")
            }
            return
        }
        startDictation(urlRequestId: rid)
    }

    private func consumeStop() {
        guard let target = consume(Keys.stopRequested, idKey: Keys.stopRequestId) else { return }
        if let current = requestId, let target, target != current {
            // A stop during a recording is never meant for another live recording: if it names the keyboard's
            // current request, the app started under a stale id — stop under the keyboard's id.
            d.synchronize()
            guard status == .recording, target == d.string(forKey: Keys.requestId) else {
                Log.info("session", "stop for \(short(target)) ignored (current \(short(current)))"); return
            }
            Log.error("session", "stop for \(short(target)) while recording under \(short(current)) → adopting the keyboard's id")
            requestId = target
        }
        stopDictation(trigger: "keyboard")
    }

    private func consumeCancel() {
        guard let target = consume(Keys.cancelRequested, idKey: Keys.cancelRequestId) else { return }
        if let target { rememberCancelled(target) }
        if let current = requestId, let target, target != current {
            d.synchronize()
            if pendingColdStart, parkedRequestId == target {
                pendingColdStart = false
                Log.info("session", "parked start \(short(target)) cancelled")
            }
            guard status == .recording, target == d.string(forKey: Keys.requestId) else {
                Log.info("session", "cancel for \(short(target)) ignored (current \(short(current)))"); return
            }
            Log.error("session", "cancel for \(short(target)) while recording under \(short(current)) → honoured")
        }
        let byUser = d.object(forKey: Keys.cancelByUser) as? Bool ?? true
        cancelDictation(byUser: byUser)
    }

    private func rememberCancelled(_ id: String) {
        cancelledRequestIds.removeAll { $0 == id }
        cancelledRequestIds.append(id)
        if cancelledRequestIds.count > 16 { cancelledRequestIds.removeFirst(cancelledRequestIds.count - 16) }
    }

    /// Consume-before-act (Darwin can deliver twice). Returns nil when the flag was not set, else the target id.
    private func consume(_ flag: String, idKey: String) -> String?? {
        d.synchronize()
        guard d.bool(forKey: flag) else { return nil }
        let target = d.string(forKey: idKey)
        d.set(false, forKey: flag); d.synchronize()
        return .some(target)
    }

    // MARK: dictation

    func startDictation(fromURL: Bool = false, allowInactive: Bool = false, urlRequestId: String? = nil) {
        d.synchronize()
        let rid = urlRequestId ?? d.string(forKey: Keys.requestId)
        if let rid, cancelledRequestIds.contains(rid) {
            Log.info("session", "start for cancelled \(short(rid)) refused"); return
        }
        if status == .recording || status == .transcribing {
            if rid != nil && rid == requestId { Log.info("session", "duplicate start for \(short(rid)) ignored"); return }
            // The keyboard abandoned the previous request; the new one supersedes it. Never throw captured speech
            // away: a superseded recording is transcribed into History + "Insert last" (a late transcription too).
            Log.info("session", "start \(short(rid)) supersedes \(short(requestId)) in \(status.rawValue)")
            let oldRid = requestId
            let old: [Float]? = (status == .recording && audio.isRecording) ? audio.collectSamples() : nil
            generation += 1
            capWork?.cancel()
            if let old { salvage(old, rid: oldRid, reason: "superseded") }
        }
        let appState = UIApplication.shared.applicationState
        if !fromURL && appState != .active && !audio.isRunning {
            // iOS won't start an engine from the background; the keyboard's 500 ms URL fallback takes over.
            Log.info("session", "Darwin start refused: engine not running in \(appStateName)")
            return
        }
        guard asr.isInstalled else {
            fail("Open Private Whisper to finish setup.")
            if appState == .active { showPrepare = true }
            return
        }
        if !asr.isLoaded && !ModelWarmth.isWarm(asr.variant) {
            fail("The speech model needs preparing. Open Private Whisper and keep it open for a few minutes.")
            if appState == .active { showPrepare = true }
            return
        }
        if !audio.isRunning && appState != .active && !allowInactive {
            pendingColdStart = true; parkedRequestId = rid                  // URL launches arrive .inactive (#73)
            Log.info("session", "start parked until active (#73)")
            return
        }
        generation += 1
        let gen = generation
        requestId = rid
        do {
            guard AVAudioApplication.shared.recordPermission == .granted else { throw AudioEngine.EngineError.permissionDenied }
            try audio.configureSession()
            try audio.startRecording()
        } catch {
            endColdStartTask()
            fail(error.localizedDescription)
            return
        }
        endColdStartTask()                                 // audio background mode holds the process from here
        recordingStartedAt = Date()
        setStatus(.recording); setSession(.recording)
        Log.info("session", "recording req=\(short(rid)) fromURL=\(fromURL) state=\(appStateName)")
        armRecordingCap(gen)
        Task { await verifyAudioFlow(gen) }
        if !asr.isLoaded { Task { _ = try? await asr.load() } }  // cold start: load while the user talks
    }

    /// Never drops a stop (reviewer): the gate always closes and the samples always go somewhere.
    func stopDictation(trigger: String, autoInsert: Bool = true) {
        guard status == .recording else {
            Log.info("session", "stop (\(trigger)) in status \(status.rawValue)")
            if audio.isRecording { _ = audio.collectSamples() }
            if pendingColdStart { pendingColdStart = false; fail("Recording had not started yet. Tap the microphone again.") }
            else { setStatus(status) }                     // re-post so the keyboard reconciles
            return
        }
        capWork?.cancel()
        let samples = audio.collectSamples()               // engine stays running
        process(samples, gen: generation, rid: requestId, stopAt: Date(), trigger: trigger, autoInsert: autoInsert)
    }

    private func process(_ samples: [Float], gen: Int, rid: String?, stopAt: Date, trigger: String, autoInsert: Bool = true) {
        let seconds = Double(samples.count) / 16_000
        let wall = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Log.info("session", "stop trigger=\(trigger) audio=\(String(format: "%.2f", seconds))s wall=\(String(format: "%.2f", wall))s req=\(short(rid))")
        guard samples.count >= Timing.minClipSamples else {
            fail("Too short. Hold the microphone a little longer."); return
        }
        setStatus(.transcribing)
        if audio.isRunning { setSession(.transcribing) }
        // Queue bound from enqueue (a job ahead in the FIFO may be slow); the normal budget starts when this job
        // actually leaves the queue (onStart), so queue time never counts as "took too long".
        armTranscribeWatchdog(gen, seconds: seconds, timeout: Timing.cpuFallbackTimeout(audioSeconds: seconds) + 60)
        let lang = Settings.language, swiss = Settings.germanIsSwiss   // one snapshot: live attempt AND saved clip
        let jobId = rid ?? UUID().uuidString
        inFlight.insert(jobId)
        let bg = BackgroundTask("pw.transcribe") { [weak self] in
            Log.error("session", "transcribe background task expired req=\(short(rid)); audio kept for the next foreground")
            if let self, gen == self.generation, self.status == .transcribing {
                self.generation += 1
                self.fail("Couldn't finish in the background. Open Private Whisper to finish.")
            }
            Log.flush()
        }
        Task {
            defer {
                inFlight.remove(jobId)
                pendingCount = PendingAudio.list().count
                if audio.isRunning, session == .transcribing || session == .dead, status != .recording { setSession(.warmIdle) }
                if inFlight.isEmpty && audio.isRunning && !audio.isRecording { audio.transcriptionsDrained() }
                bg.end()
            }
            await PendingAudio.save(samples, id: jobId, language: lang, germanIsSwiss: swiss)   // BEFORE transcribing (reviewer)
            do {
                let t = try await asr.transcribe(samples, language: lang, germanIsSwiss: swiss, dictionary: Settings.dictionary,
                    onStart: {
                        guard gen == self.generation, self.status == .transcribing else { return }
                        self.armTranscribeWatchdog(gen, seconds: seconds)
                    },
                    onFallback: { self.extendTranscribeWatchdog(gen) })   // singleton: strong capture is fine
                let timing = AppTiming(audioSeconds: seconds, stopReceivedAt: stopAt.timeIntervalSince1970,
                                       asrDoneAt: Date().timeIntervalSince1970, asrMs: t.asrMs, model: t.model,
                                       computePath: t.computePath, fallback: t.fallback)
                Log.info("timing", "app req=\(short(rid)) audio=\(String(format: "%.2f", seconds))s stop→asr=\(Int((timing.asrDoneAt - timing.stopReceivedAt) * 1000))ms asr=\(t.asrMs)ms model=\(t.model) path=\(t.computePath) chars=\(t.text.count)")
                if gen == userCancelledGeneration { Log.info("session", "result of a user-cancelled dictation dropped"); PendingAudio.remove(jobId); return }
                if !t.text.isEmpty { History.shared.add(raw: t.text, language: t.language, requestId: rid, source: "keyboard", timing: timing) }
                let suspicious = t.text.isEmpty && ASREngine.hasSpeechEnergy(samples)
                if suspicious {                                                  // empty for speech-level audio: keep it
                    Log.error("session", "empty result for speech-level audio req=\(short(rid)) → kept in pending for recovery")
                } else {
                    PendingAudio.remove(jobId)                                  // History has it (or it was silence)
                }
                guard !t.text.isEmpty else {
                    if gen == generation {
                        fail(suspicious ? "No text recognised. The audio was kept: open Private Whisper to retry."
                                        : "No speech detected.")
                    }
                    return
                }
                if gen == generation {
                    handOff(t, duration: seconds, requestId: rid, timing: timing, auto: autoInsert)
                } else {
                    Log.info("session", "late result req=\(short(rid)) → History + \"Insert last dictation\"")
                    handOff(t, duration: seconds, requestId: rid, timing: timing, auto: false, late: true)
                }
            } catch {
                Log.error("session", "transcription failed req=\(short(rid)): \(ASREngine.describe(error).prefix(300)) — audio kept in pending")
                guard gen == generation else { return }
                if UIApplication.shared.applicationState != .active {
                    fail("Couldn't transcribe in the background. Open Private Whisper to finish.")
                } else {
                    fail("Transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelDictation(byUser: Bool) {
        Log.info("session", "cancel byUser=\(byUser) status=\(status.rawValue) req=\(short(requestId))")
        // Only a user cancel discards audio; a watchdog cancel keeps what was said (History + "Insert last").
        let oldRid = requestId
        let salvaged: [Float]? = (!byUser && status == .recording && audio.isRecording) ? audio.collectSamples() : nil
        if byUser { userCancelledGeneration = generation }
        generation += 1
        capWork?.cancel()
        pendingColdStart = false
        showSwipeBack = false
        if audio.isRecording { _ = audio.collectSamples() }
        setStatus(.idle)
        cleanupRecordingKeys()
        if let salvaged { salvage(salvaged, rid: oldRid, reason: "watchdogCancel") }
    }

    /// "Stop listening" button: a running recording is stopped (kept in History) before the warm session is released.
    func stopListening() {
        Log.info("session", "stopListening status=\(status.rawValue) recording=\(audio.isRecording)")
        if status == .recording || audio.isRecording { stopDictation(trigger: "stopListening", autoInsert: false) }
        audio.releaseWarmState(reason: "user")
    }

    /// Status-neutral job for audio whose dictation was superseded or abandoned: PendingAudio → transcribe → History →
    /// late hand-off ("Insert last"). Never touches status, session, the watchdog or `generation`. Serial with every
    /// other job (ASREngine FIFO). If transcription fails the file stays in PendingAudio for foreground recovery.
    private func salvage(_ samples: [Float], rid: String?, reason: String) {
        let seconds = Double(samples.count) / 16_000
        guard samples.count >= Timing.minClipSamples else {
            Log.info("session", "\(reason): \(String(format: "%.2f", seconds))s of \(short(rid)) too short to keep"); return
        }
        let jobId = rid ?? UUID().uuidString
        let lang = Settings.language, swiss = Settings.germanIsSwiss
        let stopAt = Date()
        Log.info("session", "\(reason): keeping \(String(format: "%.1f", seconds))s of \(short(rid)) → History + Insert last")
        inFlight.insert(jobId)
        let bg = BackgroundTask("pw.salvage") {
            Log.error("session", "salvage background task expired req=\(short(rid)); audio kept in pending"); Log.flush()
        }
        Task {
            defer {
                inFlight.remove(jobId)
                pendingCount = PendingAudio.list().count
                if inFlight.isEmpty && audio.isRunning && !audio.isRecording { audio.transcriptionsDrained() }
                bg.end()
            }
            await PendingAudio.save(samples, id: jobId, language: lang, germanIsSwiss: swiss)
            do {
                let t = try await asr.transcribe(samples, language: lang, germanIsSwiss: swiss, dictionary: Settings.dictionary)
                guard !t.text.isEmpty else {
                    if !ASREngine.hasSpeechEnergy(samples) { PendingAudio.remove(jobId) }
                    Log.info("session", "\(reason) \(short(rid)): empty result"); return
                }
                let timing = AppTiming(audioSeconds: seconds, stopReceivedAt: stopAt.timeIntervalSince1970,
                                       asrDoneAt: Date().timeIntervalSince1970, asrMs: t.asrMs, model: t.model,
                                       computePath: t.computePath, fallback: t.fallback)
                History.shared.add(raw: t.text, language: t.language, requestId: rid, source: reason, timing: timing)
                PendingAudio.remove(jobId)
                handOff(t, duration: seconds, requestId: rid, timing: timing, auto: false, late: true)
            } catch {
                Log.error("session", "\(reason) transcription of \(short(rid)) failed, kept in pending: \(ASREngine.describe(error).prefix(200))")
            }
        }
    }

    // MARK: hand-off (write order matters)

    private func handOff(_ t: ASREngine.Transcript, duration: Double, requestId: String?, timing: AppTiming,
                         auto: Bool, late: Bool = false) {
        d.set(t.text, forKey: Keys.transcript)
        d.set(requestId, forKey: Keys.transcriptRequestId)
        d.set(t.language.rawValue, forKey: Keys.transcriptLanguage)
        d.set(duration, forKey: Keys.transcriptDuration)
        d.set(Date().timeIntervalSince1970, forKey: Keys.transcriptAt)
        d.set(auto, forKey: Keys.transcriptAuto)
        d.setCodable(timing, forKey: Keys.transcriptTiming)
        if late {
            d.synchronize()                                // status untouched: the dictation already failed/moved on
        } else {
            setStatus(.ready)                              // synchronize + post status
        }
        DarwinNotify.post(DarwinName.transcript)
        if !late { cleanupRecordingKeys() }
    }

    // MARK: helpers

    private func setStatus(_ s: DictationStatus) {
        // Invariant (reviewer, #60): only `.recording` may leave the gate open; the session follows.
        if s != .recording && audio.isRecording { _ = audio.collectSamples() }
        if s != .recording && s != .transcribing && (session == .recording || session == .transcribing) {
            setSession(audio.isRunning ? .warmIdle : .dead)
        }
        if s != .recording { recordingStartedAt = nil }
        status = s
        d.set(s.rawValue, forKey: Keys.status); d.synchronize()
        DarwinNotify.post(DarwinName.status)
    }
    private func setSession(_ s: SessionState) { session = s; d.set(s.rawValue, forKey: Keys.session); d.synchronize() }

    private func fail(_ message: String) {
        Log.error("session", "failed: \(message)")
        lastError = message
        showSwipeBack = false
        d.set(message, forKey: Keys.error)
        setStatus(.failed)
        cleanupRecordingKeys()
    }

    private func warmStateEnded(_ reason: String, salvaged: [Float]?) {
        Log.info("session", "warm state ended: \(reason) status=\(status.rawValue) salvaged=\(salvaged?.count ?? 0)")
        if status == .recording {
            capWork?.cancel()
            if let s = salvaged, s.count >= Timing.minClipSamples {
                // Reviewer: a call mid-sentence keeps what was said — transcribe it under the background task.
                process(s, gen: generation, rid: requestId, stopAt: Date(), trigger: reason)
            } else {
                generation += 1
                fail("Recording stopped (\(reason)). Tap the microphone again.")
            }
        }
        setSession(.dead)
        if status != .transcribing { d.removeObject(forKey: Keys.heartbeat) }
        d.synchronize()
        if reason == "idleTimeout" || reason == "user" || reason == "wallClockBackstop" { asr.unloadCPU() }
        DarwinNotify.post(DarwinName.released)
        if reason == "engineConfigChange" { rewarmAfterConfigChange() }
    }

    /// The session is still active after an engine configuration change, so a restart usually works (not yet
    /// device-proven in the background). Runs after the route settles and the `released` post has gone out.
    private func rewarmAfterConfigChange() {
        let now = Date()
        configRestarts = configRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard configRestarts.count <= 3 else {
            Log.error("audio", "engine configuration changes keep coming: not re-warming (session stays dead)"); return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let s = SessionController.shared
                guard AVAudioApplication.shared.recordPermission == .granted, !s.audio.isRunning, s.status != .recording else { return }
                do {
                    try s.audio.warmUp()
                    if s.audio.isRunning { s.setSession(s.status == .transcribing ? .transcribing : .warmIdle) }
                    Log.info("audio", "re-warmed after configuration change running=\(s.audio.isRunning)")
                } catch {
                    Log.error("audio", "re-warm after configuration change failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cleanupRecordingKeys() {                  // never clears pw.transcript (keyboard reads it async)
        [Keys.level, Keys.elapsed].forEach { d.removeObject(forKey: $0) }
        [Keys.stopRequested, Keys.cancelRequested, Keys.coldStart].forEach { d.set(false, forKey: $0) }
        d.synchronize()
    }

    private func reconcileOrphanedState() {                // launch hygiene (#261)
        if let s = d.string(forKey: Keys.status).flatMap(DictationStatus.init(rawValue:)), s == .recording || s == .transcribing {
            Log.info("session", "launch: orphaned status \(s.rawValue) → idle")
            d.set(DictationStatus.idle.rawValue, forKey: Keys.status)       // never touch .requested
        }
        d.set(SessionState.dead.rawValue, forKey: Keys.session)
        d.removeObject(forKey: Keys.heartbeat)
        if Date().timeIntervalSince1970 - d.double(forKey: Keys.transcriptAt) > Timing.transcriptSweepAge {
            [Keys.transcript, Keys.transcriptRequestId, Keys.transcriptAt, Keys.transcriptTiming].forEach { d.removeObject(forKey: $0) }
        }
        d.synchronize()
        DarwinNotify.post(DarwinName.status)
    }

    func refreshModelState() {
        let current = d.string(forKey: Keys.modelState).flatMap(ModelState.init(rawValue:))
        if current == .downloading || current == .compiling, ModelSetup.shared.isBusy { return }
        let s: ModelState = asr.isInstalled ? .installed : .notInstalled
        if current != s { d.set(s.rawValue, forKey: Keys.modelState); d.synchronize() }
    }

    private func verifyAudioFlow(_ gen: Int) async {       // zombie engine (#72)
        try? await Task.sleep(for: .seconds(Timing.zeroSampleCheck))
        guard gen == generation, status == .recording, audio.recordedSampleCount == 0 else { return }
        Log.error("audio", "no samples after \(Timing.zeroSampleCheck)s → forceRestart")
        audio.forceRestart()
        do { try audio.startRecording() } catch {
            fail("Microphone stopped responding.")
            audio.releaseWarmState(reason: "zeroSamples")   // reviewer: next tap takes the URL with a fresh engine
            return
        }
        try? await Task.sleep(for: .seconds(Timing.zeroSampleCheck))
        guard gen == generation, status == .recording else { return }
        if audio.recordedSampleCount == 0 {
            fail("Microphone stopped responding. Open Private Whisper and try again.")
            audio.releaseWarmState(reason: "zeroSamples")
        }
    }

    private func armRecordingCap(_ gen: Int) {
        capWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, gen == self.generation, self.status == .recording else { return }
            self.stopDictation(trigger: "cap")
        } }
        capWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.recordingCap, execute: w)
    }

    private func armTranscribeWatchdog(_ gen: Int, seconds: Double, timeout: TimeInterval? = nil) {
        transcribeWork?.cancel()
        let limit = timeout ?? Timing.transcribeTimeout(audioSeconds: seconds)
        if transcribeJob?.gen != gen { transcribeJob = (gen, seconds, false) }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, gen == self.generation, self.status == .transcribing else { return }
            Log.error("session", "transcription watchdog fired after \(Int(limit))s (fallback=\(self.asr.inFallback))")
            self.generation += 1                       // the late result still lands in History (+ "Insert last")
            self.fail("Transcription took too long. The text will appear in History.")
        } }
        transcribeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: w)
    }

    /// The CPU-only retry is slower by design: give it its own budget once (only for the job that fell back).
    private func extendTranscribeWatchdog(_ gen: Int) {
        guard let job = transcribeJob, !job.extended, job.gen == gen, gen == generation, status == .transcribing else { return }
        transcribeJob = (job.gen, job.seconds, true)
        let limit = Timing.cpuFallbackTimeout(audioSeconds: job.seconds)
        Log.info("session", "CPU fallback running → watchdog extended to \(Int(limit))s")
        armTranscribeWatchdog(job.gen, seconds: job.seconds, timeout: limit)
    }

    private func endColdStartTask() { coldStartTask?.end(); coldStartTask = nil }

    /// Every 3 s: keep the keyboard's liveness proof alive while transcribing without an engine (interrupted
    /// dictation), and log the footprint when it moves (reviewer: memory soak data).
    private func tick() {
        ticks += 1
        if status == .transcribing && !audio.isRunning {
            d.set(Date().timeIntervalSince1970, forKey: Keys.heartbeat)
        }
        if status == .recording {
            d.synchronize()
            if d.bool(forKey: Keys.stopRequested) {        // a lost Darwin ping or a stale read costs at most 3 s
                Log.info("session", "stop flag found by poll")
                consumeStop()
            }
        }
        if status == .recording && !audio.isRunning {       // any silent engine stop: salvage, never a 5-min zombie
            Log.error("audio", "engine stopped mid-recording → stopping (engineLost)")
            stopDictation(trigger: "engineLost")
        }
        guard ticks % 20 == 0 else { return }               // once a minute
        let mb = physFootprintMB()
        if abs(mb - lastMem.mb) >= 25 || Date().timeIntervalSince(lastMem.at) >= 600 {
            lastMem = (mb, Date())
            Log.info("mem", "footprint=\(mb)MB session=\(session.rawValue) state=\(appStateName) model=\(asr.isLoaded) cpuKit=\(asr.cpuKitLoaded)")
        }
    }

    // MARK: pending audio (foreground recovery)

    func recoverPendingAudio() {
        guard !recoveringPending, UIApplication.shared.applicationState == .active else { return }
        let items = PendingAudio.list().filter { !inFlight.contains($0.id) }
        pendingCount = PendingAudio.list().count
        guard !items.isEmpty, asr.isInstalled else { return }
        recoveringPending = true
        Log.info("pending", "recovering \(items.count) utterance(s) in the foreground")
        Task {
            defer {
                recoveringPending = false; pendingCount = PendingAudio.list().count
                if inFlight.isEmpty && audio.isRunning && !audio.isRecording { audio.transcriptionsDrained() }
            }
            for item in items {
                // Foreground only, and never ahead of a live dictation: the rest waits for the next activation
                // (or the "Finish N saved recordings" button).
                guard UIApplication.shared.applicationState == .active, status != .recording, status != .transcribing else {
                    Log.info("pending", "recovery paused (left foreground / live dictation); rest kept"); break
                }
                if History.shared.contains(requestId: item.id) { PendingAudio.remove(item.id); continue }
                guard let samples = PendingAudio.load(item) else { Log.error("pending", "unreadable \(short(item.id))"); PendingAudio.remove(item.id); continue }
                inFlight.insert(item.id)
                defer { inFlight.remove(item.id) }
                do {
                    // The language settings of the dictation itself, never the chip as it is now (forced wrong language
                    // token = translation). Older files without them: detect, then force.
                    let t = try await asr.transcribe(samples, language: item.language,
                                                     germanIsSwiss: item.germanIsSwiss, dictionary: Settings.dictionary)
                    if !t.text.isEmpty {
                        let timing = AppTiming(audioSeconds: Double(samples.count) / 16_000, stopReceivedAt: item.modified.timeIntervalSince1970,
                                               asrDoneAt: Date().timeIntervalSince1970, asrMs: t.asrMs, model: t.model,
                                               computePath: t.computePath, fallback: t.fallback)
                        History.shared.add(raw: t.text, language: t.language, requestId: item.id, source: "recovered", timing: timing)
                        if UIApplication.shared.applicationState == .active { UIPasteboard.general.string = t.text }
                    }
                    PendingAudio.remove(item.id)
                    Log.info("pending", "recovered \(short(item.id)) path=\(t.computePath) asr=\(t.asrMs)ms empty=\(t.text.isEmpty)")
                } catch {
                    Log.error("pending", "recovery of \(short(item.id)) failed, kept: \(ASREngine.describe(error).prefix(200))")
                }
            }
        }
    }

    private var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

