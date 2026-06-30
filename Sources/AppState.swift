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

/// Single source of truth for settings + runtime state.
/// All mutations happen on the main thread (the app never touches it elsewhere).
final class AppState: ObservableObject {

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
    /// Safety cap: auto-stop a recording after this many seconds (0 = no cap).
    @Published var maxRecordingSeconds: Int { didSet { d.set(maxRecordingSeconds, forKey: K.maxRecording) } }
    /// When on, asks Gemini to strip filler words / disfluencies from the text.
    @Published var removeFillers: Bool      { didSet { d.set(removeFillers, forKey: K.removeFillers) } }
    /// When on, mute the system audio output during recording and restore it after.
    @Published var muteWhileRecording: Bool { didSet { d.set(muteWhileRecording, forKey: K.muteWhileRecording) } }

    // MARK: Screenshots
    @Published var screenshotsEnabled: Bool { didSet { d.set(screenshotsEnabled, forKey: K.shotEnabled); onScreenshotHotkeyChange?() } }
    @Published var screenshotKeyCode: Int   { didSet { d.set(screenshotKeyCode, forKey: K.shotKey); onScreenshotHotkeyChange?() } }
    @Published var screenshotMods: Int      { didSet { d.set(screenshotMods, forKey: K.shotMods); onScreenshotHotkeyChange?() } }

    // MARK: Usage & cost (cumulative; cost accrued per transcription at that model's rate)
    @Published var usageCount: Int          { didSet { d.set(usageCount, forKey: K.usageCount) } }
    @Published var usageInputTokens: Int    { didSet { d.set(usageInputTokens, forKey: K.usageInput) } }
    @Published var usageOutputTokens: Int   { didSet { d.set(usageOutputTokens, forKey: K.usageOutput) } }
    @Published var usageCost: Double        { didSet { d.set(usageCost, forKey: K.usageCost) } }

    // MARK: Runtime (not persisted)
    @Published var status: AppStatus = .idle
    @Published var recents: [TranscriptItem] = [] { didSet { saveRecents() } }

    /// Set by the AppDelegate so the hotkey engine re-binds when the shortcut or mode changes.
    var onHotkeyOrModeChange: (() -> Void)?
    /// Set by the AppDelegate so the screenshot hotkey re-binds when it changes.
    var onScreenshotHotkeyChange: (() -> Void)?

    private let d = UserDefaults.standard

    private enum K {
        static let model = "model", triggerMode = "triggerMode", keyCode = "hotkeyKeyCode"
        static let mods = "hotkeyMods", insert = "insertAtCursor", copy = "copyToClipboard"
        static let type = "typeInsteadOfPaste", sounds = "playSounds", instruction = "instruction"
        static let recents = "recents", configured = "configured", maxRecording = "maxRecordingSeconds"
        static let removeFillers = "removeFillers", muteWhileRecording = "muteWhileRecording"
        static let shotEnabled = "screenshotsEnabled", shotKey = "screenshotKeyCode", shotMods = "screenshotMods"
        static let usageCount = "usageCount", usageInput = "usageInputTokens", usageOutput = "usageOutputTokens"
        static let usageCost = "usageCost"
    }

    static let defaultInstruction = """
    You are a verbatim speech transcriber. Transcribe the spoken audio exactly as said. \
    Output ONLY the transcribed text — no preamble, no quotation marks, no commentary, \
    no speaker labels, no timestamps. Preserve natural punctuation and capitalization. \
    If there is no intelligible speech, output nothing.
    """

    /// Appended to the prompt when "Remove filler words" is on. Phrased to drop
    /// only non-lexical fillers, not real words, and to tidy the result.
    static let fillerDirective = """
    Additionally, remove filler words and speech disfluencies — for example "um", "uh", "er", "erm", \
    "ah", "hmm" — along with false starts, repeated words, and stutters. Keep the speaker's actual words \
    and meaning fully intact; only drop the non-lexical fillers, and fix the surrounding spacing and \
    punctuation so the text reads cleanly.
    """

    /// The transcription prompt actually sent to Gemini, with opt-in add-ons applied.
    var effectiveInstruction: String {
        removeFillers ? instruction + "\n\n" + AppState.fillerDirective : instruction
    }

    init() {
        apiKey      = Keychain.get() ?? ""
        model       = d.string(forKey: K.model) ?? "gemini-2.5-flash"
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
        maxRecordingSeconds = d.object(forKey: K.maxRecording) as? Int ?? 60
        removeFillers       = d.object(forKey: K.removeFillers) as? Bool ?? false
        muteWhileRecording  = d.object(forKey: K.muteWhileRecording) as? Bool ?? true

        screenshotsEnabled  = d.object(forKey: K.shotEnabled) as? Bool ?? true
        // Default trigger: a clean tap of Right ⌘ (keyCode 54), no extra modifiers.
        screenshotKeyCode   = d.object(forKey: K.shotKey) as? Int ?? 54
        screenshotMods      = d.integer(forKey: K.shotMods)

        usageCount        = d.integer(forKey: K.usageCount)
        usageInputTokens  = d.integer(forKey: K.usageInput)
        usageOutputTokens = d.integer(forKey: K.usageOutput)
        usageCost         = d.double(forKey: K.usageCost)

        if let data = d.data(forKey: K.recents),
           let items = try? JSONDecoder().decode([TranscriptItem].self, from: data) {
            recents = items
        }
    }

    func recordUsage(input: Int, output: Int, model: String) {
        usageCount += 1
        usageInputTokens += input
        usageOutputTokens += output
        usageCost += GeminiPricing.cost(model: model, inputTokens: input, outputTokens: output)
    }

    func resetUsage() {
        usageCount = 0
        usageInputTokens = 0
        usageOutputTokens = 0
        usageCost = 0
    }

    func addRecent(_ text: String) {
        recents.insert(TranscriptItem(text: text, date: Date()), at: 0)
        if recents.count > 25 { recents = Array(recents.prefix(25)) }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { d.set(data, forKey: K.recents) }
    }
}
