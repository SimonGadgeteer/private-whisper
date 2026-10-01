// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusKeyboard/KeyboardState.swift (IPC subset: startRecording, markRequested, watchdog, openDictusURL),
// DictusKeyboard/KeyboardPolishCoordinator.swift, DictusCore/PendingDictation.swift.
// MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// A process singleton: iOS creates many controller instances per dictation (#281), so all state lives here and
// the controller is held weakly (#134). The pending cleanup lives in memory only (spec §0).
import UIKit
import CallKit

@MainActor
final class KeyboardState: ObservableObject {
    enum Phase: String { case idle, requested, recording, transcribing, cleaning
        var waitsOnApp: Bool { self == .requested || self == .recording || self == .transcribing }
    }
    struct Pending {
        let requestId: String
        let raw: String
        let language: DictationLanguage
        let duration: Double
        let documentId: UUID?
        let claimedAt: Date
        let timing: AppTiming?
        let stopTapAt: Date?
        let userInitiated: Bool
    }

    static let shared = KeyboardState()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var message: String?
    @Published private(set) var language: DictationLanguage = Settings.language
    @Published private(set) var insertableLast = false
    @Published private(set) var hasFullAccess = true
    @Published private(set) var needsGlobe = false

    weak var controller: UIInputViewController?
    /// SwiftUI's openURL, re-captured by the root view on every appearance.
    var openURL: ((URL) -> Void)?

    private let d = AppGroup.defaults
    private let callObserver = CXCallObserver()
    private var requestId: String?
    private var lastTap = Date.distantPast
    private var lastSignal = Date()
    private var requestedAt = Date()
    private var openedURLForRequest = false
    private var tapDocumentId: UUID?
    private var stopTapAt: Date?
    private var abandonedRequestId: String?
    private var watchdog: Timer?
    private var messageWork: DispatchWorkItem?
    /// Spec §6.7/§8.3: after a URL bounce the target field is re-read once on the first return appearance.
    private var reanchorOnReturn = false
    private var detachedSinceURL = false
    /// Adopted a `transcribing` dictation in a rebuilt keyboard process: nobody tapped in this field, so the
    /// result goes to "Insert last", never auto-inserts.
    private var adoptedWithoutStop = false
    private var pending: Pending?
    private var attachedSinceClaim = false
    private var lastFinal: (text: String, requestId: String)?

    private init() {
        DarwinNotify.observe(DarwinName.status) { onMain { KeyboardState.shared.refresh() } }
        DarwinNotify.observe(DarwinName.transcript) { onMain { KeyboardState.shared.handleTranscriptReady() } }
        DarwinNotify.observe(DarwinName.level) { onMain { KeyboardState.shared.onLevel() } }
        DarwinNotify.observe(DarwinName.released) { onMain { Log.info("kb", "app released its warm session") } }
        Log.info("kb", "process start mem=\(physFootprintMB())MB container=\(AppGroup.containerURL != nil)")
    }

    // MARK: lifecycle

    func attach(_ c: UIInputViewController) {
        controller = c
        hasFullAccess = c.hasFullAccess
        needsGlobe = c.needsInputModeSwitchKey
        d.synchronize()
        language = Settings.language
        if let p = pending, let doc = PWTextProxy.documentIdentifier(of: c.textDocumentProxy), doc == p.documentId {
            attachedSinceClaim = true
        }
        // A nil read, or an appearance before the bounce, keeps the flag armed.
        if reanchorOnReturn, detachedSinceURL, phase.waitsOnApp, let doc = PWTextProxy.documentIdentifier(of: c.textDocumentProxy) {
            Log.info("kb", "re-anchored after the URL bounce (field changed=\(doc != tapDocumentId))")
            tapDocumentId = doc; reanchorOnReturn = false
        }
        refresh()
    }

    func detached(_ c: UIInputViewController) {
        guard c === controller else { return }
        attachedSinceClaim = false
        if reanchorOnReturn { detachedSinceURL = true }
    }

    // MARK: app state

