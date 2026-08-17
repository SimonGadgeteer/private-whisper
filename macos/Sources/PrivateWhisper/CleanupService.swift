import Foundation

/// Talks to LM Studio's OpenAI-compatible endpoint for the cleanup pass and
/// command-mode rewrites. Any failure (unreachable, timeout, bad response)
/// throws — the pipeline falls back to the raw transcript so dictation is
/// never lost.
struct CleanupService {
    var baseURL: String
    var model: String
    var timeout: TimeInterval

    /// Canonical prompt lives in shared/prompts/cleanup_prompt.txt (bundled
    /// into Resources by build_app.sh); the literal below is the fallback so
    /// `swift build` binaries keep working without the bundle.
    static let systemPrompt: String = {
        if let url = Bundle.main.url(forResource: "cleanup_prompt", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallbackSystemPrompt
    }()

    private static let fallbackSystemPrompt = """
        You clean up dictated text. Rules:
        - Output ONLY the cleaned text. No preamble, no quotes, no commentary.
        - Keep the same language as the input (German stays German, French stays French, English stays English).
        - Remove filler words (um, äh, also, alors, you know), false starts, and repetitions.
        - If the speaker corrects themselves ("next Tuesday — no wait, Wednesday", "also nein, ich meine…", "enfin, je veux dire…"), keep ONLY the corrected version.
        - If the speaker enumerates items ("first… second…", "erstens… zweitens…", "premièrement…"), format them as a list, one item per line, each starting with "- ".
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

    func cleanup(
        transcript: String, language: String?,
        glossary: [String] = [], toneHint: String? = nil
    ) async throws -> String {
        var systemPrompt = Self.systemPrompt
        if let language, language != "unknown" {
            systemPrompt += "\n- The input language is \"\(language)\". The output must be in that same language."
        }
        if !glossary.isEmpty {
            systemPrompt += "\n- Personal dictionary — when the transcript contains a similar-sounding or misspelled variant of one of these, use this exact spelling: "
                + glossary.joined(separator: ", ")
        }
        if let toneHint, !toneHint.isEmpty {
            systemPrompt += "\n- The text will be inserted into an app where the expected style is: \(toneHint). Adjust register lightly; never change meaning."
        }

        // PRD: max_tokens sized to input length × 1.5 (≈3 chars/token heuristic),
        // plus fixed headroom for reasoning models that "think" before answering —
        // otherwise they hit the cap mid-thought and return empty content.
        // Non-thinking models just stop early, so the headroom is free.
        let maxTokens = max(256, Int(Double(transcript.count) / 3.0 * 1.5) + 64) + 2048

        return try await send(systemPrompt: systemPrompt, userContent: transcript, maxTokens: maxTokens)
    }

    /// Command mode: apply a spoken instruction to selected text.
    func rewrite(selection: String, instruction: String) async throws -> String {
        let systemPrompt: String
        if let url = Bundle.main.url(forResource: "rewrite_prompt", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            systemPrompt = """
                You edit text according to the user's instruction. Rules:
                - Output ONLY the edited text. No preamble, no quotes, no commentary.
                - Keep the text's original language unless the instruction explicitly asks to translate.
                - Apply the instruction faithfully; change nothing else.
                """
        }
        let user = "Instruction: \(instruction)\n\nText:\n\(selection)"
        let maxTokens = max(512, Int(Double(selection.count) / 3.0 * 2)) + 2048
        return try await send(systemPrompt: systemPrompt, userContent: user, maxTokens: maxTokens)
    }

    private func send(systemPrompt: String, userContent: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/chat/completions")) else { throw CleanupError.badURL }

        var systemPrompt = systemPrompt
        // Qwen3 hybrids honor /no_think in the prompt; belt-and-braces next to
        // reasoning_effort below. Harmless elsewhere.
        if model.localizedCaseInsensitiveContains("qwen") {
            systemPrompt += "\n/no_think"
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
            // Disables thinking on models that support it (e.g. Qwen 3.5 —
            // 0.46s instead of 67s); safely ignored by non-reasoning models.
            "reasoning_effort": "none",
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
