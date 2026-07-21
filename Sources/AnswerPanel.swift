import AppKit

/// A small floating utility window that shows Gemini's answer to a spoken
/// question about a screenshot, docked just left of the thumbnail stack so the
/// shot and its answer read side by side. Text is selectable; the window stays
/// until closed and never steals focus from the app the user is working in.
final class AnswerPanel: NSPanel {
    private let textView = NSTextView()
    private let answerFont = NSFont.systemFont(ofSize: 13)
    private let panelWidth: CGFloat = 360
    private let margin: CGFloat = 16

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Gemini"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces]

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = answerFont
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        contentView = scroll
    }

    /// Shows `answer`, sized to fit the text (capped at half the screen), next
    /// to the thumbnail stack (`anchor`, screen coordinates) or at the screen's
    /// right edge when no thumbnails are up.
    func show(_ answer: String, nextTo anchor: NSRect?) {
        textView.string = answer

        guard let screen = NSScreen.main else { orderFrontRegardless(); return }
        let vf = screen.visibleFrame

        let inset = textView.textContainerInset
        // Leave room for the container's line-fragment padding and the scroller.
        let textWidth = panelWidth - 2 * inset.width - 24
        let bound = (answer as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: answerFont])
        let chrome = frame.height - (contentView?.frame.height ?? 0) // title bar
        let height = min(max(ceil(bound.height) + 2 * inset.height + chrome, 80),
                         vf.height * 0.5)

        let x = (anchor.map { $0.minX - 10 } ?? vf.maxX - margin) - panelWidth
        let top = anchor?.maxY ?? vf.maxY - margin
        setFrame(NSRect(x: max(vf.minX + margin, x),
                        y: max(vf.minY + margin, top - height),
                        width: panelWidth, height: height),
                 display: true)
        textView.scrollToBeginningOfDocument(nil)
        orderFrontRegardless()
    }
}
