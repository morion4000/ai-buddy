import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var tick = 0
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let modelPresets = [
        "gemini-2.5-flash",
        "gemini-3.5-flash",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
        "gemini-flash-latest",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                geminiSection
                triggerSection
                outputSection
                screenshotSection
                usageSection
                permissionsSection
                advancedSection
            }
            .padding(20)
        }
        .frame(width: 500)
        .onReceive(timer) { _ in tick &+= 1 } // refresh permission states periodically
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Buddy").font(.title3.bold())
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
        }
    }

    private var statusText: String {
        switch state.status {
        case .idle:          return "Ready — press your hotkey and speak"
        case .recording:     return "● Listening…"
        case .transcribing:  return "Transcribing with \(state.model)…"
        case .error(let m):  return m
        }
    }
    private var statusColor: Color {
        switch state.status {
        case .recording: return .red
        case .error:     return .orange
        default:         return .secondary
        }
    }

    // MARK: Gemini

    private var geminiSection: some View {
        GroupBox("Gemini") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.subheadline.weight(.medium))
                    SecureField("Paste your Gemini API key", text: $state.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get a free key from Google AI Studio →",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.subheadline.weight(.medium))
                    HStack {
                        TextField("model id", text: $state.model)
                            .textFieldStyle(.roundedBorder)
                        Menu("Presets") {
                            ForEach(modelPresets, id: \.self) { m in
                                Button(m) { state.model = m }
                            }
                        }
                        .frame(width: 100)
                    }
                    Text("Any audio-capable Gemini model works. Newest stable Flash is gemini-3.5-flash; gemini-2.5-flash is a safe default.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(testing ? "Testing…" : "Test connection") { runTest() }
                        .disabled(testing || state.apiKey.isEmpty)
                    if let r = testResult {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? Color.green : Color.red)
                        Text(r.message)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let key = state.apiKey
        let model = state.model
        Task {
            let result = await GeminiClient.validateKey(apiKey: key, model: model)
            await MainActor.run {
                testing = false
                testResult = result
            }
        }
    }

    // MARK: Trigger

    private var triggerSection: some View {
        GroupBox("Trigger") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $state.triggerMode) {
                    ForEach(TriggerMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("Hotkey").font(.subheadline.weight(.medium))
                    Spacer()
                    ShortcutRecorderView(keyCode: $state.hotkeyKeyCode, mods: $state.hotkeyMods)
                }

                Text(state.triggerMode == .hold
                     ? "Hold the hotkey while you speak, then release to transcribe. A single modifier key like Right ⌥ works great here."
                     : "Press once to start listening, press again to stop and transcribe.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Output

    private var outputSection: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Insert text at the cursor", isOn: $state.insertAtCursor)
                Toggle("Copy text to the clipboard", isOn: $state.copyToClipboard)
                Toggle("Type characters instead of pasting (fallback for apps that block paste)",
                       isOn: $state.typeInsteadOfPaste)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Clean up filler words (um, uh, er…)", isOn: $state.removeFillers)
                    Text("Asks Gemini to drop “um”, “uh”, false starts, and stutters for cleaner text.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Mute audio while recording", isOn: $state.muteWhileRecording)
                    Text("Mutes your system output so playback (YouTube, Spotify, Music, etc.) doesn't bleed into the mic, then restores it after.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Play a sound when recording starts and stops", isOn: $state.playSounds)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Screenshots

    private var screenshotSection: some View {
        GroupBox("Screenshots") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable screenshot hotkey", isOn: $state.screenshotsEnabled)
                HStack {
                    Text("Hotkey").font(.subheadline.weight(.medium))
                    Spacer()
                    ShortcutRecorderView(keyCode: $state.screenshotKeyCode, mods: $state.screenshotMods)
                }
                .disabled(!state.screenshotsEnabled)
                Text("Tap it, draw a region, and the shot floats on the right edge — drag it into any app, click to copy, ✕ to dismiss. A single modifier needs a clean tap (so ⌘-shortcuts won’t trigger it). Needs Screen Recording permission.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Usage & cost

    private var usageSection: some View {
        let r = GeminiPricing.rates(for: state.model)
        return GroupBox("Usage & cost") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transcriptions").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.usageCount)")
                }
                HStack {
                    Text("Tokens (in / out)").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tokenStr(state.usageInputTokens)) / \(tokenStr(state.usageOutputTokens))")
                }
                HStack {
                    Text("Estimated cost").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "$%.4f", state.usageCost)).font(.subheadline.weight(.semibold))
                }

                Divider()

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.known
                             ? "\(state.model): $\(rateStr(r.input)) in · $\(rateStr(r.output)) out per 1M tokens"
                             : "Unknown model — billed estimate uses gemini-2.5-flash rates ($\(rateStr(r.input)) in · $\(rateStr(r.output)) out per 1M)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Link("Gemini pricing", destination: URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!)
                            .font(.caption2)
                    }
                    Spacer()
                    Button("Reset") { state.resetUsage() }
                        .font(.caption)
                        .disabled(state.usageCount == 0)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tokenStr(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Compact price string: 1.0 → "1", 0.075 → "0.075", 2.5 → "2.5".
    private func rateStr(_ v: Double) -> String { String(format: "%g", v) }

    // MARK: Permissions

    private var permissionsSection: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    name: "Microphone", hint: "to record your voice",
                    granted: Permissions.micStatus() == .authorized) {
                        if Permissions.micStatus() == .notDetermined { Permissions.requestMic { _ in } }
                        else { Permissions.openMicSettings() }
                    }
                permissionRow(
                    name: "Input Monitoring", hint: "for the global hotkey",
                    granted: Permissions.hasInputMonitoring()) {
                        Permissions.requestInputMonitoring()
                        Permissions.openInputMonitoringSettings()
                    }
                permissionRow(
                    name: "Accessibility", hint: "to type text into other apps",
                    granted: Permissions.hasAccessibility()) {
                        Permissions.requestAccessibility()
                    }
                permissionRow(
                    name: "Screen Recording", hint: "to capture screenshots",
                    granted: Permissions.hasScreenRecording()) {
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    }
                Text("After turning on Input Monitoring, Accessibility, or Screen Recording, quit and reopen the app so the change takes effect.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(name: String, hint: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        GroupBox("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLaunchAtLogin($0) }))

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $state.maxRecordingSeconds, in: 0...300, step: 15) {
                        Text(state.maxRecordingSeconds == 0
                             ? "Max recording length: off"
                             : "Max recording length: \(state.maxRecordingSeconds)s")
                    }
                    Text("Auto-stops a recording after this long — a safety net so a missed key-release can't record (and bill) indefinitely. Set to 0 to disable.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription instruction").font(.subheadline.weight(.medium))
                    TextEditor(text: $state.instruction)
                        .font(.callout)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
                    Button("Reset to default") { state.instruction = AppState.defaultInstruction }
                        .font(.caption)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else      { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[AIBuddy] launch-at-login error: %@", error.localizedDescription)
        }
    }
}
