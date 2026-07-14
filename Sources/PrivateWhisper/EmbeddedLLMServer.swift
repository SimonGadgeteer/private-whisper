import Foundation

/// Runs the bundled llama-server as a localhost sidecar so cleanup works
/// without LM Studio. Started on demand, health-checked, and terminated after
/// idling (frees ~3 GB RAM) or on app quit.
@MainActor
final class EmbeddedLLMServer {
    static let shared = EmbeddedLLMServer()

    nonisolated static let modelFileName = "Qwen3.5-4B-Q4_K_M.gguf"
    static var modelPath: URL { AppConfig.modelsDir.appendingPathComponent(modelFileName) }
    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    private var process: Process?
    private var port = 0
    private var idleTask: Task<Void, Never>?
    /// Idle window before the sidecar is stopped to reclaim memory.
    private let idleSeconds: Double = 600

    private var runningBaseURL: String? {
        guard let process, process.isRunning else { return nil }
        return "http://127.0.0.1:\(port)/v1"
    }

    /// Starts the sidecar if needed and returns its base URL once healthy.
    func ensureRunning() async -> String? {
        guard Self.isModelInstalled else { return nil }
        touchIdleTimer()
        if let url = runningBaseURL, await isHealthy() { return url }

        stop()
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "llama-server") else {
            dlog("embedded: llama-server binary not in bundle")
            return nil
        }
        port = Int.random(in: 49152..<65500)
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-m", Self.modelPath.path,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "-c", "8192",
            "-ngl", "99",
            // Disables Qwen thinking at the template level (llama-server's
            // --reasoning-budget 0 does NOT stop Qwen 3.5; this kwarg does).
            "--chat-template-kwargs", #"{"enable_thinking": false}"#,
            "--no-webui",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            dlog("embedded: failed to launch llama-server: \(error.localizedDescription)")
            return nil
        }
        process = proc
        dlog("embedded: llama-server starting on port \(port)")

        // Model load takes a few seconds; poll /health.
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await isHealthy() {
                touchIdleTimer()
                dlog("embedded: healthy")
                return runningBaseURL
            }
            if !proc.isRunning {
                dlog("embedded: llama-server exited during startup")
                process = nil
                return nil
            }
        }
        dlog("embedded: health check timed out")
        stop()
        return nil
    }

    func stop() {
        idleTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
            dlog("embedded: llama-server stopped")
        }
        process = nil
    }

    private func isHealthy() async -> Bool {
        guard let process, process.isRunning,
              let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func touchIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
            if !Task.isCancelled {
                dlog("embedded: idle — stopping to free memory")
                self.stop()
            }
        }
    }
}

extension CleanupService {
    /// Quick reachability probe with a short cache (avoids a 1 s stall on
    /// every dictation when LM Studio is down).
    private static var lastProbe: (url: String, reachable: Bool, at: Date)?

    static func isReachable(baseURL: String) async -> Bool {
        if let probe = lastProbe, probe.url == baseURL,
           Date().timeIntervalSince(probe.at) < 30 {
            return probe.reachable
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/models")) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let reachable = (try? await URLSession.shared.data(for: request)) != nil
        lastProbe = (baseURL, reachable, Date())
        return reachable
    }

    /// Backend resolution: LM Studio (local or remote Mac Mini) first, then
    /// the embedded sidecar, else nil (caller falls back to the raw transcript).
    @MainActor
    static func resolveBackend(config: AppConfig) async -> (baseURL: String, model: String)? {
        if await isReachable(baseURL: config.lmStudioURL) {
            return (config.lmStudioURL, config.cleanupModel)
        }
        if let embedded = await EmbeddedLLMServer.shared.ensureRunning() {
            return (embedded, "embedded")
        }
        return nil
    }
}
