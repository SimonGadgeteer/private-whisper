import Foundation

/// Sends the raw transcript to LM Studio's OpenAI-compatible endpoint for the
/// cleanup pass. Any failure (unreachable, timeout, bad response) throws — the
/// pipeline falls back to the raw transcript so dictation is never lost.
struct CleanupService {
    var baseURL: String
    var model: String
    var timeout: TimeInterval

    static let systemPrompt = """
        You clean up dictated text. Rules:
        - Output ONLY the cleaned text. No preamble, no quotes, no commentary.
        - Keep the same language as the input (German stays German, French stays French, English stays English).
        - Remove filler words (um, äh, also, alors, you know), false starts, and repetitions.
        - Fix punctuation, capitalization, and obvious transcription errors.
        - Preserve meaning, tone, names, numbers, and technical terms exactly.
        - Do not summarize, do not expand, do not translate.
        """

    enum CleanupError: Error, LocalizedError {
        case badURL
        case badResponse(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid LM Studio URL"
            case .badResponse(let detail): return "LM Studio error: \(detail)"
            case .emptyResult: return "LM Studio returned an empty result"
            }
        }
    }

    func cleanup(transcript: String, language: String?) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/chat/completions")) else { throw CleanupError.badURL }

        var systemPrompt = Self.systemPrompt
        if let language, language != "unknown" {
            systemPrompt += "\n- The input language is \"\(language)\". The output must be in that same language."
        }
        // Qwen3 hybrid models honor /no_think; without it they burn seconds of
        // latency "thinking" about a filler-word removal. Harmless elsewhere.
        if model.localizedCaseInsensitiveContains("qwen") {
            systemPrompt += "\n/no_think"
        }

        // PRD: max_tokens sized to input length × 1.5 (≈3 chars/token heuristic),
        // plus fixed headroom for reasoning models that "think" before answering
        // (e.g. Qwen 3.5) — otherwise they hit the cap mid-thought and return
        // empty content. Non-thinking models just stop early, so this is free.
        let maxTokens = max(256, Int(Double(transcript.count) / 3.0 * 1.5) + 64) + 2048

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? "HTTP error"
            throw CleanupError.badResponse(detail)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw CleanupError.badResponse("unexpected response shape")
        }

        let cleaned = Self.stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CleanupError.emptyResult }
        return cleaned
    }

    /// Removes <think>…</think> blocks that reasoning models may emit.
    static func stripReasoning(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        // Unterminated think block (hit max_tokens mid-reasoning) → nothing usable.
        if let range = result.range(of: "<think>") {
            result = String(result[..<range.lowerBound])
        }
        return result
    }

    /// Fetches available model IDs from LM Studio (for the settings dropdown).
    static func availableModels(baseURL: String) async -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/models")) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["id"] as? String }
    }
}