    func refresh() {
        d.synchronize()
        let status = d.string(forKey: Keys.status).flatMap(DictationStatus.init(rawValue:))
        adoptIfLive(status)
        switch status {
        case .recording?:
            if phase == .requested || phase == .recording {
                if phase != .recording { Log.info("kb", "recording confirmed after \(ms(since: requestedAt))ms") }
                phase = .recording; lastSignal = Date()
            }
        case .transcribing?:
            if phase.waitsOnApp { phase = .transcribing; lastSignal = Date() }
        case .ready?:
            handleTranscriptReady()
        case .failed?:
            if phase.waitsOnApp {                                   // phase gating already shows one message per failure
                if let e = d.string(forKey: Keys.error) { show(e) }
                setLocalIdle()
            }
        case .idle?:
            // After the bounce the app owns the request, so its `idle` is terminal even while we still say `requested`
            // (e.g. Cancel on the swipe-back screen). The warm path keeps its 500 ms fallback / 3 s deadline instead.
            if phase == .recording || phase == .transcribing || (phase == .requested && openedURLForRequest) {
                Log.info("kb", "app went idle (cancelled) phase=\(phase.rawValue)"); setLocalIdle()
            }
        default: break
        }
        updateInsertableLast()
    }

    /// iOS rebuilds the keyboard process routinely (#261); a new process must follow a live dictation instead of
    /// showing an idle mic whose tap would start (and supersede) a new one.
    @discardableResult
    private func adoptIfLive(_ status: DictationStatus?) -> Bool {
        guard phase == .idle, let s = status, s == .recording || s == .transcribing,
              Liveness.evaluate(status: s, heartbeat: d.object(forKey: Keys.heartbeat) as? Double,
                                requestAt: d.object(forKey: Keys.requestAt) as? Double,
                                now: Date().timeIntervalSince1970) == .live,
              let rid = d.string(forKey: Keys.requestId), rid != abandonedRequestId else { return false }
        Log.info("kb", "adopting live \(s.rawValue) req=\(short(rid)) (rebuilt keyboard)")
        requestId = rid
        phase = s == .recording ? .recording : .transcribing
        openedURLForRequest = true; reanchorOnReturn = false
        requestedAt = Date(); lastSignal = Date(); stopTapAt = nil
        tapDocumentId = controller.flatMap { PWTextProxy.documentIdentifier(of: $0.textDocumentProxy) }
        adoptedWithoutStop = (s == .transcribing)
        startWatchdog()
        return true
    }

    private func onLevel() {
        if phase == .idle { refresh() }                              // first level ping can adopt a live recording
        level = d.float(forKey: Keys.level)
        elapsed = d.double(forKey: Keys.elapsed)
        lastSignal = Date()
        if phase == .requested { phase = .recording }
    }

    // MARK: user actions

