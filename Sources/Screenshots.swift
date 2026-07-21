import AppKit
import UniformTypeIdentifiers

/// Captures an interactive screen-region selection (via the system
/// `screencapture -i` UI) and shows each shot as a draggable thumbnail floating
/// on the right edge of the screen.
final class ScreenshotController {
    private lazy var panel = ShotPanel()

    private let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("AIBuddyShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Runs the native crosshair selection; on completion adds a thumbnail.
    func captureInteractive() {
        let file = dir.appendingPathComponent("shot-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path] // -i interactive, -x no shutter sound
            do { try p.run(); p.waitUntilExit() } catch { return }
            // No file means the user pressed Esc to cancel — nothing to show.
            guard FileManager.default.fileExists(atPath: file.path),
                  let image = NSImage(contentsOf: file) else { return }
            DispatchQueue.main.async { self.panel.addShot(image: image, url: file) }
        }
    }
}

/// A borderless, always-on-top HUD pinned to the screen's right edge that stacks
/// screenshot thumbnails top-down. Sized tightly to its content so it doesn't
/// block clicks elsewhere.
final class ShotPanel: NSPanel {
    private let thumbWidth: CGFloat = 160
    private let spacing: CGFloat = 10
    private let margin: CGFloat = 16
    private var thumbs: [ThumbnailView] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = FlippedView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func addShot(image: NSImage, url: URL) {
        let height = thumbHeight(for: image)
        let thumb = ThumbnailView(image: image, url: url, width: thumbWidth, height: height)
        thumb.onClose = { [weak self] t in self?.remove(t) }
        thumbs.insert(thumb, at: 0) // newest on top
        contentView?.addSubview(thumb)
        relayout()
        orderFrontRegardless()
    }

    private func remove(_ thumb: ThumbnailView) {
        // Only take it off the screen — leave the PNG on disk so a dismissed shot
        // (or one already dragged out) isn't destroyed.
        thumb.removeFromSuperview()
        thumbs.removeAll { $0 === thumb }
        if thumbs.isEmpty { orderOut(nil) } else { relayout() }
    }

    private func thumbHeight(for image: NSImage) -> CGFloat {
        let s = image.size
        guard s.width > 0 else { return 110 }
        return min(220, max(60, thumbWidth * s.height / s.width))
    }

    private func relayout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let total = thumbs.reduce(0) { $0 + $1.frame.height } + spacing * CGFloat(max(0, thumbs.count - 1))
        let panelWidth = thumbWidth + 2
        let panelHeight = min(total, vf.height - 2 * margin)
        let originX = vf.maxX - panelWidth - margin
        let originY = vf.maxY - margin - panelHeight
        setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)

        var y: CGFloat = 0
        for t in thumbs {
            t.frame = NSRect(x: 1, y: y, width: thumbWidth, height: t.frame.height)
            y += t.frame.height + spacing
        }
    }
}

/// Top-left-origin container; passes clicks in empty areas through to apps below.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// The dismiss badge: a red disc with a white ring and a bold white ✕.
///
/// Drawn by hand rather than styled through `NSButton`'s layer. A button re-renders
/// its own backing layer from its cell, which silently discards a `backgroundColor`
/// / `borderColor` / `cornerRadius` set on that layer — leaving nothing but a white
/// glyph that disappears over a light screenshot.
final class CloseBadge: NSView {
    var onTap: (() -> Void)?
    private var pressed = false

    override func draw(_ dirtyRect: NSRect) {
        // Inset by the ring width so the stroke stays inside the frame.
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (pressed ? NSColor.systemRed.blended(withFraction: 0.25, of: .black) ?? .systemRed
                 : .systemRed).setFill()
        disc.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        disc.lineWidth = 2
        disc.stroke()

        let g = bounds.insetBy(dx: bounds.width * 0.33, dy: bounds.height * 0.33)
        let glyph = NSBezierPath()
        glyph.move(to: NSPoint(x: g.minX, y: g.minY))
        glyph.line(to: NSPoint(x: g.maxX, y: g.maxY))
        glyph.move(to: NSPoint(x: g.minX, y: g.maxY))
        glyph.line(to: NSPoint(x: g.maxX, y: g.minY))
        glyph.lineWidth = 2.5
        glyph.lineCapStyle = .round
        NSColor.white.setStroke()
        glyph.stroke()
    }

    // Handling the whole click here also keeps it away from the thumbnail's
    // click-to-copy and drag-out gestures.
    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A thumbnail you can drag into any app (drops the PNG file / image), click to
/// copy to the clipboard, or dismiss with the ✕ button.
final class ThumbnailView: NSView, NSDraggingSource {
    let url: URL
    private let image: NSImage
    var onClose: ((ThumbnailView) -> Void)?
    private var mouseDownPoint: NSPoint = .zero
    private var dragging = false

    init(image: NSImage, url: URL, width: CGFloat, height: CGFloat) {
        self.image = image
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true

        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)

        // A big, high-contrast dismiss button: a red disc with a bold white ✕ and a
        // white ring, so it reads clearly over any screenshot.
        let closeSize: CGFloat = 28
        let inset: CGFloat = 6
        let close = CloseBadge(frame: NSRect(x: width - closeSize - inset,
                                             y: height - closeSize - inset,
                                             width: closeSize, height: closeSize))
        close.onTap = { [weak self] in self?.closeTapped() }
        close.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(close)

        toolTip = "Drag into any app · click to copy · double-click to open · right-click for more · ✕ to dismiss"
    }
    required init?(coder: NSCoder) { nil }

    @objc private func closeTapped() { onClose?(self) }

    // MARK: Actions (shared by clicks and the right-click menu)

    @objc private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Opens the PNG in Preview specifically (falling back to the default handler).
    @objc private func openInPreview() {
        let config = NSWorkspace.OpenConfiguration()
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Saves a copy somewhere permanent — the capture itself lives in a temp dir
    /// that's cleaned up when the thumbnail is dismissed.
    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.lastPathComponent
        NSApp.activate(ignoringOtherApps: true) // agent app: bring the panel forward
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest) // the panel already confirmed overwrite
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    @objc private func dismiss() { onClose?(self) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("Open in Preview", #selector(openInPreview)),
            ("Copy Image",      #selector(copyToClipboard)),
            ("Save As…",        #selector(saveAs)),
            ("Show in Finder",  #selector(showInFinder)),
        ]
        for (title, action) in items {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let dismissMI = NSMenuItem(title: "Dismiss", action: #selector(dismiss), keyEquivalent: "")
        dismissMI.target = self
        menu.addItem(dismissMI)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let now = event.locationInWindow
        if hypot(now.x - mouseDownPoint.x, now.y - mouseDownPoint.y) > 6 {
            dragging = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(origin: .zero, size: bounds.size), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragging else { return }
        if event.clickCount >= 2 {
            // Double-click opens Preview; cancel the pending single-click copy so a
            // double-click doesn't also stomp the clipboard.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(copyToClipboard), object: nil)
            openInPreview()
        } else {
            // Defer the copy one double-click interval: if a second click lands it
            // becomes an open-in-Preview instead.
            perform(#selector(copyToClipboard), with: nil, afterDelay: NSEvent.doubleClickInterval)
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        // The shot landed somewhere (any accepted operation) — dismiss it. A drag
        // cancelled onto nothing reports an empty operation, so the thumbnail stays.
        if operation != [] { onClose?(self) }
    }
}
