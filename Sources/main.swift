import AppKit

// AI Buddy — a menu-bar-only (LSUIElement) push-to-talk app.
// Press a global hotkey, speak, and Gemini transcribes your voice to text.
//
// This file holds the only top-level executable code in the module (required to
// be in `main.swift` when compiling an executable directly with swiftc).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon; lives in the menu bar
app.run()
