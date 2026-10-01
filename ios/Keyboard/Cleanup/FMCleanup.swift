// Portions adapted from Dictus (https://github.com/getdictus/dictus-ios),
// DictusCore/Polish/AppleFoundationModelsPolishEngine.swift, PolishPipeline.swift, PolishAvailabilityGate.swift,
// PolishTimeBudget.swift, PolishContextBudget.swift. MIT License, Copyright (c) 2026 PIVI Solutions. See THIRD_PARTY_NOTICES.md.
//
// Runs ONLY in the keyboard while it is on screen (a backgrounded app gets `rateLimited`, Dictus #315/#361).
import FoundationModels
import Foundation
import NaturalLanguage

struct CleanupTimeout: Error {}
enum CleanupOutcome { case cleaned(String), raw(String, reason: String) }

/// Resolves with whichever comes first: op finishes, the deadline passes, or cancel(). Never waits for a cancelled op.
@MainActor final class Race<T> {
    private var cont: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    func run(seconds: Double, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            cont = c
            work = Task { @MainActor in
                do { let v = try await op(); self.finish(.success(v)) } catch { self.finish(.failure(error)) }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { self.finish(.failure(CleanupTimeout())) }
            }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ r: Result<T, Error>) {
        guard let c = cont else { return }
        cont = nil; work?.cancel(); timer?.cancel()
        c.resume(with: r)
    }
}

enum CleanupBudget {
    static func tokens(_ s: String) -> Int { Int((Double(s.count) / 4.9).rounded(.up)) }
    static func fits(instructions: String, input: String, window: Int) -> Bool {
        let i = tokens(input)
        return Int((Double(tokens(instructions) + 64 + i + Int((Double(i) * 1.8).rounded(.up))) * 1.15).rounded(.up)) <= window
    }
}

@MainActor final class FMCleanup {
    static let shared = FMCleanup()
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private var rateLimitStrikes = 0
    private var blockedUntil: Date?
    private var race: Race<String>?

    private var loggedVariant = false

    func cancel() { race?.cancel(); race = nil }

