import Foundation

/// Downloads whisper models into the support dir on first run, so the app can
/// be distributed without bundling gigabytes of weights.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    static let sources: [String: (url: String, size: String)] = [
        "large-v3-turbo": (
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            "1.5 GB"),
        "large-v3": (
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
            "2.9 GB"),
    ]

    private var destination: URL?
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    static func isInstalled(_ model: String) -> Bool {
        FileManager.default.fileExists(
            atPath: AppConfig.modelsDir.appendingPathComponent("ggml-\(model).bin").path)
    }

    func download(model: String) {
        guard !downloading, let source = Self.sources[model],
              let url = URL(string: source.url) else { return }
        DispatchQueue.main.async {
            self.downloading = true
            self.progress = 0
            self.errorMessage = nil
        }
        destination = AppConfig.modelsDir.appendingPathComponent("ggml-\(model).bin")
        try? FileManager.default.createDirectory(
            at: AppConfig.modelsDir, withIntermediateDirectories: true)
        session.downloadTask(with: url).resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = fraction }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.downloading = false
                self.progress = 1
            }
            dlog("Model downloaded: \(destination.lastPathComponent)")
        } catch {
            DispatchQueue.main.async {
                self.downloading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.downloading = false
            self.errorMessage = error.localizedDescription
        }
    }
}
