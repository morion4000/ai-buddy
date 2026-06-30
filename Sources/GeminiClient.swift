import Foundation

enum GeminiError: LocalizedError {
    case noKey
    case http(Int, String)
    case empty
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey:            return "No Gemini API key set. Open Settings and paste your key."
        case .http(let c, let m): return "Gemini API error \(c): \(m)"
        case .empty:            return "No speech detected — nothing to transcribe."
        case .badResponse:      return "Unexpected response from Gemini."
        }
    }
}

/// One transcription's text plus the token usage Gemini reported for it.
struct TranscriptionResult {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
}

/// Built-in Gemini price list (USD per 1M tokens). Input uses each model's
/// AUDIO-input rate, since this app always sends audio. Source:
/// https://ai.google.dev/gemini-api/docs/pricing (checked Jun 2026).
enum GeminiPricing {
    private static let table: [String: (input: Double, output: Double)] = [
        "gemini-2.5-flash":       (1.00, 2.50),
        "gemini-2.5-flash-lite":  (0.30, 0.40),
        "gemini-3.5-flash":       (1.50, 9.00),
        "gemini-3-flash-preview": (1.00, 3.00),
        "gemini-3.1-flash-lite":  (0.50, 1.50),
        "gemini-2.0-flash":       (0.70, 0.40),
        "gemini-2.0-flash-lite":  (0.075, 0.30),
        "gemini-flash-latest":    (1.50, 9.00), // tracks newest stable Flash (currently 3.5)
    ]

    /// Rates for a model id. Exact match wins; otherwise the longest known prefix
    /// (covers dated/preview variants); else gemini-2.5-flash, flagged `known=false`.
    static func rates(for model: String) -> (input: Double, output: Double, known: Bool) {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = table[id] { return (r.input, r.output, true) }
        if let key = table.keys.filter({ id.hasPrefix($0) }).max(by: { $0.count < $1.count }),
           let r = table[key] { return (r.input, r.output, true) }
        let fallback = table["gemini-2.5-flash"]!
        return (fallback.input, fallback.output, false)
    }

    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let r = rates(for: model)
        return (Double(inputTokens) * r.input + Double(outputTokens) * r.output) / 1_000_000
    }
}

/// Sends recorded audio to the Gemini API for transcription via the stable
/// `generateContent` endpoint with an inline audio part.
enum GeminiClient {
    static func transcribe(audioURL: URL,
                           apiKey: String,
                           model: String,
                           instruction: String) async throws -> TranscriptionResult {
        // Keys pasted from a webpage often carry a trailing newline/space, which
        // otherwise fails auth with a confusing 400. Trim before use.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiError.noKey }

        let audio = try Data(contentsOf: audioURL)
        let base64 = audio.base64EncodedString()

        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
        guard let url = URL(string: endpoint) else { throw GeminiError.badResponse }

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": instruction],
                    ["inline_data": ["mime_type": "audio/wav", "data": base64]],
                ]
            ]],
            "generationConfig": ["temperature": 0],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(req, retries: 2)

        guard let text = extractText(from: data) else { throw GeminiError.empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw GeminiError.empty }
        let usage = extractUsage(from: data)
        return TranscriptionResult(text: trimmed, inputTokens: usage.input, outputTokens: usage.output)
    }

    /// Lightweight check that the key + model are valid: a GET on the model's
    /// metadata. Returns whether it succeeded plus a human-readable message.
    static func validateKey(apiKey: String, model: String) async -> (ok: Bool, message: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (false, "No API key set.") }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID)")
        else { return (false, "Enter a model id first.") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (false, "Unexpected response.") }
            if (200..<300).contains(http.statusCode) { return (true, "Connected — \(modelID) is available.") }
            let msg = errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            return (false, "Error \(http.statusCode): \(msg)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Posts the request, retrying once or twice on rate-limit / server errors
    /// (429, 5xx) with a short linear backoff before giving up.
    private static func send(_ req: URLRequest, retries: Int) async throws -> Data {
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
            if (200..<300).contains(http.statusCode) { return data }

            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if retryable && attempt < retries {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.8 * 1_000_000_000))
                continue
            }
            let msg = errorMessage(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
            throw GeminiError.http(http.statusCode, msg)
        }
    }

    private static func extractText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// Pulls Gemini's reported token counts from `usageMetadata` (0 if absent).
    private static func extractUsage(from data: Data) -> (input: Int, output: Int) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usageMetadata"] as? [String: Any] else { return (0, 0) }
        let input = usage["promptTokenCount"] as? Int ?? 0
        let output = usage["candidatesTokenCount"] as? Int ?? 0
        return (input, output)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }
}
