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

/// Gemini price list (USD per 1M tokens). Input uses each model's AUDIO-input
/// rate, since this app always sends audio.
///
/// The compiled-in table is only the fallback: rates are served remotely as
/// pricing.json beside the update feed's appcast, refreshed at launch and cached
/// across launches — so when Google changes prices the estimate stays honest
/// without shipping a build. Source of truth is pricing.json in the repo, which
/// each release publishes: https://ai.google.dev/gemini-api/docs/pricing
enum GeminiPricing {
    private static let builtin: [String: (input: Double, output: Double)] = [
        "gemini-2.5-flash":       (1.00, 2.50),
        "gemini-2.5-flash-lite":  (0.30, 0.40),
        "gemini-3.5-flash":       (1.50, 9.00),
        "gemini-3-flash-preview": (1.00, 3.00),
        "gemini-3.1-flash-lite":  (0.50, 1.50),
        "gemini-2.0-flash":       (0.70, 0.40),
        "gemini-2.0-flash-lite":  (0.075, 0.30),
        "gemini-flash-latest":    (1.50, 9.00), // tracks newest stable Flash (currently 3.5)
    ]

    private static let feedURL = URL(string: "https://updates.claudete.co/ai-buddy/pricing.json")!
    private static let cacheKey = "remotePricing"
    private static let lock = NSLock()
    /// Parsed remote rates; nil until the UserDefaults cache is read once.
    /// An empty dictionary means "no usable remote data" and keeps a bad cache
    /// from being re-parsed on every lookup.
    private static var remote: [String: (input: Double, output: Double)]?

    /// The live lookup table: remote rates layered over the built-ins, so a
    /// served model id wins and unlisted ones keep their compiled-in rate.
    private static func currentTable() -> [String: (input: Double, output: Double)] {
        lock.lock(); defer { lock.unlock() }
        if remote == nil {
            remote = UserDefaults.standard.data(forKey: cacheKey).flatMap(parse) ?? [:]
        }
        guard let remote, !remote.isEmpty else { return builtin }
        return builtin.merging(remote) { _, served in served }
    }

    /// Fetches the served pricing table; on success caches it and uses it from
    /// then on. Fire-and-forget — any failure just means the current rates stand.
    static func refresh() {
        var req = URLRequest(url: feedURL)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let parsed = parse(data), !parsed.isEmpty else { return }
            lock.lock()
            remote = parsed
            lock.unlock()
            UserDefaults.standard.set(data, forKey: cacheKey)
        }.resume()
    }

    /// pricing.json shape: {"models": {"<id>": {"input": <USD/1M>, "output": <USD/1M>}}}
    private static func parse(_ data: Data) -> [String: (input: Double, output: Double)]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: [String: Any]] else { return nil }
        var out: [String: (input: Double, output: Double)] = [:]
        for (id, v) in models {
            guard let input = v["input"] as? Double, let output = v["output"] as? Double else { continue }
            out[id.lowercased()] = (input, output)
        }
        return out
    }

    /// Rates for a model id. Exact match wins; otherwise the longest known prefix
    /// (covers dated/preview variants); else gemini-2.5-flash, flagged `known=false`.
    static func rates(for model: String) -> (input: Double, output: Double, known: Bool) {
        let table = currentTable()
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = table[id] { return (r.input, r.output, true) }
        if let key = table.keys.filter({ id.hasPrefix($0) }).max(by: { $0.count < $1.count }),
           let r = table[key] { return (r.input, r.output, true) }
        let fallback = table["gemini-2.5-flash"] ?? builtin["gemini-2.5-flash"]!
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
