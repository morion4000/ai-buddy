import Foundation
import Combine
import AppKit

/// How the hotkey starts/stops recording.
enum TriggerMode: String, CaseIterable, Identifiable {
    case hold    // hold the key while speaking, release to transcribe
    case toggle  // press once to start, again to stop

    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to talk" : "Toggle on/off" }
}

/// What triggers a retry of the last take (delete its text, re-send its audio).
enum RetryTrigger: String, CaseIterable, Identifiable {
    case doubleTap  // two quick taps of the talk hotkey
    case hotkey     // a dedicated shortcut
    case off        // gesture disabled; the menu-bar item still works

    var id: String { rawValue }
    var label: String {
        switch self {
        case .doubleTap: return "Double-tap talk key"
        case .hotkey:    return "Its own hotkey"
        case .off:       return "Off"
        }
    }
}

/// Current activity of the app, surfaced in the menu bar + settings window.
enum AppStatus: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)

    /// True when a fresh recording may begin — i.e. we're not already busy.
    /// A prior `.error` counts as startable so one failed take never blocks the next.
    var canStartRecording: Bool {
        switch self {
        case .idle, .error:             return true
        case .recording, .transcribing: return false
        }
    }
}

/// One past transcription, shown in the "Recent" list.
struct TranscriptItem: Identifiable, Codable {
    var id = UUID()
    var text: String
    var date: Date
}

/// One month × model cell of usage, for the per-model breakdown and the
/// month-over-month trend in Settings ▸ Usage & Cost.
struct UsageBucket: Codable, Identifiable, Equatable {
    var month: String   // "2026-07"
    var model: String
    var count: Int
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double

    var id: String { "\(month)|\(model)" }
}

/// Single source of truth for settings + runtime state.
/// All mutations happen on the main thread (the app never touches it elsewhere).
final class AppState: ObservableObject {
    static let maxSavedTranscriptions = 1_000

    // MARK: Persisted settings
    @Published var apiKey: String           { didSet { Keychain.set(apiKey) } }
    @Published var model: String            { didSet { d.set(model, forKey: K.model) } }
    @Published var triggerMode: TriggerMode { didSet { d.set(triggerMode.rawValue, forKey: K.triggerMode); onHotkeyOrModeChange?() } }
    @Published var hotkeyKeyCode: Int       { didSet { d.set(hotkeyKeyCode, forKey: K.keyCode); onHotkeyOrModeChange?() } }
    @Published var hotkeyMods: Int          { didSet { d.set(hotkeyMods, forKey: K.mods); onHotkeyOrModeChange?() } }
    @Published var insertAtCursor: Bool     { didSet { d.set(insertAtCursor, forKey: K.insert) } }
    @Published var copyToClipboard: Bool    { didSet { d.set(copyToClipboard, forKey: K.copy) } }
    @Published var typeInsteadOfPaste: Bool { didSet { d.set(typeInsteadOfPaste, forKey: K.type) } }
    @Published var playSounds: Bool         { didSet { d.set(playSounds, forKey: K.sounds) } }
    @Published var instruction: String      { didSet { d.set(instruction, forKey: K.instruction) } }
    /// Comma-separated terms the speaker uses often (names, jargon, acronyms) that
    /// Gemini should prefer the exact spelling of — see `vocabularyDirective`.
    @Published var vocabulary: String        { didSet { d.set(vocabulary, forKey: K.vocabulary) } }
    /// Uses locally extracted topics from saved transcripts as soft context. Unlike
    /// the custom dictionary, these never instruct Gemini to force an exact spelling.
    @Published var useConversationKeywords: Bool { didSet { d.set(useConversationKeywords, forKey: K.useConversationKeywords) } }
    /// Cached separately from the transcript history so the UI and prompt do not need
    /// to re-run linguistic analysis whenever SwiftUI redraws.
    @Published private(set) var conversationKeywords: [String] = [] {
        didSet { d.set(conversationKeywords, forKey: K.conversationKeywords) }
    }
    /// Safety cap: auto-stop a recording after this many seconds (0 = no cap).
    @Published var maxRecordingSeconds: Int { didSet { d.set(maxRecordingSeconds, forKey: K.maxRecording) } }
    /// When on, asks Gemini to strip filler words / disfluencies from the text.
    @Published var removeFillers: Bool      { didSet { d.set(removeFillers, forKey: K.removeFillers) } }
    /// When on, mute the system audio output during recording and restore it after.
    @Published var muteWhileRecording: Bool { didSet { d.set(muteWhileRecording, forKey: K.muteWhileRecording) } }
    /// Languages the speaker dictates in. Transcription is constrained to this set —
    /// English is always included and can't be removed. See `languagesDirective`.
    @Published var languages: [String]     { didSet { d.set(languages, forKey: K.languages) } }
    /// Off by default: verbatim transcription needs no reasoning and thinking only
    /// adds latency. When on, we allow a small budget (see `thinkingBudget`).
    @Published var enableThinking: Bool    { didSet { d.set(enableThinking, forKey: K.enableThinking) } }

