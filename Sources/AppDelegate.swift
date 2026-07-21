import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// Wires the menu-bar UI, the global hotkey, the recorder, Gemini, and text
/// injection together. All methods here run on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private let engine = HotkeyEngine()
    private let shotEngine = HotkeyEngine()
    private let retryEngine = HotkeyEngine()
    private let shots = ScreenshotController()
    private let answerPanel = AnswerPanel()
    private let recorder = Recorder()
    /// Set when we muted system audio for this take, so we restore exactly what
    /// we changed at the end (and never touch audio we didn't mute).
    private var audioRestore: SystemAudio.Restore?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var transcribeTask: Task<Void, Never>?
    /// Forces back to a usable state if a transcription wedges (network hang, etc.).
    private var transcribeWatchdog: Timer?
    /// Bumped per transcription so a stale or cancelled task's late result is ignored.
    private var transcribeGeneration = 0
    private var engineRetry: Timer?
    private var recordTimer: Timer?
    private var silenceTimer: Timer?
    /// Native indeterminate spinner shown in the menu bar while transcribing.
    private var progressSpinner: NSProgressIndicator!

    private let minimumDuration: TimeInterval = 0.3

    /// Everything needed to redo the last completed dictation: the audio it came
    /// from, the text Gemini produced, and exactly what was put on screen so the
    /// retry can take it back before replacing it.
    private struct RetryableTake {
        let audioURL: URL
        let text: String
        let insertedCount: Int
        let completedAt: Date
    }
    /// The most recent completed take, kept (audio included) so a double-tap of
    /// the hotkey can delete its text and send the same audio back to Gemini.
    private var lastTake: RetryableTake?
    /// When the last sub-`minimumDuration` take ended — two of those in quick
    /// succession are the retry gesture, not two failed dictations.
    private var lastTapAt: Date?
    private let retryTapWindow: TimeInterval = 0.8
    /// After this long the inserted text is no longer plausibly "just landed" —
    /// the cursor has almost certainly moved on, so deleting behind it is unsafe.
    private let retryWindow: TimeInterval = 30

    // No-audio detection: if the mic produces nothing above `silenceThreshold` dBFS
    // within `silenceGrace` seconds of starting, assume it's muted/off and bail out
    // with an error rather than letting the user talk into silence. The threshold sits
    // well above a dead mic's floor (~-120 dBFS) yet far below any real speech, so a
    // working mic clears it the moment the user makes a sound.
    private let silenceThreshold: Float = -60
    private let silenceGrace: TimeInterval = 4
    /// Set true once any real input level is seen; once true the take is never aborted
    /// for silence (so a natural pause mid-dictation can't trip the watchdog).
    private var sawAudioSignal = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notify.setup()
        setupStatusItem()

        state.onHotkeyOrModeChange = { [weak self] in self?.applyHotkeyConfig() }
        engine.onStart  = { [weak self] in self?.startRecording() }
        engine.onStop   = { [weak self] in self?.stopAndTranscribe() }
        engine.onCancel = { [weak self] in self?.cancelRecording() }
        engine.isActive = { [weak self] in self?.state.status == .recording }
        // If a recording dies mid-take (mic unplugged, encode error), don't keep
        // believing we're recording — recover so the next press works.
        recorder.onUnexpectedStop = { [weak self] in self?.handleRecorderFailure() }

        state.onScreenshotHotkeyChange = { [weak self] in self?.applyScreenshotHotkeyConfig() }
        state.onRecentsChange = { [weak self] in self?.rebuildMenu() }
        shotEngine.onStart = { [weak self] in self?.triggerScreenshot() }
        shots.askEnabled = { [weak self] in self?.state.askScreenshots ?? false }

        state.onRetryHotkeyChange = { [weak self] in self?.applyRetryHotkeyConfig() }
        retryEngine.onStart = { [weak self] in self?.retryLastTake() }

        // Ask for the mic up front so the first dictation isn't blocked.
        if Permissions.micStatus() == .notDetermined { Permissions.requestMic { _ in } }

        applyHotkeyConfig()
        applyScreenshotHotkeyConfig()
        applyRetryHotkeyConfig()
        if !engine.isRunning
            || (state.screenshotsEnabled && !shotEngine.isRunning)
            || (state.retryTrigger == .hotkey && !retryEngine.isRunning) { scheduleEngineRetry() }

        refreshUI()

        // Nudge first-time users toward setup.
        if state.apiKey.isEmpty || !Permissions.hasInputMonitoring() {
            openSettings(nil)
        }

        // Delay the daily update check so launch stays instant and any prompt
        // doesn't collide with first-run setup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated { Updater.shared.checkAutomatically() }
            GeminiPricing.refresh()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = micImage("mic")
            button.toolTip = "AI Buddy"
            button.setAccessibilityLabel("AI Buddy")

            // The spinner is a real view (not a template image), so it draws its own
            // appearance-adaptive spokes — light on a dark menu bar, dark on a light
            // one — with no tinting help. Centered in the button and hidden until it's
            // animating (isDisplayedWhenStopped = false).
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 16),
                spinner.heightAnchor.constraint(equalToConstant: 16),
            ])
            progressSpinner = spinner
        }
        rebuildMenu()
    }

    private func micImage(_ symbol: String, tint: NSColor? = nil) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AI Buddy") else { return nil }
        guard let tint else {
            // Template: the menu bar tints it adaptively (white on a dark bar, black
            // on a light one) — correct for the idle/transcribing glyphs.
            image.isTemplate = true
            return image
        }
        // Bake the color into a NON-template image. A template glyph's grayscale is
        // remapped by the menu bar's vibrancy for contrast, which silently flips an
        // explicit white back to black; baked pixels are drawn as authored.
        let colored = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? image
        colored.isTemplate = false
        return colored
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusMI = NSMenuItem(title: menuStatusText(), action: nil, keyEquivalent: "")
        statusMI.isEnabled = false
        menu.addItem(statusMI)
        menu.addItem(.separator())

        switch state.status {
        case .recording:
            let stopMI = NSMenuItem(title: "Stop Listening", action: #selector(manualToggle), keyEquivalent: "")
            stopMI.target = self
            menu.addItem(stopMI)
            let cancelMI = NSMenuItem(title: "Cancel (discard)", action: #selector(cancelFromMenu), keyEquivalent: "")
            cancelMI.target = self
            menu.addItem(cancelMI)
        case .transcribing:
            // Always offer a way out while transcribing so a slow or stuck request
            // never forces an app restart.
            let cancelMI = NSMenuItem(title: "Cancel transcription", action: #selector(cancelFromMenu), keyEquivalent: "")
            cancelMI.target = self
            menu.addItem(cancelMI)
        default:
            let startMI = NSMenuItem(title: "Start Listening", action: #selector(manualToggle), keyEquivalent: "")
            startMI.target = self
            menu.addItem(startMI)
            if hasRetryableTake {
                let retryMI = NSMenuItem(title: "Retry Last Take", action: #selector(retryFromMenu), keyEquivalent: "")
                retryMI.target = self
                retryMI.toolTip = "Delete what the last take inserted and send its audio back to Gemini for a second pass."
                menu.addItem(retryMI)
            }
        }

        let shotMI = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot), keyEquivalent: "")
        shotMI.target = self
        menu.addItem(shotMI)

        let recentsMI = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if state.recents.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for item in state.recents.prefix(10) {
                let mi = NSMenuItem(title: shorten(item.text), action: #selector(insertRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.text
                mi.toolTip = "\(RelativeTime.string(item.date)) — click to insert at cursor and copy\n\n\(item.text)"
                sub.addItem(mi)
            }
        }
        recentsMI.submenu = sub
        menu.addItem(recentsMI)
        menu.addItem(.separator())

        let settingsMI = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsMI.target = self
        menu.addItem(settingsMI)

        let aboutMI = NSMenuItem(title: "About AI Buddy", action: #selector(showAbout), keyEquivalent: "")
        aboutMI.target = self
        menu.addItem(aboutMI)

        let updateMI = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateMI.target = self
        menu.addItem(updateMI)

        let quitMI = NSMenuItem(title: "Quit AI Buddy", action: #selector(quit), keyEquivalent: "q")
        quitMI.target = self
        menu.addItem(quitMI)

        statusItem.menu = menu
    }

    private func menuStatusText() -> String {
        switch state.status {
        case .idle:         return "Idle"
        case .recording:    return "● Listening…"
        case .transcribing: return "Transcribing…"
        case .error:        return "Last attempt failed"
        }
    }

    private func shorten(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
    }

    // MARK: Hotkey

    private func applyHotkeyConfig() {
        let flags = cgFlags(fromNSRaw: state.hotkeyMods)
        let mode: HotkeyEngine.Mode = (state.triggerMode == .hold) ? .holdToTalk : .toggle
        engine.update(keyCode: CGKeyCode(state.hotkeyKeyCode), flags: flags, mode: mode)
        _ = engine.start() // idempotent; no-op if already running
    }

    private func applyScreenshotHotkeyConfig() {
        guard state.screenshotsEnabled else { shotEngine.stop(); return }
        let flags = cgFlags(fromNSRaw: state.screenshotMods)
        shotEngine.update(keyCode: CGKeyCode(state.screenshotKeyCode), flags: flags, mode: .tap)
        _ = shotEngine.start()
    }

    private func applyRetryHotkeyConfig() {
        guard state.retryTrigger == .hotkey else { retryEngine.stop(); return }
        let flags = cgFlags(fromNSRaw: state.retryMods)
        retryEngine.update(keyCode: CGKeyCode(state.retryKeyCode), flags: flags, mode: .tap)
        _ = retryEngine.start()
    }

    /// Hotkey path — only fires when the screenshot shortcut is enabled.
    private func triggerScreenshot() {
        guard state.screenshotsEnabled else { return }
        captureScreenshot()
    }

    /// Menu path — an explicit click, so it always works regardless of the hotkey toggle.
    @objc private func takeScreenshot() { captureScreenshot() }

    /// Shared capture: prompt for Screen Recording if missing, otherwise start an
    /// interactive selection grab.
    private func captureScreenshot() {
        guard Permissions.hasScreenRecording() else {
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
            Notify.show("Screen Recording needed",
                        "Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording, then try again.")
            return
        }
        shots.captureInteractive()
    }

    private func cgFlags(fromNSRaw raw: Int) -> CGEventFlags {
        let m = NSEvent.ModifierFlags(rawValue: UInt(raw))
        var f = CGEventFlags()
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option)  { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.shift)   { f.insert(.maskShift) }
        return f
    }

    private func scheduleEngineRetry() {
        engineRetry?.invalidate()
        engineRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard Permissions.hasInputMonitoring() else { return }
            _ = self.engine.start()
            if self.state.screenshotsEnabled { _ = self.shotEngine.start() }
            if self.state.retryTrigger == .hotkey { _ = self.retryEngine.start() }
            let shotReady = !self.state.screenshotsEnabled || self.shotEngine.isRunning
            let retryReady = self.state.retryTrigger != .hotkey || self.retryEngine.isRunning
            if self.engine.isRunning && shotReady && retryReady { timer.invalidate() }
        }
    }

    // MARK: Recording flow

    private func startRecording() {
        // A new start request while a transcription is still running means "drop that
        // one, I'd rather talk again" — cancel the in-flight request and fall through
        // into a fresh recording instead of ignoring the press.
        if case .transcribing = state.status { resetToIdle() }

        guard state.status.canStartRecording else { return }

        switch Permissions.micStatus() {
        case .authorized:
            break
        case .notDetermined:
            Permissions.requestMic { _ in }
            return
        default:
            Notify.show("Microphone access needed",
                        "Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }

        // Clear any half-open recorder/audio left by a prior aborted take so a stale
        // handle can't make this recording fail.
        if let leftover = recorder.stop() { try? FileManager.default.removeItem(at: leftover.url) }
        unmuteAudioIfMuted()

        if state.muteWhileRecording { audioRestore = SystemAudio.mute() }

        do {
            try recorder.start()
            state.status = .recording
            // Open the connection now, while there's speech still to come, so the
            // handshake isn't billed to the pause after the key is released.
            GeminiClient.prewarm(apiKey: state.apiKey, model: state.model)
            if state.playSounds { Sound.start() }
            startRecordTimer()
            refreshUI()
        } catch {
            unmuteAudioIfMuted() // recording never started — restore audio
            state.status = .error(error.localizedDescription)
            refreshUI()
            resetIdleSoon()
        }
    }

    private func stopAndTranscribe() {
        guard state.status == .recording else { return }
        stopRecordTimer()
        if state.playSounds { Sound.stop() }
        unmuteAudioIfMuted()

        // The recorder can be gone even while we think we're recording (an audio
        // interruption or unplugged device tore it down). Nothing to send — reset to
        // idle rather than wedging in `.recording`.
        guard let result = recorder.stop() else {
            state.status = .idle
            refreshUI()
            return
        }

        guard result.duration >= minimumDuration else {
            try? FileManager.default.removeItem(at: result.url)
            state.status = .idle
            refreshUI()
            registerRetryTap()
            return
        }

        // A screenshot armed for a voice question turns this take into a question
        // about that shot instead of a dictation.
        if state.askScreenshots, let shotURL = shots.armedShotURL {
            askGemini(about: shotURL, audioURL: result.url)
            return
        }

        state.status = .transcribing
        refreshUI()
        startTranscribeWatchdog()

        let apiKey = state.apiKey
        let model = state.model
        let instruction = state.effectiveInstruction
        let thinkingBudget = state.thinkingBudget
        let url = result.url

        transcribeGeneration += 1
        let gen = transcribeGeneration
        transcribeTask?.cancel()
        transcribeTask = Task {
            let outcome: Result<TranscriptionResult, Error>
            do {
                outcome = .success(try await GeminiClient.transcribe(
                    audioURL: url, apiKey: apiKey, model: model, instruction: instruction,
                    thinkingBudget: thinkingBudget))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                // Drop a result the watchdog or a manual reset already moved past.
                guard let self, gen == self.transcribeGeneration else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                switch outcome {
                case .success(let result):
                    // The audio outlives a successful take: it's what a retry
                    // (double-tap) re-sends. `rememberTake` owns deleting it.
                    self.state.recordUsage(input: result.inputTokens, output: result.outputTokens, model: model)
                    self.handleTranscription(result.text, audioURL: url)
                case .failure(let error):
                    try? FileManager.default.removeItem(at: url)
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.handleError(message)
                }
            }
        }
    }

    // MARK: Retry (double-tap the hotkey to redo the last take)

    /// Called for every take too short to transcribe. One tap is just an aborted
    /// take; a second within `retryTapWindow` is the gesture to redo the last one.
    private func registerRetryTap() {
        guard state.retryTrigger == .doubleTap else { return }
        let now = Date()
        if let prev = lastTapAt, now.timeIntervalSince(prev) < retryTapWindow {
            lastTapAt = nil
            retryLastTake()
        } else {
            lastTapAt = now
        }
    }

    /// Whether there is a take the user could still retry right now.
    private var hasRetryableTake: Bool {
        guard let take = lastTake else { return false }
        return Date().timeIntervalSince(take.completedAt) < retryWindow
    }

    /// Deletes what the last take put at the cursor and sends its audio back to
    /// Gemini for a second, more careful pass (the rejected text is quoted in the
    /// prompt and a small thinking budget is allowed, so the model actually
    /// reconsiders instead of reproducing the same output).
    private func retryLastTake() {
        // The double-tap arrives at idle by construction, but the dedicated hotkey
        // and the menu item can fire mid-recording or mid-transcription.
        guard state.status.canStartRecording else { return }
        guard let take = lastTake,
              Date().timeIntervalSince(take.completedAt) < retryWindow else { return }
        lastTake = nil

        if take.insertedCount > 0, Permissions.hasAccessibility() {
            TextInjector.deleteBackward(take.insertedCount)
        }

        state.status = .transcribing
        refreshUI()
        startTranscribeWatchdog()

        let apiKey = state.apiKey
        let model = state.model
        let instruction = state.effectiveInstruction + "\n\n" + AppState.retryDirective(previous: take.text)
        let url = take.audioURL

        transcribeGeneration += 1
        let gen = transcribeGeneration
        transcribeTask?.cancel()
        transcribeTask = Task {
            let outcome: Result<TranscriptionResult, Error>
            do {
                outcome = .success(try await GeminiClient.transcribe(
                    audioURL: url, apiKey: apiKey, model: model, instruction: instruction,
                    thinkingBudget: AppState.smallThinkingBudget))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, gen == self.transcribeGeneration else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                switch outcome {
                case .success(let result):
                    self.state.recordUsage(input: result.inputTokens, output: result.outputTokens, model: model)
                    self.handleRetriedTranscription(result.text, replacing: take, audioURL: url)
                case .failure(let error):
                    // The rejected text is already deleted, so there's nothing to
                    // take back — keep the audio so another double-tap can retry.
                    self.lastTake = RetryableTake(audioURL: url, text: take.text,
                                                  insertedCount: 0, completedAt: Date())
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.handleError(message, title: "Retry failed")
                }
            }
        }
    }

    /// Lands the corrected text the same way a fresh take would, and swaps it into
    /// the history in place of the rejected wording. Kept retryable itself, so the
    /// user can double-tap again if the second attempt is still wrong.
    private func handleRetriedTranscription(_ text: String, replacing take: RetryableTake, audioURL: URL) {
        stopTranscribeWatchdog()
        state.replaceRecent(matching: take.text, with: text)

        if state.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        let inserted = insertAtCursor(text)
        rememberTake(text: text, audioURL: audioURL, inserted: inserted)
        state.status = .idle
        refreshUI()
    }

    /// Retains a completed take for the retry gesture, releasing the one it
    /// replaces (and that take's audio file) in the process.
    private func rememberTake(text: String, audioURL: URL, inserted: Bool) {
        if let old = lastTake, old.audioURL != audioURL {
            try? FileManager.default.removeItem(at: old.audioURL)
        }
        lastTake = RetryableTake(audioURL: audioURL, text: text,
                                 insertedCount: inserted ? text.count : 0,
                                 completedAt: Date())
    }

    // MARK: Voice questions about a screenshot

    /// Sends the recorded question plus the armed screenshot to Gemini and shows
    /// the answer beside the thumbnail. Mirrors the transcription flow's watchdog
    /// and generation bookkeeping so cancel/reset work the same way.
    private func askGemini(about shotURL: URL, audioURL url: URL) {
        state.status = .transcribing
        refreshUI()
        // Image + audio + the model's default thinking is slower than plain
        // transcription; give the answer twice the ceiling before calling it stuck.
        startTranscribeWatchdog(seconds: 60)

        let apiKey = state.apiKey
        let model = state.model

        transcribeGeneration += 1
        let gen = transcribeGeneration
        transcribeTask?.cancel()
        transcribeTask = Task {
            let outcome: Result<TranscriptionResult, Error>
            do {
                outcome = .success(try await GeminiClient.answerAboutImage(
                    audioURL: url, imageURL: shotURL, apiKey: apiKey, model: model,
                    instruction: AppState.askInstruction))
            } catch {
                outcome = .failure(error)
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { [weak self] in
                guard let self, gen == self.transcribeGeneration else { return }
                switch outcome {
                case .success(let result):
                    self.state.recordUsage(input: result.inputTokens, output: result.outputTokens, model: model)
                    self.handleAnswer(result.text)
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.handleError(message, title: "Couldn’t answer the question")
                }
            }
        }
    }

    /// Shows the answer and returns the hotkey to plain dictation. On failure the
    /// shot stays armed instead, so asking again is just another hotkey press.
    private func handleAnswer(_ text: String) {
        stopTranscribeWatchdog()
        shots.disarm()
        if state.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        answerPanel.show(text, nextTo: shots.stackFrame)
        state.status = .idle
        refreshUI()
    }

    /// Discards an in-progress recording without sending it to Gemini.
    private func cancelRecording() {
        guard state.status == .recording else { return }
        stopRecordTimer()
        if let result = recorder.stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
        if state.playSounds { Sound.stop() }
        unmuteAudioIfMuted()
        state.status = .idle
        refreshUI()
    }

    /// Restores the system audio we muted at record start, if any.
    private func unmuteAudioIfMuted() {
        guard let restore = audioRestore else { return }
        audioRestore = nil
        SystemAudio.restore(restore)
    }

    /// Hard reset to a known-good idle state from anywhere — the recovery path so a
    /// stuck recording or transcription never needs an app restart.
    private func resetToIdle() {
        transcribeGeneration += 1        // drop any in-flight transcription's result
        transcribeTask?.cancel()
        transcribeTask = nil
        stopTranscribeWatchdog()
        stopRecordTimer()
        if state.status == .recording, state.playSounds { Sound.stop() }
        if let leftover = recorder.stop() { try? FileManager.default.removeItem(at: leftover.url) }
        unmuteAudioIfMuted()
        state.status = .idle
        refreshUI()
    }

    /// Called when the recorder stops on its own mid-take (encode error, device
    /// loss). Recover, then surface a brief error so the user knows the take was lost.
    private func handleRecorderFailure() {
        guard state.status == .recording else { return }
        resetToIdle()
        handleError("Recording stopped unexpectedly. Please try again.")
    }

    // MARK: Transcription watchdog (hard ceiling so `.transcribing` can't wedge)

    private func startTranscribeWatchdog(seconds: TimeInterval = 30) {
        stopTranscribeWatchdog()
        // Hard cap: cancel a stalled request and reset, so a slow or hung network
        // never leaves the app stuck transcribing with no way back.
        transcribeWatchdog = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, case .transcribing = self.state.status else { return }
            self.transcribeGeneration += 1   // ignore the in-flight task's eventual result
            self.transcribeTask?.cancel()
            self.transcribeTask = nil
            self.handleError("Transcription timed out. Please try again.")
        }
    }

    private func stopTranscribeWatchdog() {
        transcribeWatchdog?.invalidate()
        transcribeWatchdog = nil
    }

    // MARK: Recording timer (live elapsed display + max-duration safety cap)

    private func startRecordTimer() {
        recordTimer?.invalidate()
        updateElapsedTitle()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateElapsedTitle()
            let cap = self.state.maxRecordingSeconds
            if cap > 0, self.recorder.currentTime >= Double(cap) {
                self.stopAndTranscribe() // hit the safety cap — wrap up the take
            }
        }
        startSilenceMonitor()
    }

    private func stopRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
        stopSilenceMonitor()
        statusItem.button?.title = ""
    }

    // MARK: No-audio watchdog (catches a muted/off mic recording silence)

    /// Polls the input level at the start of a take. If a real signal shows up, the
    /// mic is live and we stop watching. If the grace window passes with nothing but
    /// silence, the mic is almost certainly muted or off — abort and tell the user.
    private func startSilenceMonitor() {
        sawAudioSignal = false
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.state.status == .recording else { return }
            if self.recorder.peakLevel() > self.silenceThreshold {
                self.sawAudioSignal = true
                self.stopSilenceMonitor() // mic is live — no need to keep checking
                return
            }
            if self.recorder.currentTime >= self.silenceGrace {
                self.handleNoAudioDetected()
            }
        }
    }

    private func stopSilenceMonitor() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    /// The mic produced only silence after starting — discard the take and surface a
    /// clear error so the user fixes the mic instead of talking into the void.
    private func handleNoAudioDetected() {
        guard state.status == .recording else { return }
        // Discard the silent take and restore audio, like a cancel, but signal an error
        // instead of a clean stop.
        stopRecordTimer() // also stops the no-audio watchdog
        if let result = recorder.stop() { try? FileManager.default.removeItem(at: result.url) }
        unmuteAudioIfMuted()
        if state.playSounds { Sound.error() }
        state.status = .error("No sound from the microphone — it looks muted or off.")
        refreshUI()
        resetIdleSoon()
        // A banner is easy to miss (and needs Notification permission), so show a dialog
        // the user can't overlook — they may have been talking, not watching the screen.
        presentNoAudioAlert()
    }

    /// Foreground, modal warning that the mic captured nothing, with a shortcut to the
    /// Sound settings where input is muted/selected.
    private func presentNoAudioAlert() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No sound was recorded"
            alert.informativeText = "Your microphone appears to be muted or off, so nothing was captured. Check it in System Settings ▸ Sound ▸ Input, then try again."
            alert.addButton(withTitle: "Open Sound Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func updateElapsedTitle() {
        guard let button = statusItem.button else { return }
        // Render the timer explicitly white with monospaced digits: a plain title
        // inherits a non-adaptive dark color that's invisible on the dark menu bar,
        // and monospaced digits keep the width from jittering as the seconds tick.
        button.attributedTitle = NSAttributedString(
            string: " " + clockString(recorder.currentTime),
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
    }

    private func handleTranscription(_ text: String, audioURL: URL) {
        stopTranscribeWatchdog()
        state.addRecent(text)

        if state.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        let inserted = insertAtCursor(text)
        rememberTake(text: text, audioURL: audioURL, inserted: inserted)
        state.status = .idle
        refreshUI()
    }

    /// Puts `text` at the cursor when settings and the system allow it; returns
    /// whether it was actually inserted. When secure input or a missing permission
    /// blocks synthetic keystrokes, the text goes to the clipboard (even with the
    /// clipboard setting off — it must not just vanish) and a notification says why.
    private func insertAtCursor(_ text: String) -> Bool {
        guard state.insertAtCursor else { return false }

        func fallBackToClipboard(_ title: String, _ body: String) {
            if !state.copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Notify.show(title, body)
        }

        if TextInjector.secureInputActive {
            fallBackToClipboard("A password field is blocking insertion",
                                "Secure input is on (a password field or secure app has the keyboard), so typed text would vanish. Your text is on the clipboard — paste it with ⌘V.")
            return false
        }
        guard Permissions.hasAccessibility() else {
            Permissions.requestAccessibility()
            fallBackToClipboard("Accessibility needed to insert text",
                                "Your transcription is on the clipboard. Enable Accessibility to auto-insert it.")
            return false
        }
        TextInjector.deliver(text, typeInstead: state.typeInsteadOfPaste)
        return true
    }

    private func handleError(_ message: String, title: String = "Transcription failed") {
        stopTranscribeWatchdog()
        if state.playSounds { Sound.error() }
        state.status = .error(message)
        Notify.show(title, message)
        refreshUI()
        resetIdleSoon()
    }

    private func resetIdleSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if case .error = self?.state.status {
                self?.state.status = .idle
                self?.refreshUI()
            }
        }
    }

    // MARK: UI refresh

    private func refreshUI() {
        if let button = statusItem.button {
            switch state.status {
            case .recording:
                hideSpinner()
                // Force the button into dark appearance so the explicitly-white timer
                // text isn't remapped to black by the menu bar's vibrancy, and pair it
                // with a baked-white (non-template) mic glyph so both read white.
                button.appearance = NSAppearance(named: .darkAqua)
                button.image = micImage("mic.fill", tint: .white)
                button.contentTintColor = nil
            case .transcribing:
                // Run the native spinner while we wait on Gemini, so the menu bar reads
                // as busy rather than a frozen glyph.
                showSpinner()
            default:
                hideSpinner()
                button.appearance = nil
                button.image = micImage("mic")
                button.contentTintColor = nil
                button.title = ""
            }
        }
        rebuildMenu()
    }

    // MARK: Transcribing spinner

    /// Hide the glyph and run the native spinner. A fixed status width gives the
    /// centered spinner room to draw — variableLength would collapse to nothing once
    /// the image and title are cleared.
    private func showSpinner() {
        guard let button = statusItem.button else { return }
        button.appearance = nil
        button.contentTintColor = nil
        button.image = nil
        button.title = ""
        statusItem.length = 28
        progressSpinner.startAnimation(nil)
    }

    /// Stop the spinner (auto-hides via isDisplayedWhenStopped) and let the button
    /// resize to its glyph again.
    private func hideSpinner() {
        progressSpinner.stopAnimation(nil)
        statusItem.length = NSStatusItem.variableLength
    }

    // MARK: Actions

    @objc private func manualToggle() {
        if state.status == .recording { stopAndTranscribe() }
        else if state.status.canStartRecording { startRecording() }
    }

    @objc private func retryFromMenu() { retryLastTake() }

    @objc private func cancelFromMenu() {
        switch state.status {
        case .recording:    cancelRecording()
        case .transcribing: resetToIdle()
        default:            break
        }
    }

    /// Re-uses a past transcription: copies it, and (if enabled) re-inserts it at
    /// the cursor once the menu has dismissed and focus returns to the prior app.
    @objc private func insertRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        if state.copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        guard state.insertAtCursor, Permissions.hasAccessibility() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            TextInjector.deliver(text, typeInstead: self?.state.typeInsteadOfPaste ?? false)
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let window = NSWindow(contentViewController: hosting)
            window.title = "AI Buddy"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 740, height: 600))
            window.contentMinSize = NSSize(width: 660, height: 480)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Modal About panel: app identity, version, and buttons out to the website
    /// and the source on GitHub.
    @objc private func showAbout() {
        let website = "claudete.co/ai-buddy"
        let websiteURL = URL(string: "https://\(website)")
        let github = "github.com/morion4000/ai-buddy"
        let githubURL = URL(string: "https://\(github)")

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let versionLine = version.isEmpty ? "" : "Version \(version)\(build.isEmpty ? "" : " (\(build))")\n\n"

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "AI Buddy"
        alert.informativeText = """
        \(versionLine)Push-to-talk dictation for your Mac. Press your hotkey, speak, \
        and Gemini transcribes it straight to your cursor.

        \(website)
        \(github)
        """
        alert.addButton(withTitle: "Visit Website")
        alert.addButton(withTitle: "GitHub")
        alert.addButton(withTitle: "OK")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  if let websiteURL { NSWorkspace.shared.open(websiteURL) }
        case .alertSecondButtonReturn: if let githubURL { NSWorkspace.shared.open(githubURL) }
        default: break
        }
    }

    @objc private func checkForUpdates() {
        // Menu actions always arrive on the main thread.
        MainActor.assumeIsolated { Updater.shared.check(userInitiated: true) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
