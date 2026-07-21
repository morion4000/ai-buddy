import AVFoundation
import Speech

/// On-device speech recognition that runs while the user is still speaking, so a
/// draft can reach the cursor without waiting for the network.
///
/// This runs *alongside* `Recorder` with its own tap on the input device rather
/// than being wired through it. Drafting is an enhancement, never a dependency:
/// if the model isn't downloaded, permission was refused, or the audio engine
/// fails to start, the take still records and Gemini still transcribes it exactly
/// as before. macOS allows several capture clients on one input device, so the
/// two coexist.
final class LiveTranscriber {

    /// Called on the main thread with the entire draft so far — not a delta, since
    /// recognition revises words it has already emitted.
    var onDraft: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var running = false

    /// Finalized text and the still-changing tail are tracked separately: a volatile
    /// update replaces the tail rather than appending a second copy of it.
    private var settled = ""
    private var pending = ""
    private var draft: String { settled + pending }

    // MARK: Authorization

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static var isDenied: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied || status == .restricted
    }

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !running, Self.isAuthorized else { return }
        running = true
        settled = ""
        pending = ""
        Task { await self.begin() }
    }

    func stop() {
        guard running else { return }
        running = false
        teardownEngine()
        continuation?.finish()
        continuation = nil
        let finishing = analyzer
        analyzer = nil
        // Let the analyzer drain what it already has; the results task ends with it.
        Task { try? await finishing?.finalizeAndFinishThroughEndOfInput() }
    }

    private func teardownEngine() {
        if engine.isRunning || engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning { engine.stop() }
    }

    // MARK: Setup

    private func begin() async {
        let locale = await Self.preferredLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // The per-locale model is a download. If it isn't present, start fetching it
        // in the background and sit this take out rather than stalling the user
        // mid-sentence; the next take gets a draft.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Task.detached { try? await request.downloadAndInstall() }
                await self.abort()
                return
            }
        } catch {
            await self.abort()
            return
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            await self.abort()
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let live = self else { return }
                    let piece = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { live.absorb(piece, isFinal: isFinal) }
                }
            } catch {
                // A failed recognition stream just means no draft for this take.
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            await self.abort()
            return
        }

        await MainActor.run {
            // stop() may have arrived while the model was being prepared.
            guard self.running else {
                continuation.finish()
                Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
                return
            }
            self.analyzer = analyzer
            self.continuation = continuation
            self.startEngine(feeding: continuation, converting: format)
        }
    }

    /// Folds one recognition result into the draft and publishes it.
    @MainActor
    private func absorb(_ piece: String, isFinal: Bool) {
        if isFinal {
            settled += piece
            pending = ""
        } else {
            pending = piece
        }
        onDraft?(draft)
    }

    @MainActor
    private func abort() {
        running = false
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func startEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                             converting target: AVAudioFormat) {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: target) else {
            running = false
            return
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: native) { buffer, _ in
            guard let converted = Self.convert(buffer, with: converter, to: target) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            running = false
        }
    }

    /// Resamples a tap buffer into the format the analyzer asked for.
    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // One tap buffer per conversion; anything more would block the tap thread.
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// The user's own locale when a model exists for it, otherwise the closest
    /// language match, otherwise English.
    private static func preferredLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        let exact = supported.first { $0.identifier(.bcp47) == current.identifier(.bcp47) }
        let sameLanguage = supported.first { $0.language.languageCode == current.language.languageCode }
        return exact ?? sameLanguage ?? Locale(identifier: "en-US")
    }
}
