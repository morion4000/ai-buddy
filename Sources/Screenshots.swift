import AppKit

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
        thumb.removeFromSuperview()
        thumbs.removeAll { $0 === thumb }
        try? FileManager.default.removeItem(at: thumb.url)
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
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true

        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        addSubview(iv)

        let close = NSButton(frame: NSRect(x: width - 20, y: height - 20, width: 18, height: 18))
        close.bezelStyle = .circular
        close.title = "✕"
        close.font = .systemFont(ofSize: 9)
        close.target = self
        close.action = #selector(closeTapped)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(close)

        toolTip = "Drag me into any app · click to copy · ✕ to dismiss"
    }
    required init?(coder: NSCoder) { nil }

    @objc private func closeTapped() { onClose?(self) }

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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image]) // click = copy to clipboard
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