    // MARK: Retry
    /// How the user redoes a bad take — see `RetryTrigger`.
    @Published var retryTrigger: RetryTrigger { didSet { d.set(retryTrigger.rawValue, forKey: K.retryTrigger); onRetryHotkeyChange?() } }
    @Published var retryKeyCode: Int          { didSet { d.set(retryKeyCode, forKey: K.retryKey); onRetryHotkeyChange?() } }
    @Published var retryMods: Int             { didSet { d.set(retryMods, forKey: K.retryMods); onRetryHotkeyChange?() } }

    // MARK: Screenshots
    /// When on, a fresh capture "arms" the talk hotkey: hold it, speak a question
    /// about the shot, and Gemini's answer pops up beside the thumbnail.
    @Published var askScreenshots: Bool     { didSet { d.set(askScreenshots, forKey: K.askScreenshots) } }
    @Published var screenshotsEnabled: Bool { didSet { d.set(screenshotsEnabled, forKey: K.shotEnabled); onScreenshotHotkeyChange?() } }
    @Published var screenshotKeyCode: Int   { didSet { d.set(screenshotKeyCode, forKey: K.shotKey); onScreenshotHotkeyChange?() } }
    @Published var screenshotMods: Int      { didSet { d.set(screenshotMods, forKey: K.shotMods); onScreenshotHotkeyChange?() } }

    // MARK: Usage & cost (cost accrued per transcription at that model's rate)
    // All-time totals…
    @Published var usageCount: Int          { didSet { d.set(usageCount, forKey: K.usageCount) } }
    @Published var usageInputTokens: Int    { didSet { d.set(usageInputTokens, forKey: K.usageInput) } }
    @Published var usageOutputTokens: Int   { didSet { d.set(usageOutputTokens, forKey: K.usageOutput) } }
    @Published var usageCost: Double        { didSet { d.set(usageCost, forKey: K.usageCost) } }
    // …plus month × model buckets, which answer "is this getting expensive" —
    // per-model breakdown for the current month and a trend across months.
    @Published private(set) var usageBuckets: [UsageBucket] = [] { didSet { saveUsageBuckets() } }

    // MARK: Runtime (not persisted)
    @Published var status: AppStatus = .idle
    @Published var recents: [TranscriptItem] = [] {
        didSet {
            saveRecents()
            refreshConversationKeywords()
            onRecentsChange?()
        }
    }

    /// Set by the AppDelegate so the hotkey engine re-binds when the shortcut or mode changes.
    var onHotkeyOrModeChange: (() -> Void)?
    /// Set by the AppDelegate so the screenshot hotkey re-binds when it changes.
    var onScreenshotHotkeyChange: (() -> Void)?
    /// Set by the AppDelegate so the retry hotkey re-binds when it changes.
    var onRetryHotkeyChange: (() -> Void)?
    /// Keeps the native Recent Transcriptions menu synchronized with settings actions.
    var onRecentsChange: (() -> Void)?

    private let d = UserDefaults.standard
    private var keywordRefreshGeneration = 0

    private enum K {
        static let model = "model", triggerMode = "triggerMode", keyCode = "hotkeyKeyCode"
        static let mods = "hotkeyMods", insert = "insertAtCursor", copy = "copyToClipboard"
        static let type = "typeInsteadOfPaste", sounds = "playSounds", instruction = "instruction"
        static let vocabulary = "vocabulary", useConversationKeywords = "useConversationKeywords"
        static let conversationKeywords = "conversationKeywords"
        static let recents = "recents", configured = "configured", maxRecording = "maxRecordingSeconds"
        static let removeFillers = "removeFillers", muteWhileRecording = "muteWhileRecording"
        static let languages = "languages"
        static let enableThinking = "enableThinking"
        static let modelMigrated35 = "modelDefault35Migrated"
        static let shotEnabled = "screenshotsEnabled", shotKey = "screenshotKeyCode", shotMods = "screenshotMods"
        static let askScreenshots = "askScreenshots"
        static let retryTrigger = "retryTrigger", retryKey = "retryKeyCode", retryMods = "retryMods"
        static let usageCount = "usageCount", usageInput = "usageInputTokens", usageOutput = "usageOutputTokens"
        static let usageCost = "usageCost", usageBuckets = "usageBuckets"
    }

