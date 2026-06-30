import AppKit
import CoreAudio
import UserNotifications

/// Formats a past `Date` as a short relative string ("just now", "2 min ago").
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    static func string(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 5 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Formats an elapsed duration in seconds as `m:ss` (e.g. "1:07").
func clockString(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Subtle audio feedback when recording starts/stops.
enum Sound {
    static func start() {
        // Quieter than default so the cue doesn't bleed into the first moment of
        // captured audio (the mic is live the instant this plays).
        let s = NSSound(named: "Tink")
        s?.volume = 0.25
        s?.play()
    }
    static func stop()  { NSSound(named: "Pop")?.play() }
}

/// Mutes the system's default audio output while recording, then puts it back
/// exactly as it was — so playback you can't (or didn't) pause won't bleed into
/// the mic. Unlike toggling the mute key, this saves and restores the prior
/// state, so it never accidentally un-mutes audio that was already muted.
enum SystemAudio {
    /// Captures what we changed so `restore` can undo precisely that.
    struct Restore {
        let device: AudioDeviceID
        let change: Change
        enum Change {
            case mute(prior: UInt32)    // we flipped the device's mute switch
            case volume(prior: Float)   // fallback: we dropped the master volume
        }
    }

    /// Mutes the default output. Returns a token to pass back to `restore`,
    /// or nil if the device exposes no settable mute/volume (nothing changed).
    @discardableResult
    static func mute() -> Restore? {
        guard let device = defaultOutputDevice() else { return nil }

        // Preferred: the device's master mute switch — clean and fully reversible.
        var muteAddr = address(kAudioDevicePropertyMute)
        if isSettable(device, &muteAddr) {
            var prior: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &prior) == noErr {
                var on: UInt32 = 1
                if AudioObjectSetPropertyData(device, &muteAddr, 0, nil, size, &on) == noErr {
                    return Restore(device: device, change: .mute(prior: prior))
                }
            }
        }

        // Fallback: some outputs lack a mute switch — drop the master volume to 0.
        var volAddr = address(kAudioDevicePropertyVolumeScalar)
        if isSettable(device, &volAddr) {
            var prior: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &volAddr, 0, nil, &size, &prior) == noErr {
                var zero: Float = 0
                if AudioObjectSetPropertyData(device, &volAddr, 0, nil, size, &zero) == noErr {
                    return Restore(device: device, change: .volume(prior: prior))
                }
            }
        }
        return nil
    }

    /// Restores whatever `mute` changed back to its previous value.
    static func restore(_ r: Restore) {
        switch r.change {
        case .mute(let prior):
            var addr = address(kAudioDevicePropertyMute)
            var value = prior
            _ = AudioObjectSetPropertyData(r.device, &addr, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &value)
        case .volume(let prior):
            var addr = address(kAudioDevicePropertyVolumeScalar)
            var value = prior
            _ = AudioObjectSetPropertyData(r.device, &addr, 0, nil,
                                           UInt32(MemoryLayout<Float>.size), &value)
        }
    }

    // MARK: CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ device: AudioDeviceID,
                                   _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }
}

/// User-facing notifications (errors, hints). Falls back to NSLog if the app
/// isn't running as a proper bundle (e.g. invoked as a bare binary).
enum Notify {
    static func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func show(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("[AIBuddy] %@: %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
