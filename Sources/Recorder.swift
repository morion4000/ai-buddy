import AVFoundation

/// How recordings are encoded on disk before being uploaded.
///
/// AAC in an MPEG-4 container rather than the PCM WAV this used to write: at
/// 16 kHz mono it lands ~8x smaller, which matters because the whole file is
/// base64-encoded and uploaded *after* the hotkey is released, squarely in the
/// gap between speaking and seeing text. Gemini bills audio by duration, not
/// bytes, so the smaller upload costs nothing — verified against the API, where
/// WAV and AAC of the same take returned identical transcripts for 151 vs 152
/// input tokens.
enum AudioFormat {
    static let fileExtension = "m4a"
    /// The container is MPEG-4; `audio/mp4` and `audio/aac` are both accepted.
    static let mimeType = "audio/mp4"
    static let sampleRate = 16_000.0
    /// Speech at 16 kHz mono stays comfortably intelligible here. Lower bitrates
    /// shrink the file further but buy little real time back, so this keeps
    /// headroom for noisy rooms and quiet speakers.
    static let bitRate = 32_000

    static var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
    }
}

/// Records the microphone to a temporary 16 kHz mono AAC file — see `AudioFormat`.
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    /// Called on the main thread if recording stops on its own — an encode error or
    /// an interruption/device loss the recorder couldn't survive — and never on a
    /// normal `stop()`. Lets the app recover instead of believing it's still recording.
    var onUnexpectedStop: (() -> Void)?

    func start() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-dictation-\(UUID().uuidString).\(AudioFormat.fileExtension)")

        let rec = try AVAudioRecorder(url: file, settings: AudioFormat.recorderSettings)
        rec.delegate = self
        rec.isMeteringEnabled = true // so we can detect a muted/off mic recording pure silence
        rec.prepareToRecord()
        guard rec.record() else {
            throw NSError(domain: "Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the microphone."])
        }
        recorder = rec
        url = file
    }

    /// Stops recording and returns the file URL plus its duration in seconds.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let rec = recorder, let u = url else { return nil }
        let duration = rec.currentTime
        rec.stop()
        recorder = nil
        url = nil
        return (u, duration)
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Seconds recorded so far (0 when idle).
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    /// Most recent peak input level in dBFS (≈ -160 = digital silence, 0 = max).
    /// A muted or disconnected mic records pure silence and sits near the floor,
    /// which lets the app notice nothing is being captured. Returns -160 when idle.
    func peakLevel() -> Float {
        guard let rec = recorder else { return -160 }
        rec.updateMeters()
        return rec.peakPower(forChannel: 0)
    }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // `flag == true` is the normal stop()/cap path the app already handles.
        // Only an unexpected failure (false) needs recovery.
        guard !flag else { return }
        notifyUnexpectedStop()
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        notifyUnexpectedStop()
    }

    private func notifyUnexpectedStop() {
        let cb = onUnexpectedStop
        let work = { [weak self] in
            self?.recorder = nil
            self?.url = nil
            cb?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
