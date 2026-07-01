import AppKit
import CoreGraphics

/// Inserts transcribed text into whatever app is focused.
///
/// Primary path = set the pasteboard and synthesize ⌘V (reliable for large/Unicode
/// text, layout-independent), saving & restoring the user's clipboard around it.
/// Fallback path = type the characters directly via CGEvent Unicode strings, for
/// the minority of apps that don't bind ⌘V to paste.
///
/// Both require the Accessibility permission (to post synthetic events).
enum TextInjector {
    static func deliver(_ text: String, typeInstead: Bool) {
        if typeInstead { typeUnicode(text) } else { paste(text) }
    }

    // MARK: Paste

    static func paste(_ text: String) {
        let saved = snapshot()
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Mark transient so well-behaved clipboard managers skip the temporary value.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { restore(saved) }
        }
    }

    private static func snapshot() -> [NSPasteboardItem] {
        var copy: [NSPasteboardItem] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            let dup = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { dup.setData(data, forType: type) }
            }
            copy.append(dup)
        }
        return copy
    }

    private static func restore(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Keep the user's physically-held modifiers from corrupting our synthetic flags.
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    // MARK: Type (fallback)

    /// Serial so streamed deltas type out in the order they were requested (each
    /// `typeUnicode` call just enqueues; the queue drains one chunk at a time).
    private static let typeQueue = DispatchQueue(label: "com.morion4000.aibuddy.typing")

    static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let chunks = utf16Chunks(text)
        typeQueue.async {
            for var chunk in chunks {
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down?.post(tap: .cgSessionEventTap)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up?.post(tap: .cgSessionEventTap)
                usleep(5_000) // ~5ms between chunks so no characters drop
            }
        }
    }

    /// Splits text into <= 20 UTF-16 code units per event (a hard CGEvent limit),
    /// never splitting a grapheme/surrogate pair.
    private static func utf16Chunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for ch in text {
            let units = Array(String(ch).utf16)
            if current.count + units.count > 20 { chunks.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