    /// On iOS 27, log the on-device model variant once per keyboard process (core3 expected on 8 GB).
    func logVariantOnce() {
        guard !loggedVariant else { return }
        loggedVariant = true
        if #available(iOS 27.0, *) {
            let name = SystemLanguageModel.default.variant.displayName
            AppGroup.defaults.set(name, forKey: Keys.fmVariant)
            Log.info("fm", "variant=\(name) availability=\(availabilitySlug()) context=\(model.contextSize)")
        } else {
            Log.info("fm", "availability=\(availabilitySlug())")
        }
    }

    func availabilitySlug() -> String {
        switch model.availability {
        case .available: return "available"
        case .unavailable(.appleIntelligenceNotEnabled): return "appleIntelligenceNotEnabled"
        case .unavailable(.modelNotReady): return "modelNotReady"
        case .unavailable(.deviceNotEligible): return "deviceNotEligible"
        default: return "other"
        }
    }

    func clean(raw: String, language: DictationLanguage, duration: TimeInterval, dictionary: [String]) async -> CleanupOutcome {
        cancel()                                                    // one in-flight call per process (N+1 cancels N)
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duration >= 2.0, input.split(whereSeparator: \.isWhitespace).count >= 4 else { return .raw(input, reason: "skippedShort") }
        AppGroup.defaults.set(availabilitySlug(), forKey: Keys.fmAvailability)
        guard case .available = model.availability else { return .raw(input, reason: "unavailable") }
        if let until = blockedUntil, until > Date() { return .raw(input, reason: "rateLimitedLatch") }
        // The language tag is what WhisperKit was forced to / detected, not proof of what the text is in (large-v3
        // turbo often writes English words under a forced "de"). Clean in — and check against — the language the
        // transcript is actually in, or "Never translate" plus the language guardrail would accept a translation.
        var lang = language
        let rec = NLLanguageRecognizer(); rec.languageConstraints = [.english, .german, .french]
        rec.processString(input)
        if let top = rec.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
           top.value >= 0.9, top.key.rawValue != language.nlCode {
            switch top.key.rawValue {
            case "en": lang = .en
            case "fr": lang = .fr
            default: lang = Settings.germanIsSwiss ? .gsw : .de
            }
            Log.info("fm", "input lang \(top.key.rawValue) != tag \(language.nlCode) → cleaning as \(lang.rawValue)")
        }
        let instructions = CleanupPrompt.instructions(language: lang, dictionary: dictionary)
        guard input.count <= 2_000,
              CleanupBudget.fits(instructions: instructions, input: input, window: model.contextSize) else {
            return .raw(input, reason: "tooLong")
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: CleanupBudget.tokens(input) * 5 / 2 + 48)
        let prompt = CleanupPrompt.userTurn(input)
        let deadline = min(20, max(6, 3 + 0.025 * Double(input.count)))
        let r = Race<String>(); race = r
        let started = Date()
        do {
            let text = try await r.run(seconds: deadline) { try await session.respond(to: prompt, options: options).content }
            if race === r { race = nil }
            rateLimitStrikes = 0
            let out = CleanupPrompt.stripEcho(text, input: input)
            Log.info("fm", "ok ms=\(Int(Date().timeIntervalSince(started) * 1000)) in=\(input.count) out=\(out.count) mem=\(physFootprintMB())")
            if let check = CleanupGuardrail.rejection(output: out, input: input, languageCode: lang.nlCode) {
                Log.info("fm", "guardrail rejected: \(check)")
                return .raw(input, reason: "guardrail.\(check)")
            }
            return .cleaned(out)
        } catch {
            if race === r { race = nil }
            let slug = FMErrors.slug(error)                         // never log debugDescription: it can quote the dictation
            Log.info("fm", "error=\(slug) ms=\(Int(Date().timeIntervalSince(started) * 1000)) in=\(input.count)")
            switch slug {                                           // spec §6.2: two CONSECUTIVE on-screen refusals
            case "rateLimited":
                // A refusal received while hidden says nothing about the on-screen keyboard (Dictus #315/#361).
                guard KeyboardState.shared.controller?.isAttachedToWindow == true else {
                    Log.info("fm", "rateLimited while hidden: not counted"); break
                }
                rateLimitStrikes += 1
                if rateLimitStrikes >= 2 {
                    blockedUntil = FMErrors.resetDate(error) ?? .distantFuture
                    Log.info("fm", "rate-limit latch set")
                }
            case "cancelled", "timeout":
                break                                               // our own cancel or deadline: no evidence either way
            default:
                rateLimitStrikes = 0                                // a different verdict breaks the run
            }
            return .raw(input, reason: slug)
        }
    }
}

enum FMErrors {
    static func slug(_ error: Error) -> String {
        if error is CleanupTimeout { return "timeout" }
        if error is CancellationError { return "cancelled" }
        if #available(iOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .rateLimited: return "rateLimited"
            case .contextSizeExceeded: return "contextSizeExceeded"
            case .guardrailViolation: return "guardrailViolation"
            case .refusal: return "refusal"
            case .timeout: return "timeout"
            case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
            default: return "lme.other"
            }
        }
        if let e = error as? LanguageModelSession.GenerationError {       // deprecated on 27, still thrown on 26
            switch e {
            case .rateLimited: return "rateLimited"
            case .exceededContextWindowSize: return "contextSizeExceeded"
            case .guardrailViolation: return "guardrailViolation"
            case .refusal: return "refusal"
            case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
            case .assetsUnavailable: return "assetsUnavailable"
            case .concurrentRequests: return "concurrentRequests"
            default: return "ge.other"
            }
        }
        return "other"
    }
    static func resetDate(_ error: Error) -> Date? {
        if #available(iOS 27.0, *), case .rateLimited(let r)? = error as? LanguageModelError { return r.resetDate }
        return nil
    }
}