    static let defaultInstruction = """
    You are a verbatim speech transcriber. Transcribe the spoken audio exactly as said. \
    Output ONLY the transcribed text — no preamble, no quotation marks, no commentary, \
    no speaker labels, no timestamps. Preserve natural punctuation and capitalization. \
    If there is no intelligible speech, output nothing.
    """

    /// The prompt for a spoken question about a screenshot. Unlike transcription,
    /// the output here is an *answer* the user reads, so it must be plain text
    /// (no markdown — it renders verbatim in the answer panel) and stay concise.
    static let askInstruction = """
    You are AI Buddy, a helpful assistant on the user's Mac. The user captured the attached \
    screenshot and is asking the spoken question in the attached audio about it. Answer the \
    question directly and concisely in plain text — no markdown, no preamble, no restating \
    the question. Answer in the same language the question was asked in. If the audio contains \
    no intelligible question, briefly describe what the screenshot shows instead.
    """

    /// Appended when the user rejects a take (double-tap of the hotkey) and the
    /// same audio goes back for a second pass. Quoting the rejected attempt is what
    /// makes the retry useful — transcription runs at temperature 0, so without it
    /// the model would mostly just reproduce the same text.
    static func retryDirective(previous: String) -> String {
        """
        A previous transcription of this exact audio was rejected by the user as inaccurate. \
        That rejected attempt was:
        "\(previous)"
        Listen to the audio again more carefully and produce a corrected transcription. \
        Reconsider words that could plausibly have been misheard — names, technical terms, \
        and words the rejected attempt may have guessed at — and do not simply repeat the \
        rejected attempt unless you are confident it is exactly right.
        """
    }

    /// Appended to the prompt when "Remove filler words" is on. Phrased to drop
    /// only non-lexical fillers, not real words, and to tidy the result.
    static let fillerDirective = """
    Additionally, remove filler words and speech disfluencies — for example "um", "uh", "er", "erm", \
    "ah", "hmm" — along with false starts, repeated words, and stutters. Keep the speaker's actual words \
    and meaning fully intact; only drop the non-lexical fillers, and fix the surrounding spacing and \
    punctuation so the text reads cleanly.
    """

    /// Built from the user's comma-separated `vocabulary`. Tells Gemini to prefer the
    /// exact spelling/capitalization of frequently-used or easily-misheard terms
    /// (names, jargon, acronyms). Empty when no terms are entered, so it adds nothing
    /// to the prompt by default.
    var vocabularyDirective: String {
        let terms = AppState.vocabularyTerms(vocabulary)
        guard !terms.isEmpty else { return "" }
        return """
        The speaker often uses the following terms. When you hear a word or phrase that \
        closely matches one of these, transcribe it using exactly this spelling and \
        capitalization: \(terms.joined(separator: ", ")).
        """
    }

    /// Splits the raw comma-separated field into trimmed, de-duplicated, non-empty terms.
    static func vocabularyTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Soft context for resolving ambiguous speech. It must not force missing words or
    /// exact spellings; those stronger semantics belong only to `vocabularyDirective`.
    var conversationKeywordsDirective: String {
        guard useConversationKeywords else { return "" }
        let dictionaryTerms = Set(AppState.vocabularyTerms(vocabulary).map { $0.lowercased() })
        let keywords = conversationKeywords.filter { !dictionaryTerms.contains($0.lowercased()) }
        guard !keywords.isEmpty else { return "" }
        return """
        Recent transcriptions have often discussed these topics: \(keywords.joined(separator: ", ")). \
        Use them only as context when the audio is genuinely ambiguous. Do not add a topic that was not \
        spoken, and do not treat this list as an exact-spelling dictionary.
        """
    }

