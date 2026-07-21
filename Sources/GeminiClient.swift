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
                           instruction: String,
                           thinkingBudget: Int,
                           mimeType: String = AudioFormat.mimeType) async throws -> TranscriptionResult {
        // Keys pasted from a webpage often carry a trailing newline/space, which
        // otherwise fails auth with a confusing 400. Trim before use.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiError.noKey }

        let audio = try Data(contentsOf: audioURL)
        let base64 = audio.base64EncodedString()

        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
        guard let url = URL(string: endpoint) else { throw GeminiError.badResponse }

        func makeBody(thinking: Bool) throws -> Data {
            var gen = generationConfig(thinkingBudget: thinkingBudget)
            if !thinking { gen.removeValue(forKey: "thinkingConfig") }
            let body: [String: Any] = [
                "contents": [[
                    "parts": [
                        ["text": instruction],
                        ["inline_data": ["mime_type": mimeType, "data": base64]],
                    ]
                ]],
                "generationConfig": gen,
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try makeBody(thinking: true)

        let data: Data
        do {
            data = try await send(req, retries: 2)
        } catch let GeminiError.http(code, msg) where code == 400 && isThinkingError(msg) {
            // A model that rejects our thinking hint — retry once with its defaults.
            req.httpBody = try makeBody(thinking: false)
            data = try await send(req, retries: 2)
        }

        guard let text = extractText(from: data) else { throw GeminiError.empty }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw GeminiError.empty }
        let usage = extractUsage(from: data)
        return TranscriptionResult(text: trimmed, inputTokens: usage.input, outputTokens: usage.output)
    }

    /// Streaming transcription over `streamGenerateContent` (SSE). Calls `onDelta`
    /// with whitespace-safe text pieces as they arrive — deltas never carry the
    /// output's leading or a dangling trailing whitespace, so a caller can type
    /// them straight to the cursor without a stray space or an accidental newline
    /// (which could submit a chat field). Returns the full result at the end.
    static func transcribeStreaming(audioURL: URL,
                                    apiKey: String,
                                    model: String,
                                    instruction: String,
                                    thinkingBudget: Int,
                                    mimeType: String = AudioFormat.mimeType,
                                    onDelta: @escaping (String) -> Void) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiError.noKey }

        let audio = try Data(contentsOf: audioURL)
        let base64 = audio.base64EncodedString()
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else { throw GeminiError.badResponse }

        func makeBody(thinking: Bool) throws -> Data {
            var gen = generationConfig(thinkingBudget: thinkingBudget)
            if !thinking { gen.removeValue(forKey: "thinkingConfig") }
            let body: [String: Any] = [
                "contents": [[
                    "parts": [
                        ["text": instruction],
                        ["inline_data": ["mime_type": mimeType, "data": base64]],
                    ]
                ]],
                "generationConfig": gen,
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        func attempt(thinking: Bool) async throws -> TranscriptionResult {
            req.httpBody = try makeBody(thinking: thinking)
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await b in bytes { data.append(b) }
                let msg = errorMessage(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
                throw GeminiError.http(http.statusCode, msg)
            }

            var full = ""
            var input = 0, output = 0
            var trailing = ""     // whitespace held back so we never emit a trailing newline
            var started = false   // drop the whole output's leading whitespace
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let usage = obj["usageMetadata"] as? [String: Any] {
                    input = usage["promptTokenCount"] as? Int ?? input
                    output = usage["candidatesTokenCount"] as? Int ?? output
                }
                guard let delta = extractTextParts(obj), !delta.isEmpty else { continue }
                full += delta
                var piece = trailing + delta
                if !started {
                    piece = String(piece.drop(while: { $0.isWhitespace }))
                    if piece.isEmpty { trailing = ""; continue }
                    started = true
                }
                // Emit up to the last non-whitespace; buffer any trailing whitespace
                // in case it's mid-text (a space before the next word) or the end.
                if let lastNonWS = piece.lastIndex(where: { !$0.isWhitespace }) {
                    let cut = piece.index(after: lastNonWS)
                    trailing = String(piece[cut...])
                    onDelta(String(piece[..<cut]))
                } else {
                    trailing = piece
                }
            }
            let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw GeminiError.empty }
            return TranscriptionResult(text: trimmed, inputTokens: input, outputTokens: output)
        }

        do {
            return try await attempt(thinking: true)
        } catch let GeminiError.http(code, msg) where code == 400 && isThinkingError(msg) {
            return try await attempt(thinking: false)
        }
    }

    /// Answers a spoken question about a screenshot: one `generateContent` call
    /// carrying the instruction, the PNG, and the recorded audio, so the question
    /// never needs a separate transcription round-trip.
    static func answerAboutImage(audioURL: URL,
                                 imageURL: URL,
                                 apiKey: String,
                                 model: String,
                                 instruction: String,
                                 audioMimeType: String = AudioFormat.mimeType) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiError.noKey }

        let audio = try Data(contentsOf: audioURL)
        let image = try Data(contentsOf: imageURL)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent"
        guard let url = URL(string: endpoint) else { throw GeminiError.badResponse }

        // No thinkingConfig here: unlike verbatim transcription, answering benefits
        // from the model's default reasoning, and the user is reading — not waiting
        // to keep typing — so the extra latency is acceptable.
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": instruction],
                    ["inline_data": ["mime_type": "image/png", "data": image.base64EncodedString()]],
                    ["inline_data": ["mime_type": audioMimeType, "data": audio.base64EncodedString()]],
                ]
            ]],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
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

    /// A 0 thinking budget disables reasoning — the single biggest latency win, and
    /// the default here since verbatim transcription needs none. Works on Flash 2.x
    /// and 3.x alike (verified against the API); if some model ever rejects the
    /// budget, the caller retries without any thinking config.
    private static func generationConfig(thinkingBudget: Int) -> [String: Any] {
        ["temperature": 0, "thinkingConfig": ["thinkingBudget": thinkingBudget]]
    }

    /// True when an API error looks like it's complaining about our thinking hint,
    /// so we can retry without it rather than failing the transcription.
    private static func isThinkingError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("thinking") || m.contains("thinkinglevel") || m.contains("thinking_level")
            || m.contains("thinkingbudget") || m.contains("thinking_budget")
    }

    // MARK: Connection prewarm

    private static let warmLock = NSLock()
    private static var lastWarm = Date.distantPast
    /// Comfortably inside the pool's idle keep-alive, so back-to-back takes don't
    /// re-warm a connection that is already open.
    private static let warmInterval: TimeInterval = 45

    /// Opens the connection to the API host while the user is still speaking.
    ///
    /// Otherwise DNS, the TCP handshake and the TLS handshake all happen *after*
    /// the hotkey is released — dead time the user reads as the app being slow.
    /// `URLSession.shared` pools connections, so the transcription request that
    /// follows reuses this one. Best-effort and fire-and-forget: the response is
    /// discarded, a failure just means we paid nothing, and the metadata endpoint
    /// costs no tokens.
    static func prewarm(apiKey: String, model: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !modelID.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID)")
        else { return }

        warmLock.lock()
        let due = Date().timeIntervalSince(lastWarm) > warmInterval
        if due { lastWarm = Date() }
        warmLock.unlock()
        guard due else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return extractTextParts(obj)
    }

    /// Joins the text parts of the first candidate in a parsed response object.
    private static func extractTextParts(_ obj: [String: Any]) -> String? {
        guard let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let texts = parts
            .filter { ($0["thought"] as? Bool) != true }   // never surface reasoning as output
            .compactMap { $0["text"] as? String }
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
