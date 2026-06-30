import AppKit
import CoreGraphics

/// Global hotkey engine built on a listen-only CGEventTap.
///
/// Why a CGEventTap (not Carbon RegisterEventHotKey)? It's the only approach that
/// delivers reliable, independent key-down AND key-up edges for arbitrary keys
/// *and* bare modifier keys (e.g. Right ⌥) — which hold-to-talk requires. A
/// `.listenOnly` tap needs only Input Monitoring (not Accessibility) and never
/// swallows the key, so a modifier/Fn trigger won't interfere with typing.
final class HotkeyEngine {
    enum Mode { case toggle, holdToTalk, tap }

    var onStart:  () -> Void = {}
    var onStop:   () -> Void = {}
    /// Fired when Esc is pressed (so the app can discard an in-progress take).
    var onCancel: () -> Void = {}
    /// Source of truth for "are we recording right now?", used by toggle mode so
    /// its idea of on/off can't drift from the app's actual state.
    var isActive: () -> Bool = { false }

    private var mode: Mode = .holdToTalk
    private var targetKeyCode: CGKeyCode = 61
    private var targetFlags: CGEventFlags = []

    private var tap: CFMachPort?
    private var src: CFRunLoopSource?
    private var watchdog: Timer?
    private var isDown = false
    // .tap-mode bookkeeping for clean-tap detection of a bare modifier.
    private var tapArmed = false
    private var tapDirty = false

    private let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    // Keycodes that are themselves modifier keys (no caps-lock). Used to decide
    // whether the trigger arrives via .flagsChanged instead of .keyDown/.keyUp.
    private let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    var isRunning: Bool { tap != nil }
    private var isModifierTrigger: Bool { modifierKeyCodes.contains(targetKeyCode) }

    func update(keyCode: CGKeyCode, flags: CGEventFlags, mode: Mode) {
        targetKeyCode = keyCode
        targetFlags = flags.intersection(relevant)
        self.mode = mode
        isDown = false
    }

    /// Installs the tap. Returns false (and prompts for Input Monitoring) if the
    /// permission isn't granted yet.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyEngine>.fromOpaque(refcon!).takeUnretainedValue()
                me.handle(type, event)
                return Unmanaged.passUnretained(event) // never swallow in .listenOnly
            },
            userInfo: ctx
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.src = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        return true
    }

    func stop() {
        if let s = src { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        watchdog?.invalidate()
        watchdog = nil
        src = nil
        tap = nil
        isDown = false
    }

    // The system can silently disable a tap (timeout / heavy input). A non-nil
    // tap isn't necessarily a live one — poll and re-arm.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let t = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        let code  = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(relevant)

        if mode == .tap { handleTap(type, code: code, flags: flags, event: event); return }

        switch type {
        case .keyDown:
            // Esc always discards an in-progress take (unless Esc *is* the trigger).
            if code == 53, targetKeyCode != 53 { dispatch(onCancel); return }
            guard !isModifierTrigger, code == targetKeyCode, flags == targetFlags else { return }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            fireDown()
        case .keyUp:
            guard !isModifierTrigger, code == targetKeyCode else { return }
            fireUp()
        case .flagsChanged:
            guard isModifierTrigger, code == targetKeyCode else { return }
            isModifierPressed(code: code, flags: event.flags) ? fireDown() : fireUp()
        default:
            break
        }
    }

    /// One-shot "tap to trigger". For a regular key: fire on its key-down. For a
    /// bare modifier: fire only on a clean tap — pressed and released with no
    /// other key in between — so it never fires during ⌘C-style shortcuts.
    private func handleTap(_ type: CGEventType, code: CGKeyCode, flags: CGEventFlags, event: CGEvent) {
        guard isModifierTrigger else {
            if type == .keyDown, code == targetKeyCode, flags == targetFlags,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                dispatch(onStart)
            }
            return
        }
        switch type {
        case .flagsChanged where code == targetKeyCode:
            if isModifierPressed(code: code, flags: event.flags) {
                tapArmed = true; tapDirty = false
            } else {
                if tapArmed && !tapDirty { dispatch(onStart) }
                tapArmed = false
            }
        case .keyDown, .flagsChanged:
            if tapArmed { tapDirty = true } // another key/modifier → not a clean tap
        default:
            break
        }
    }

    private func isModifierPressed(code: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch code {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63:     return flags.contains(.maskSecondaryFn)
        default:     return false
        }
    }

    private func fireDown() {
        switch mode {
        case .holdToTalk:
            if !isDown { isDown = true; dispatch(onStart) }
        case .toggle:
            // Ask the app what it's actually doing rather than tracking our own
            // flag, which could desync if a start/stop request gets rejected.
            if isActive() { dispatch(onStop) } else { dispatch(onStart) }
        case .tap:
            break // handled in handleTap; fireDown is never called in this mode
        }
    }

    private func fireUp() {
        guard mode == .holdToTalk, isDown else { return }
        isDown = false
        dispatch(onStop)
    }

    private func dispatch(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
