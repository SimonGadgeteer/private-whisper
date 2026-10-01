// Model download + first compile, foreground only (spec §5.2, reviewer minor on onboarding fragility).
// - Download uses WhisperKit's background URLSession so a short app switch does not stall 630 MB.
// - The first load compiles for the ANE (~4 min) AND fetches the tokenizer (needs the network once);
//   network/tokenizer failures are reported separately from compile failures.
// - Leaving mid-compile: the same task keeps running and is awaited again on return, never restarted (#472).
import UIKit
import os

@MainActor
final class ModelSetup: ObservableObject {
    enum FailureKind { case network, compile }
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case compiling(Date)
        case ready
        case failed(FailureKind, String)
    }

    static let shared = ModelSetup()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fallbackMessage: String?
    private var task: Task<Void, Never>?
    private var lastProgressWrite = Date.distantPast

    var isBusy: Bool { task != nil }
    /// Observable (unlike `task`): disables the model picker while a download or compile runs.
    var isWorking: Bool {
        switch phase { case .downloading, .compiling: return true; default: return false }
    }
    private var asr: ASREngine { SessionController.shared.asr }
    private let d = AppGroup.defaults

    private init() {}

    /// Download (if needed) and prepare the current variant.
    func installAndPrepare() {
        guard task == nil else { return }
        let v = Settings.modelVariant
        task = Task {
            defer { task = nil }
            if !ASREngine.isInstalled(v) {
                guard await download(v) else { return }
            }
            guard await fetchTokenizer(v) else { return }
            await compile(v)
        }
    }

    /// Compile only (cold Core ML cache after reinstall / iOS update). Joins a running task.
    func prepare() {
        guard task == nil else { return }
        let v = Settings.modelVariant
        guard ASREngine.isInstalled(v) else { installAndPrepare(); return }
        task = Task { defer { task = nil }; guard await fetchTokenizer(v) else { return }; await compile(v) }
    }

    func useAlternative() {
        let other = Settings.modelVariant == ModelCatalog.primary ? ModelCatalog.alternative : ModelCatalog.primary
        switchVariant(to: other)
        installAndPrepare()
    }

    func switchVariant(to v: String) {
        guard v != Settings.modelVariant else { return }
        Log.info("model", "variant \(Settings.modelVariant) → \(v)")
        Settings.modelVariant = v
        asr.unload()
        phase = .idle
        d.set((ASREngine.isInstalled(v) ? ModelState.installed : .notInstalled).rawValue, forKey: Keys.modelState)
        d.synchronize()
    }

    func redownload() {
        guard task == nil else { return }
        let v = Settings.modelVariant
        asr.unload()
        try? FileManager.default.removeItem(at: ASREngine.folder(v))
        installAndPrepare()
    }

    /// Optional smaller model for the background CPU-only fallback. Loads it once online (tokenizer).
    func installCPUFallback(_ v: String) {
        guard task == nil else { return }
        fallbackMessage = "Downloading \(ModelCatalog.displayName(v))…"
        task = Task {
            defer { task = nil }
            do {
                if !ASREngine.isInstalled(v) {
                    try await asr.download(variant: v) { p in
                        Task { @MainActor in ModelSetup.shared.fallbackMessage = "Downloading… \(Int(p * 100))%" }
                    }
                }
                try? await asr.prefetchTokenizer(v)             // optional: the CPU load fetches it too
                fallbackMessage = "Loading once on CPU…"
                try await asr.primeCPUFallback(v)
                Settings.cpuFallbackVariant = v
                fallbackMessage = "\(ModelCatalog.displayName(v)) ready as background fallback."
                Log.info("model", "CPU fallback model \(v) installed")
            } catch {
                fallbackMessage = "Failed: \(error.localizedDescription)"
                Log.error("model", "CPU fallback install failed: \(ASREngine.describe(error).prefix(300))")
            }
        }
    }

    // MARK: steps

    private func download(_ v: String) async -> Bool {
        phase = .downloading(0)
        setState(.downloading)
        d.set(0.0, forKey: Keys.modelProgress)
        Log.info("model", "download \(v) start")
        let started = Date()
        do {
            try await asr.download(variant: v) { p in
                Task { @MainActor in ModelSetup.shared.progress(p) }
            }
            Log.info("model", "download \(v) done in \(Int(Date().timeIntervalSince(started)))s")
            return true
        } catch {
            Log.error("model", "download failed: \(ASREngine.describe(error).prefix(300))")
            phase = .failed(.network, "Download failed: \(error.localizedDescription). Check Wi-Fi and retry.")
            setState(.failed)
            return false
        }
    }

    /// Spec §5.2 step 1: the tokenizer before the compile, so an offline Prepare fails in a second, not after 4 min.
    private func fetchTokenizer(_ v: String) async -> Bool {
        do {
            try await asr.prefetchTokenizer(v)
            return true
        } catch {
            Log.error("model", "tokenizer fetch failed: \(ASREngine.describe(error).prefix(300))")
            phase = .failed(.network, "No internet connection. The tokenizer is needed once. Connect and retry.")
            setState(ASREngine.isInstalled(v) ? .installed : .failed)
            return false
        }
    }

    private func progress(_ p: Double) {
        if case .downloading = phase { phase = .downloading(p) }
        if Date().timeIntervalSince(lastProgressWrite) > 0.5 || p >= 1 {
            lastProgressWrite = Date()
            d.set(p, forKey: Keys.modelProgress)
        }
    }

    private func compile(_ v: String) async {
        let started = Date()
        phase = .compiling(started)
        setState(.compiling)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        Log.info("model", "prepare \(v) (foreground compile) mem=\(physFootprintMB())MB avail=\(os_proc_available_memory() / 1_048_576)MB")
        do {
            try await asr.load(v)
            Log.info("model", "prepare \(v) OK in \(Int(Date().timeIntervalSince(started)))s mem=\(physFootprintMB())MB avail=\(os_proc_available_memory() / 1_048_576)MB")
            guard Settings.modelVariant == v else {              // the user picked another model meanwhile: never revert it
                Log.info("model", "prepared \(v) but the selected variant is now \(Settings.modelVariant)")
                phase = .idle
                return
            }
            setState(.installed)
            phase = .ready
            SessionController.shared.showPrepare = false
            await SessionController.shared.warmUp()        // reviewer: warm the engine as soon as install completes
        } catch {
            let desc = ASREngine.describe(error)
            let network = error is URLError || desc.contains("NSURLErrorDomain") || desc.lowercased().contains("tokenizer")
            Log.error("model", "prepare failed (\(network ? "network/tokenizer" : "compile")) after \(Int(Date().timeIntervalSince(started)))s: \(desc.prefix(300))")
            phase = .failed(network ? .network : .compile,
                            network ? "Couldn't fetch the tokenizer. Connect to the internet once and retry."
                                    : "Preparing the model failed: \(error.localizedDescription)")
            setState(ASREngine.isInstalled(v) ? .installed : .failed)
        }
    }

    private func setState(_ s: ModelState) { d.set(s.rawValue, forKey: Keys.modelState); d.synchronize() }
}