    /// The languages the user can pick from. English leads and is always selected.
    static let supportedLanguages = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese",
        "Dutch", "Romanian", "Polish", "Russian", "Ukrainian", "Turkish",
        "Greek", "Czech", "Hungarian", "Swedish", "Norwegian", "Danish",
        "Finnish", "Arabic", "Hebrew", "Hindi", "Japanese", "Korean",
        "Chinese", "Vietnamese", "Thai", "Indonesian",
    ]

    /// The stored selection, normalized so English is always present and first.
    static func effectiveLanguages(_ raw: [String]) -> [String] {
        var result = ["English"]
        for l in raw where l != "English" { result.append(l) }
        return result
    }

    /// Constrains Gemini to the chosen languages so the output never drifts into an
    /// unwanted one. Always present (English at minimum), so it's part of every prompt.
    var languagesDirective: String {
        let langs = AppState.effectiveLanguages(languages)
        let list = langs.joined(separator: ", ")
        if langs.count == 1 {
            return "The audio is spoken in \(list). Transcribe it in \(list) and do not output text in any other language."
        }
        return """
        The audio is spoken in one or more of these languages: \(list). Transcribe each part in the \
        same language it is actually spoken in, chosen only from this list. Do not translate between \
        languages, and do not output text in any language outside this list.
        """
    }

    /// Thinking tokens allowed per transcription: 0 (off) by default, or a small
    /// budget when the user opts in — kept low so it barely costs latency.
    static let smallThinkingBudget = 512
    var thinkingBudget: Int { enableThinking ? AppState.smallThinkingBudget : 0 }

    /// The transcription prompt actually sent to Gemini, with opt-in add-ons applied.
    var effectiveInstruction: String {
        var prompt = instruction
        if removeFillers { prompt += "\n\n" + AppState.fillerDirective }
        let vocab = vocabularyDirective
        if !vocab.isEmpty { prompt += "\n\n" + vocab }
        let keywords = conversationKeywordsDirective
        if !keywords.isEmpty { prompt += "\n\n" + keywords }
        prompt += "\n\n" + languagesDirective
        return prompt
    }

    init() {
        apiKey      = Keychain.get() ?? ""
        model       = d.string(forKey: K.model) ?? "gemini-3.5-flash"
        triggerMode = TriggerMode(rawValue: d.string(forKey: K.triggerMode) ?? "") ?? .hold

        if d.bool(forKey: K.configured) {
            hotkeyKeyCode = d.integer(forKey: K.keyCode)
            hotkeyMods    = d.integer(forKey: K.mods)
        } else {
            // First launch: default to Right Option (keyCode 61) — a clean, no-conflict
            // push-to-talk key that needs no extra modifiers.
            hotkeyKeyCode = 61
            hotkeyMods    = 0
            d.set(true, forKey: K.configured)
        }

        insertAtCursor     = d.object(forKey: K.insert)  as? Bool ?? true
        copyToClipboard    = d.object(forKey: K.copy)    as? Bool ?? true
        typeInsteadOfPaste = d.object(forKey: K.type)    as? Bool ?? false
        playSounds         = d.object(forKey: K.sounds)  as? Bool ?? true
        instruction        = d.string(forKey: K.instruction) ?? AppState.defaultInstruction
        vocabulary         = d.string(forKey: K.vocabulary) ?? ""
        useConversationKeywords = d.object(forKey: K.useConversationKeywords) as? Bool ?? true
        maxRecordingSeconds = d.object(forKey: K.maxRecording) as? Int ?? 60
        removeFillers       = d.object(forKey: K.removeFillers) as? Bool ?? false
        muteWhileRecording  = d.object(forKey: K.muteWhileRecording) as? Bool ?? true
        languages           = AppState.effectiveLanguages(d.stringArray(forKey: K.languages) ?? [])
        enableThinking      = d.object(forKey: K.enableThinking) as? Bool ?? false

        retryTrigger        = RetryTrigger(rawValue: d.string(forKey: K.retryTrigger) ?? "") ?? .doubleTap
        // Default retry shortcut: a clean tap of Right ⌃ (keyCode 62) — the only
        // right-side modifier the talk and screenshot defaults haven't claimed.
        retryKeyCode        = d.object(forKey: K.retryKey) as? Int ?? 62
        retryMods           = d.integer(forKey: K.retryMods)

        askScreenshots      = d.object(forKey: K.askScreenshots) as? Bool ?? true
        screenshotsEnabled  = d.object(forKey: K.shotEnabled) as? Bool ?? true
        // Default trigger: a clean tap of Right ⌘ (keyCode 54), no extra modifiers.
        screenshotKeyCode   = d.object(forKey: K.shotKey) as? Int ?? 54
        screenshotMods      = d.integer(forKey: K.shotMods)

        usageCount        = d.integer(forKey: K.usageCount)
        usageInputTokens  = d.integer(forKey: K.usageInput)
        usageOutputTokens = d.integer(forKey: K.usageOutput)
        usageCost         = d.double(forKey: K.usageCost)
        if let data = d.data(forKey: K.usageBuckets),
           let buckets = try? JSONDecoder().decode([UsageBucket].self, from: data) {
            usageBuckets = buckets
        }

        if let data = d.data(forKey: K.recents),
           let items = try? JSONDecoder().decode([TranscriptItem].self, from: data) {
            recents = Array(items.prefix(AppState.maxSavedTranscriptions))
        }
        if let cached = d.stringArray(forKey: K.conversationKeywords) {
            conversationKeywords = cached
        } else {
            conversationKeywords = KeywordExtractor.extract(from: recents.map(\.text))
            d.set(conversationKeywords, forKey: K.conversationKeywords)
        }

        // One-time bump: anyone still on the previous default (gemini-2.5-flash) moves
        // to the newer, faster gemini-3.5-flash. A deliberate other choice is untouched.
        if !d.bool(forKey: K.modelMigrated35) {
            if model == "gemini-2.5-flash" { model = "gemini-3.5-flash" }
            d.set(model, forKey: K.model)
            d.set(true, forKey: K.modelMigrated35)
        }
    }

    func recordUsage(input: Int, output: Int, model: String) {
        let cost = GeminiPricing.cost(model: model, inputTokens: input, outputTokens: output)
        usageCount += 1
        usageInputTokens += input
        usageOutputTokens += output
        usageCost += cost

        let month = AppState.monthKey()
        var buckets = usageBuckets
        if let i = buckets.firstIndex(where: { $0.month == month && $0.model == model }) {
            buckets[i].count += 1
            buckets[i].inputTokens += input
            buckets[i].outputTokens += output
            buckets[i].cost += cost
        } else {
            buckets.append(UsageBucket(month: month, model: model, count: 1,
                                       inputTokens: input, outputTokens: output, cost: cost))
        }
        usageBuckets = buckets
    }

    func resetUsage() {
        usageCount = 0
        usageInputTokens = 0
        usageOutputTokens = 0
        usageCost = 0
        usageBuckets = []
    }

    // MARK: Month bucketing

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func monthKey(for date: Date = Date()) -> String {
        monthFormatter.string(from: date)
    }

    /// The last `n` month keys, oldest first, current month last — the trend's x-axis.
    static func recentMonthKeys(_ n: Int) -> [String] {
        let cal = Calendar.current
        return (0..<n).reversed().compactMap { back in
            cal.date(byAdding: .month, value: -back, to: Date()).map(monthKey)
        }
    }

    /// "2026-07" → "Jul" (localized short month name).
    static func monthLabel(_ key: String) -> String {
        guard let date = monthFormatter.date(from: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: date)
    }

    private func saveUsageBuckets() {
        if let data = try? JSONEncoder().encode(usageBuckets) { d.set(data, forKey: K.usageBuckets) }
    }

    func addRecent(_ text: String) {
        var updated = recents
        updated.insert(TranscriptItem(text: text, date: Date()), at: 0)
        recents = Array(updated.prefix(AppState.maxSavedTranscriptions))
    }

    /// Swaps the entry a retry replaced (normally the newest) for the corrected
    /// text, so the history doesn't keep the rejected wording around.
    func replaceRecent(matching old: String, with text: String) {
        var updated = recents
        if let i = updated.firstIndex(where: { $0.text == old }) {
            updated[i] = TranscriptItem(text: text, date: Date())
            recents = updated
        } else {
            addRecent(text)
        }
    }

    func clearRecents() {
        recents.removeAll()
        // `recents`' observer has already synchronized the empty in-memory state;
        // remove the persisted keys entirely so clear really removes the history/cache.
        d.removeObject(forKey: K.recents)
        d.removeObject(forKey: K.conversationKeywords)
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { d.set(data, forKey: K.recents) }
    }

    private func refreshConversationKeywords() {
        keywordRefreshGeneration += 1
        let generation = keywordRefreshGeneration
        let texts = recents.map(\.text)
        guard !texts.isEmpty else {
            conversationKeywords = []
            return
        }

        // Linguistic tagging can become noticeable with a full 1,000-item history.
        // Analyze off the main thread, then ignore stale results if history changed
        // again while the work was running.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keywords = KeywordExtractor.extract(from: texts)
            DispatchQueue.main.async {
                guard let self, self.keywordRefreshGeneration == generation else { return }
                self.conversationKeywords = keywords
            }
        }
    }
}
