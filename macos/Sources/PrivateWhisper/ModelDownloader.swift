import Foundation

/// Downloads model weights into the support dir on first run, so the app can
/// be distributed without bundling gigabytes. Supports multiple items with
/// per-item progress (whisper models + the embedded cleanup LLM).
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    struct Item {
        let url: String
        let fileName: String
        let size: String
        let label: String
    }

    struct State {
        var downloading = false
        var progress: Double = 0
        var error: String?
    }

    /// Keyed by item id: whisper model names + "cleanup-llm".
    static let items: [String: Item] = [
        "large-v3-turbo": Item(
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            fileName: "ggml-large-v3-turbo.bin", size: "1.5 GB",
            label: "Transcription model (Whisper large-v3-turbo)"),
        "large-v3": Item(
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
            fileName: "ggml-large-v3.bin", size: "2.9 GB",
            label: "Transcription model (Whisper large-v3)"),
        "cleanup-llm": Item(
            url: "https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
            fileName: EmbeddedLLMServer.modelFileName, size: "2.7 GB",
            label: "Cleanup model (Qwen 3.5 4B, embedded)"),
    ]

    @Published var states: [String: State] = [:]

    private var taskKeys: [Int: String] = [:]
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    static func isInstalled(_ key: String) -> Bool {
        guard let item = items[key] else { return false }
        return FileManager.default.fileExists(
            atPath: AppConfig.modelsDir.appendingPathComponent(item.fileName).path)
    }

    func state(_ key: String) -> State { states[key] ?? State() }

    func download(_ key: String) {
        guard let item = Self.items[key], let url = URL(string: item.url),
              !(states[key]?.downloading ?? false) else { return }
        DispatchQueue.main.async {
            self.states[key] = State(downloading: true, progress: 0, error: nil)
        }
        try? FileManager.default.createDirectory(
            at: AppConfig.modelsDir, withIntermediateDirectories: true)
        let task = session.downloadTask(with: url)
        taskKeys[task.taskIdentifier] = key
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let key = taskKeys[downloadTask.taskIdentifier] else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.states[key]?.progress = fraction
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = taskKeys[downloadTask.taskIdentifier],
              let item = Self.items[key] else { return }
        let destination = AppConfig.modelsDir.appendingPathComponent(item.fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.states[key] = State(downloading: false, progress: 1, error: nil)
            }
            dlog("Model downloaded: \(item.fileName)")
        } catch {
            DispatchQueue.main.async {
                self.states[key] = State(
                    downloading: false, progress: 0, error: error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = taskKeys[task.taskIdentifier] else { return }
        DispatchQueue.main.async {
            self.states[key] = State(
                downloading: false, progress: 0, error: error.localizedDescription)
        }
    }
}
