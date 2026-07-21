import SwiftUI
import AVFoundation
import ServiceManagement

/// The sections shown in the settings sidebar, in order.
enum SettingsTab: String, CaseIterable, Hashable {
    case gemini, trigger, output, screenshots, usage, permissions, advanced

    var title: String {
        switch self {
        case .gemini:      return "Gemini"
        case .trigger:     return "Trigger"
        case .output:      return "Output"
        case .screenshots: return "Screenshots"
        case .usage:       return "Usage & Cost"
        case .permissions: return "Permissions"
        case .advanced:    return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .gemini:      return "sparkles"
        case .trigger:     return "keyboard"
        case .output:      return "text.cursor"
        case .screenshots: return "camera.viewfinder"
        case .usage:       return "dollarsign.circle"
        case .permissions: return "lock.shield"
        case .advanced:    return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var selection: SettingsTab? = .gemini
    @State private var tick = 0
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var showingClearHistoryConfirmation = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let modelPresets = [
        "gemini-3.5-flash",
        "gemini-2.5-flash",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
        "gemini-flash-latest",
    ]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                Divider()
                List(SettingsTab.allCases, id: \.self, selection: $selection) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 250)
        } detail: {
            ScrollView {
                detail(for: selection ?? .gemini)
                    .padding(22)
                    .frame(maxWidth: 540, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(timer) { _ in tick &+= 1 } // refresh permission states periodically
    }

    /// The detail pane for a section: an icon + title heading above its content.
    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(tab.title).font(.title2.bold())
            }
            switch tab {
            case .gemini:      geminiContent
            case .trigger:     triggerContent
            case .output:      outputContent
            case .screenshots: screenshotContent
            case .usage:       usageContent
            case .permissions: permissionsContent
            case .advanced:    advancedContent
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Buddy").font(.title3.bold())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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

    private var geminiContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Text("Any audio-capable Gemini model works. gemini-3.5-flash is the default; gemini-2.5-flash-lite is faster and cheaper for simple dictation.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Enable thinking", isOn: $state.enableThinking)
                Text("Off by default and recommended off — transcription needs no reasoning, so thinking mostly just adds delay. When on, only a small thinking budget is used.")
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

    private var triggerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Redo a bad take").font(.subheadline.weight(.medium))
                Picker("Retry trigger", selection: $state.retryTrigger) {
                    ForEach(RetryTrigger.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if state.retryTrigger == .hotkey {
                    HStack {
                        Text("Retry hotkey").font(.subheadline.weight(.medium))
                        Spacer()
                        ShortcutRecorderView(keyCode: $state.retryKeyCode, mods: $state.retryMods)
                    }
                }
                Text(retryHelp)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var retryHelp: String {
        switch state.retryTrigger {
        case .doubleTap:
            return "Double-tap the talk hotkey within 30 seconds of a take: the text it inserted is deleted and the same audio goes back to Gemini for a more careful second pass."
        case .hotkey:
            return "Tap the retry hotkey within 30 seconds of a take: the text it inserted is deleted and the same audio goes back to Gemini for a more careful second pass."
        case .off:
            return "No retry shortcut. Retry Last Take stays available in the menu bar for 30 seconds after each take."
        }
    }

    // MARK: Output

    private var outputContent: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            Divider().padding(.vertical, 2)
            languagesSection
        }
    }

    /// Multi-select of the languages the speaker dictates in. English is always on.
    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spoken languages").font(.subheadline.weight(.medium))
            Text("Limits transcription to the languages you pick, so the output never drifts into an unwanted one. English is always on — add any others you dictate in.")
                .font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(AppState.supportedLanguages, id: \.self) { lang in
                    Toggle(lang, isOn: languageBinding(lang))
                        .toggleStyle(.checkbox)
                        .disabled(lang == "English")
                }
            }
            .padding(.top, 2)
        }
    }

    /// On/off binding for one language, backed by the persisted `languages` array.
    private func languageBinding(_ lang: String) -> Binding<Bool> {
        Binding(
            get: { state.languages.contains(lang) },
            set: { on in
                if on {
                    if !state.languages.contains(lang) { state.languages.append(lang) }
                } else {
                    state.languages.removeAll { $0 == lang }
                }
            })
    }

    // MARK: Screenshots

    private var screenshotContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable screenshot hotkey", isOn: $state.screenshotsEnabled)
            HStack {
                Text("Hotkey").font(.subheadline.weight(.medium))
                Spacer()
                ShortcutRecorderView(keyCode: $state.screenshotKeyCode, mods: $state.screenshotMods)
            }
            .disabled(!state.screenshotsEnabled)
            Text("Tap it, draw a region, and the shot floats on the right edge — drag it into any app, click to copy, ✕ to dismiss. A single modifier needs a clean tap (so ⌘-shortcuts won’t trigger it). Needs Screen Recording permission.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Toggle("Ask about a new shot with your voice", isOn: $state.askScreenshots)
            Text("Right after a capture, hold your talk hotkey and ask a question about it — Gemini’s answer pops up beside the thumbnail, then the hotkey goes back to dictation. The shot’s mic badge shows when it’s listening for a question; click the badge to switch it on or off per shot.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Usage & cost

    private var usageContent: some View {
        let r = GeminiPricing.rates(for: state.model)
        let month = AppState.monthKey()
        let thisMonth = state.usageBuckets
            .filter { $0.month == month }
            .sorted { $0.cost > $1.cost }
        let monthCost = thisMonth.reduce(0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 10) {
            Text("This month").font(.subheadline.weight(.semibold))
            if thisMonth.isEmpty {
                Text("No transcriptions yet this month.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(thisMonth) { b in
                    HStack {
                        Text(b.model)
                        Spacer()
                        Text("\(b.count) · \(tokenStr(b.inputTokens)) / \(tokenStr(b.outputTokens)) tok")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(costStr(b.cost))
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.callout)
                }
                HStack {
                    Text("Month total").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(costStr(monthCost)).font(.subheadline.weight(.semibold))
                }
            }

            Divider()

            Text("Last 6 months").font(.subheadline.weight(.semibold))
            usageTrend

            Divider()

            HStack {
                Text("All time").foregroundStyle(.secondary)
                Spacer()
                Text("\(state.usageCount) takes · \(tokenStr(state.usageInputTokens)) / \(tokenStr(state.usageOutputTokens)) tok · \(costStr(state.usageCost))")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
    }

    /// Six slim bars, one per month, scaled to the most expensive of them — the
    /// at-a-glance answer to "is this getting expensive".
    private var usageTrend: some View {
        let months = AppState.recentMonthKeys(6)
        let totals = months.map { m in
            state.usageBuckets.filter { $0.month == m }.reduce(0) { $0 + $1.cost }
        }
        let peak = max(totals.max() ?? 0, .leastNonzeroMagnitude)
        return HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(zip(months, totals)), id: \.0) { m, total in
                VStack(spacing: 3) {
                    Text(total > 0 ? costStr(total) : "—")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(m == AppState.monthKey() ? 1 : 0.45))
                        .frame(width: 36, height: max(3, 48 * total / peak))
                    Text(AppState.monthLabel(m))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Adaptive cost string: sub-cent amounts keep the detail ("$0.0042"),
    /// anything visible on a bill reads like money ("$1.28").
    private func costStr(_ v: Double) -> String {
        String(format: v < 0.01 ? "$%.4f" : "$%.2f", v)
    }

    private func tokenStr(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Compact price string: 1.0 → "1", 0.075 → "0.075", 2.5 → "2.5".
    private func rateStr(_ v: Double) -> String { String(format: "%g", v) }

    // MARK: Permissions

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Text("Custom dictionary").font(.subheadline.weight(.medium))
                TextEditor(text: $state.vocabulary)
                    .font(.callout)
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3)))
                Text("Words you use often that get misheard — names, jargon, acronyms. Separate them with commas (e.g. Gemini, Kubernetes, Ionut, GraphQL) and Gemini will prefer these exact spellings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Conversation keywords").font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("Use for transcription", isOn: $state.useConversationKeywords)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                Group {
                    if state.conversationKeywords.isEmpty {
                        Text("Keywords will appear after you save some transcriptions.")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(state.conversationKeywords.joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                .padding(7)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))

                Text("Extracted locally from your saved transcription history and used only as soft context. Unlike the custom dictionary, keywords do not force an exact spelling.")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack {
                    Text("\(state.recents.count.formatted()) of \(AppState.maxSavedTranscriptions.formatted()) transcriptions saved locally")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear saved transcriptions…", role: .destructive) {
                        showingClearHistoryConfirmation = true
                    }
                    .font(.caption)
                    .disabled(state.recents.isEmpty)
                }
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
        .alert("Clear saved transcriptions?", isPresented: $showingClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { state.clearRecents() }
        } message: {
            Text("This removes all locally saved transcription history and its conversation keywords. Your custom dictionary will not be changed.")
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