    func micTapped() {
        switch phase {
        case .recording: requestStop(); return
        case .requested: requestCancel(); return
        case .transcribing: show("Still transcribing…"); return
        case .cleaning: flushActiveAsRaw()                        // N+1: insert N's raw now, then continue
        case .idle:
            d.synchronize()                                        // a tap before any ping reached this process
            if adoptIfLive(d.string(forKey: Keys.status).flatMap(DictationStatus.init(rawValue:))) { micTapped(); return }
        }
        guard let controller, controller.hasFullAccess else { show("Turn on Allow Full Access for Private Whisper."); return }
        let now = Date()
        guard now.timeIntervalSince(lastTap) >= Timing.micDebounce else { return }
        lastTap = now
        guard !callObserver.calls.contains(where: { !$0.hasEnded }) else { show("Dictation is paused during calls."); return }
        d.synchronize()
        let variant = Settings.modelVariant
        guard d.string(forKey: Keys.modelState) == ModelState.installed.rawValue, ModelWarmth.isWarm(variant) else {
            Log.info("kb", "model not ready (state=\(d.string(forKey: Keys.modelState) ?? "nil") warm=\(ModelWarmth.isWarm(variant))) → prepare")
            open(DictationURL.make(.prepare)); return             // never start a 4-min compile from a tap (#542)
        }
        let req = UUID().uuidString
        d.set(req, forKey: Keys.requestId)
        d.set(now.timeIntervalSince1970, forKey: Keys.requestAt)
        d.set(DictationStatus.requested.rawValue, forKey: Keys.status)
        d.removeObject(forKey: Keys.error)
        d.set(false, forKey: Keys.stopRequested); d.set(false, forKey: Keys.cancelRequested)
        d.synchronize()
        requestId = req; phase = .requested; requestedAt = now; lastSignal = now
        openedURLForRequest = false; stopTapAt = nil; level = 0; elapsed = 0
        reanchorOnReturn = false; detachedSinceURL = false; adoptedWithoutStop = false
        tapDocumentId = PWTextProxy.documentIdentifier(of: controller.textDocumentProxy)
        startWatchdog()
        let session = d.string(forKey: Keys.session).flatMap(SessionState.init(rawValue:))
        let heartbeat = d.object(forKey: Keys.heartbeat) as? Double
        if Liveness.shouldSkipDarwin(session: session, heartbeat: heartbeat, now: now.timeIntervalSince1970) {
            Log.info("kb", "tap req=\(short(req)) cold (session=\(session?.rawValue ?? "nil")) → URL")
            openRecordURL(req); return
        }
        Log.info("kb", "tap req=\(short(req)) warm=\(Liveness.appLooksWarm(session: session, heartbeat: heartbeat, now: now.timeIntervalSince1970)) → Darwin start")
        DarwinNotify.post(DarwinName.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.darwinFallback) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .requested, self.requestId == req else { return }
                self.d.synchronize()
                guard self.d.string(forKey: Keys.status) == DictationStatus.requested.rawValue else { self.refresh(); return }
                Log.info("kb", "no answer to Darwin start in \(Int(Timing.darwinFallback * 1000))ms → URL")
                self.openRecordURL(req)                                   // app alive but engine dead
            }
        }
    }

    func requestStop() {
        // The field where the user pressed stop is the target if no return appearance re-anchored yet.
        if reanchorOnReturn, let c = controller, let doc = PWTextProxy.documentIdentifier(of: c.textDocumentProxy) {
            tapDocumentId = doc; reanchorOnReturn = false
        }
        adoptedWithoutStop = false
        sendStop()
        stopTapAt = Date(); lastSignal = Date()
        phase = .transcribing
        Log.info("kb", "stop req=\(short(requestId)) after \(String(format: "%.1f", elapsed))s")
    }

    private func sendStop() {
        d.set(requestId, forKey: Keys.stopRequestId)
        d.set(true, forKey: Keys.stopRequested); d.synchronize()     // flag first, then ping
        DarwinNotify.post(DarwinName.stop)
    }

    func requestCancel() {
        Log.info("kb", "cancel by user phase=\(phase.rawValue)")
        if phase == .cleaning { FMCleanup.shared.cancel(); pending = nil }
        if phase.waitsOnApp { postCancel(byUser: true) }
        abandonedRequestId = requestId
        setLocalIdle()
    }

    func cycleLanguage() {
        language = language.next
        Settings.language = language
    }

    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
    func insert(_ s: String) { controller?.textDocumentProxy.insertText(s) }

    func openApp() { open(DictationURL.make(.open)) }

    // MARK: watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Timing.watchdogTick, repeats: true) { _ in
            MainActor.assumeIsolated { KeyboardState.shared.watchdogTick() }
        }
    }
    private func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    private func watchdogTick() {
        guard phase.waitsOnApp else { stopWatchdog(); return }
        refresh()                                                     // a missed status ping must never cause an abandon
        guard phase.waitsOnApp else { return }
        let now = Date().timeIntervalSince1970
        if phase == .requested {
            // Reviewer: `requested` has a hard deadline that ignores the (idle) heartbeat.
            let limit = (openedURLForRequest || d.bool(forKey: Keys.coldStart)) ? Timing.coldGrace : Timing.requestedWarmDeadline
            if Date().timeIntervalSince(requestedAt) > limit { abandon("Couldn't start. Open Private Whisper and try again.") }
            return
        }
        // Spec §8.3: a stop is re-sent every second while the app still says `recording` (a missed flag read or
        // ping must not leave the mic running). Given up locally after 5 s WITHOUT a cancel: a cancel would discard
        // the audio, and the app's cap / stop poll still lands it in History + "Insert last".
        if phase == .transcribing, let t = stopTapAt, d.string(forKey: Keys.status) == DictationStatus.recording.rawValue {
            let waited = Date().timeIntervalSince(t)
            if waited > Timing.stopUnanswered {
                Log.error("kb", "stop unanswered \(Int(waited))s req=\(short(requestId))")
                abandonedRequestId = requestId
                show("Private Whisper didn't stop. Open it to finish.")
                setLocalIdle(); return
            }
            if waited >= Timing.watchdogTick {
                Log.info("kb", "status still recording \(ms(since: t))ms after stop → re-sending stop")
                sendStop()
            }
        }
        let verdict = Liveness.evaluate(status: d.string(forKey: Keys.status).flatMap(DictationStatus.init(rawValue:)),
                                        heartbeat: d.object(forKey: Keys.heartbeat) as? Double,
                                        requestAt: d.object(forKey: Keys.requestAt) as? Double, now: now)
        if verdict == .orphaned { abandon("Recording interrupted. Please try again."); return }
        let limit = d.bool(forKey: Keys.coldStart) ? Timing.coldGrace : Timing.watchdogStale
        guard Date().timeIntervalSince(lastSignal) > limit else { return }
        if let hb = d.object(forKey: Keys.heartbeat) as? Double, now - hb < limit { lastSignal = Date(); return }
        abandon(phase == .recording ? "Recording interrupted. Please try again." : "Private Whisper stopped responding. Please try again.")
    }

    private func abandon(_ message: String) {
        Log.error("kb", "watchdog abandon phase=\(phase.rawValue) req=\(short(requestId)): \(message)")
        postCancel(byUser: false)                                     // any active phase; cancel is idempotent
        abandonedRequestId = requestId                                // a late transcript becomes "Insert last"
        d.set(DictationStatus.idle.rawValue, forKey: Keys.status)
        [Keys.level, Keys.elapsed].forEach { d.removeObject(forKey: $0) }
        d.synchronize()
        DarwinNotify.post(DarwinName.status)
        show(message)
        setLocalIdle()
    }

    private func postCancel(byUser: Bool) {
        d.set(requestId, forKey: Keys.cancelRequestId)
        d.set(byUser, forKey: Keys.cancelByUser)
        d.set(true, forKey: Keys.cancelRequested)
        if phase == .requested { d.set(DictationStatus.idle.rawValue, forKey: Keys.status) }   // a parked start must not fire later
        d.synchronize()
        DarwinNotify.post(DarwinName.cancel)
        if phase == .requested { DarwinNotify.post(DarwinName.status) }
    }

    private func setLocalIdle() {
        phase = .idle; level = 0; elapsed = 0
        stopWatchdog()
    }

    // MARK: transcript claim (spec §8.3, reviewer minor on wrong-field inserts)

    func handleTranscriptReady(retry: Bool = true) {
        d.synchronize()
        guard let text = d.string(forKey: Keys.transcript), !text.isEmpty else {
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.transcriptRetry) {
                    MainActor.assumeIsolated { KeyboardState.shared.handleTranscriptReady(retry: false) }
                }
            }
            return
        }
        let rid = d.string(forKey: Keys.transcriptRequestId)
        let age = Date().timeIntervalSince1970 - d.double(forKey: Keys.transcriptAt)
        let auto = d.object(forKey: Keys.transcriptAuto) as? Bool ?? true
        let mine = rid != nil && rid == requestId && rid != abandonedRequestId
        let attached = controller?.isAttachedToWindow ?? false
        guard mine, auto, !adoptedWithoutStop, phase.waitsOnApp, age < Timing.transcriptClaimMaxAge, attached else {
            Log.info("kb", "transcript \(short(rid)) not auto-inserted (mine=\(mine) auto=\(auto) adopted=\(adoptedWithoutStop) phase=\(phase.rawValue) age=\(Int(age))s attached=\(attached)) → Insert last")
            if mine && phase.waitsOnApp { setLocalIdle() }
            updateInsertableLast()
            return
        }
        // Both paths (warm and after a URL bounce): the text only goes into the anchored field.
        guard let tapDoc = tapDocumentId, let c = controller, PWTextProxy.documentIdentifier(of: c.textDocumentProxy) == tapDoc else {
            Log.info("kb", "field differs from the anchor (or no anchor, opened URL=\(openedURLForRequest)) → Insert last")
            setLocalIdle(); updateInsertableLast(); return
        }
        claim(text: text, requestId: rid!, userInitiated: false)
    }

    /// "Insert last dictation": the user asked explicitly, so the tap-time document check is skipped.
    func claimLast() {
        if let lf = lastFinal {
            lastFinal = nil
            guard let c = controller else { return }
            c.textDocumentProxy.insertText(TextPost.spaced(lf.text, before: c.textDocumentProxy.documentContextBeforeInput))
            writeResult(KeyboardResult(requestId: lf.requestId, text: lf.text, cleaned: false, inserted: true,
                                       reason: "insertLast", at: Date().timeIntervalSince1970))
            updateInsertableLast()
            return
        }
        d.synchronize()
        guard let text = d.string(forKey: Keys.transcript), !text.isEmpty,
              Date().timeIntervalSince1970 - d.double(forKey: Keys.transcriptAt) < Timing.transcriptSweepAge else {
            updateInsertableLast(); return
        }
        if phase == .cleaning { flushActiveAsRaw() }
        claim(text: text, requestId: d.string(forKey: Keys.transcriptRequestId) ?? UUID().uuidString, userInitiated: true)
    }

    private func claim(text: String, requestId rid: String, userInitiated: Bool) {
        let lang = d.string(forKey: Keys.transcriptLanguage).flatMap(DictationLanguage.init(rawValue:)) ?? .de
        let duration = d.double(forKey: Keys.transcriptDuration)
        let timing = d.codable(AppTiming.self, forKey: Keys.transcriptTiming)
        d.removeObject(forKey: Keys.transcript)                        // claim BEFORE acting (double delivery)
        d.synchronize()
        let doc = controller.flatMap { PWTextProxy.documentIdentifier(of: $0.textDocumentProxy) }
        let p = Pending(requestId: rid, raw: text, language: lang, duration: duration, documentId: doc, claimedAt: Date(),
                        timing: timing, stopTapAt: rid == requestId ? stopTapAt : nil, userInitiated: userInitiated)
        pending = p
        attachedSinceClaim = true
        stopWatchdog()
        phase = .cleaning
        updateInsertableLast()
        Log.info("kb", "claim req=\(short(rid)) chars=\(text.count) lang=\(lang.rawValue) doc=\(doc != nil) user=\(userInitiated) mem=\(physFootprintMB())MB")
        Task { await runCleanup(p) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Log.info("kb", "mem 30s after claim=\(physFootprintMB())MB") }
    }

    private func runCleanup(_ p: Pending) async {
        let started = Date()
        let outcome: CleanupOutcome
        if !Settings.cleanupEnabled {
            outcome = .raw(p.raw, reason: "disabled")
        } else {
            Log.info("kb", "mem before FM=\(physFootprintMB())MB")
            outcome = await FMCleanup.shared.clean(raw: p.raw, language: p.language, duration: p.duration,
                                                   dictionary: Settings.dictionary)
            Log.info("kb", "mem after FM=\(physFootprintMB())MB")
        }
        guard pending?.requestId == p.requestId else { Log.info("kb", "cleanup result for \(short(p.requestId)) superseded"); return }
        pending = nil
        switch outcome {
        case .cleaned(let t): finish(p, text: t, cleaned: true, reason: "cleaned", cleanupMs: ms(since: started))
        case .raw(let t, let reason): finish(p, text: t, cleaned: false, reason: reason, cleanupMs: ms(since: started))
        }
    }

    /// "Insert raw now", or a new mic tap while cleaning (spec §6.7).
    func flushActiveAsRaw() {
        guard let p = pending else { return }
        pending = nil
        FMCleanup.shared.cancel()
        finish(p, text: p.raw, cleaned: false, reason: "flushedRaw", cleanupMs: ms(since: p.claimedAt))
    }

    private func finish(_ p: Pending, text: String, cleaned: Bool, reason: String, cleanupMs: Int) {
        let final = TextPost.finalize(text, language: p.language, dictionary: Settings.dictionary)
        let inserted = gateAndInsert(final, p)
        if !inserted { lastFinal = (final, p.requestId) }
        let insertAt = Date().timeIntervalSince1970
        let stopRef = p.stopTapAt?.timeIntervalSince1970 ?? p.timing?.stopReceivedAt
        let stopToInsert = stopRef.map { Int((insertAt - $0) * 1000) }
        var result = KeyboardResult(requestId: p.requestId, text: final, cleaned: cleaned, inserted: inserted,
                                    reason: reason, at: insertAt)
        result.cleanupMs = cleanupMs
        result.stopToInsertMs = stopToInsert
        writeResult(result)
        let t = p.timing
        let stopToAsr: String = {
            guard let t, let stopRef else { return "–" }
            return "\(Int((t.asrDoneAt - stopRef) * 1000))"
        }()
        Log.info("timing", "req=\(short(p.requestId)) audio=\(String(format: "%.2f", t?.audioSeconds ?? p.duration))s model=\(t?.model ?? "?") path=\(t?.computePath ?? "?") stop→asr=\(stopToAsr)ms asr=\(t.map { "\($0.asrMs)" } ?? "–")ms cleanup=\(cleanupMs)ms stop→insert=\(stopToInsert.map(String.init) ?? "–")ms cleaned=\(cleaned) reason=\(reason) inserted=\(inserted)")
        if phase == .cleaning { phase = .idle }
        d.synchronize()
        if d.string(forKey: Keys.status) == DictationStatus.ready.rawValue {
            d.set(DictationStatus.idle.rawValue, forKey: Keys.status); d.synchronize()
            DarwinNotify.post(DarwinName.status)
        }
        if !cleaned && reason != "disabled" && reason != "skippedShort" { show("Inserted without cleanup (\(reason))", subtle: true) }
        updateInsertableLast()
    }

    /// The text must never land in the wrong place (spec §6.7).
    private func gateAndInsert(_ text: String, _ p: Pending) -> Bool {
        guard let c = controller else { Log.info("kb", "gate: no controller"); return false }
        let doc = PWTextProxy.documentIdentifier(of: c.textDocumentProxy)
        let window = c.isAttachedToWindow
        guard attachedSinceClaim, window, let doc, doc == p.documentId else {
            Log.info("kb", "gate refused req=\(short(p.requestId)) attachedSinceClaim=\(attachedSinceClaim) window=\(window) doc=\(doc != nil) match=\(doc != nil && doc == p.documentId)")
            return false
        }
        c.textDocumentProxy.insertText(TextPost.spaced(text, before: c.textDocumentProxy.documentContextBeforeInput))
        return true
    }

    private func writeResult(_ r: KeyboardResult) {
        d.setCodable(r, forKey: Keys.lastResult); d.synchronize()
        DarwinNotify.post(DarwinName.result)
    }

    private func updateInsertableLast() {
        if lastFinal != nil { insertableLast = true; return }
        let has = (d.string(forKey: Keys.transcript)?.isEmpty == false)
            && Date().timeIntervalSince1970 - d.double(forKey: Keys.transcriptAt) < Timing.transcriptSweepAge
        insertableLast = has && phase != .cleaning
    }

    // MARK: helpers

    private func openRecordURL(_ req: String) {
        openedURLForRequest = true
        reanchorOnReturn = true; detachedSinceURL = false
        open(DictationURL.make(.record, requestId: req))
    }

    /// Dictus's two-step open: the extension context first; SwiftUI openURL when it reports failure.
    private func open(_ url: URL) {
        if let ctx = controller?.extensionContext {
            ctx.open(url) { ok in
                if !ok {
                    onMain {
                        Log.info("kb", "extensionContext.open returned false → SwiftUI openURL")
                        KeyboardState.shared.openURL?(url)
                    }
                }
            }
        } else {
            openURL?(url)
        }
    }

    func show(_ text: String, subtle: Bool = false) {
        message = text
        messageWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.message = nil } }
        messageWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (subtle ? 2.5 : 4), execute: w)
    }

    private func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
}
