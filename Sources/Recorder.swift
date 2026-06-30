import AVFoundation

/// Records the microphone to a temporary 16 kHz mono 16-bit PCM WAV file —
/// small, lossless, and directly accepted by Gemini as `audio/wav`.
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    /// Called on the main thread if recording stops on its own — an encode error or
    /// an interruption/device loss the recorder couldn't survive — and never on a
    /// normal `stop()`. Lets the app recover instead of believing it's still recording.
    var onUnexpectedStop: (() -> Void)?

    func start() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-dictation-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let rec = try AVAudioRecorder(url: file, settings: settings)
        rec.delegate = self
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
