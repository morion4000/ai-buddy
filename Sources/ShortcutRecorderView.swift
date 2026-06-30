import SwiftUI
import AppKit

/// A button that records a new global shortcut. Click it, then press any key
/// (with optional modifiers) or a single modifier key like Right ⌥. Uses a
/// *local* event monitor, so it needs no special permission.
struct ShortcutRecorderView: View {
    @Binding var keyCode: Int
    @Binding var mods: Int
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(label)
                .frame(minWidth: 200)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .help("Click, then press the key or modifier you want to use as your hotkey.")
        .onDisappear(perform: removeMonitor)
    }

    private var label: String {
        if recording { return "Press a key…  (Esc to cancel)" }
        return KeyDisplay.string(keyCode: keyCode,
                                 mods: NSEvent.ModifierFlags(rawValue: UInt(mods)))
    }

    private func toggle() { recording ? cancel() : begin() }

    private func begin() {
        recording = true
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { cancel(); return nil } // Esc cancels
                capture(keyCode: Int(event.keyCode), mods: event.modifierFlags.intersection(relevant))
                return nil // swallow so the field doesn't beep/type
            } else { // .flagsChanged — capture a lone modifier (e.g. Right ⌥)
                if let code = soloModifier(event) {
                    capture(keyCode: code, mods: [])
                    return nil
                }
                return event
            }
        }
    }

    /// Returns the keycode if a single modifier key just turned ON.
    private func soloModifier(_ event: NSEvent) -> Int? {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 54, 55: return flags.contains(.command) ? Int(event.keyCode) : nil
        case 56, 60: return flags.contains(.shift)   ? Int(event.keyCode) : nil
        case 58, 61: return flags.contains(.option)  ? Int(event.keyCode) : nil
        case 59, 62: return flags.contains(.control) ? Int(event.keyCode) : nil
        case 63:     return flags.contains(.function) ? 63 : nil
        default:     return nil
        }
    }

    private func capture(keyCode kc: Int, mods m: NSEvent.ModifierFlags) {
        keyCode = kc
        mods = Int(m.rawValue)
        cancel()
    }

    private func cancel() { recording = false; removeMonitor() }
    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
