import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// Thin wrappers over the three macOS permissions this app needs:
///  • Microphone        — to record your voice
///  • Input Monitoring  — for the global hotkey (CGEventTap, listen-only)
///  • Accessibility     — to type/paste the transcription into other apps
enum Permissions {

    // MARK: Microphone
    static func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
    static func requestMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Input Monitoring (for the listen-only key tap)
    static func hasInputMonitoring() -> Bool { CGPreflightListenEventAccess() }
    static func requestInputMonitoring() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
    }

    // MARK: Accessibility (for posting paste / typing events)
    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    // MARK: Screen Recording (for screen-region capture)
    static func hasScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording()      { _ = CGRequestScreenCaptureAccess() }

    // MARK: Deep-links into System Settings
    static func openMicSettings()             { openSettings("Privacy_Microphone") }
    static func openInputMonitoringSettings() { openSettings("Privacy_ListenEvent") }
    static func openAccessibilitySettings()   { openSettings("Privacy_Accessibility") }
    static func openScreenRecordingSettings() { openSettings("Privacy_ScreenCapture") }

    private static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
