import AppKit

final class NotchIsland: NSPanel {
    private enum Shape { case hidden, waiting, targeted, peek, open }

    private let canvas = NSSize(width: 420, height: 160)
    // A cursor pinned to the top of the screen sits exactly on the screen edge, which a rect treats as outside.
    private let aboveScreen: CGFloat = 4
    private let island: IslandView
    private let blob = CAShapeLayer()
    private let vortex = Vortex(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private let dropTitle = label(15, .semibold, .white)
    private let dropSubtitle = label(11, .regular, .secondaryLabelColor)
    private let smallFan = NSImageView()
    private let countLabel = label(13, .semibold, .white)
    private let bigFan = NSImageView()
    private let filesTitle = label(15, .semibold, .white)
    private let filesSubtitle = label(11, .regular, .secondaryLabelColor)
    private let sendButton = NSButton(title: "", target: nil, action: nil)
    private let sendCaption = label(10, .medium, .secondaryLabelColor)
    private var notch = NSSize(width: 0, height: 32)
    private var shape = Shape.hidden
    private var mouseWatcher: Any?
    private var hoverArea: NSTrackingArea?
    private var opensOnHover = true
    private var openedAt = Date.distantPast
    private unowned let plugin: ShelfPlugin

    var isWaitingForDrop: Bool { shape == .waiting || shape == .targeted }

    init(plugin: ShelfPlugin) {
        self.plugin = plugin
        island = IslandView(frame: NSRect(origin: .zero, size: canvas))
        super.init(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = island
        island.island = self
        buildContents()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func prepare() {
        moveToScreen(NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main)
        ignoresMouseEvents = true
        alphaValue = 0
        orderFrontRegardless()
    }

    func dragStarted() {
        moveToScreenUnderMouse()
        go(.waiting)
    }

    func dragEnded() {
        if isWaitingForDrop { go(plugin.count > 0 ? .peek : .hidden) }
    }

    func showFiles() {
        if shape == .hidden { moveToScreenUnderMouse() }
        go(.open)
    }

    func update(_ files: [URL]) {
        let count = files.count
        countLabel.stringValue = "\(count)"
        filesTitle.stringValue = count == 1 ? files[0].lastPathComponent : "\(count) files"
        filesSubtitle.stringValue = count == 1 ? "Manage it in Hop" : "Manage them in Hop"
        dropSubtitle.stringValue = count == 0 ? "AirDrop them all at once later" : "\(count) on the shelf, AirDrop all at once"
        if count == 0 && !isWaitingForDrop { go(.hidden) }
        let paths = files.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fan = paths.isEmpty ? nil : fanOfIcons(paths)
            DispatchQueue.main.async {
                self?.smallFan.image = fan
                self?.bigFan.image = fan
            }
        }
    }

    fileprivate func accepts(_ point: NSPoint) -> Bool { hoverRect().contains(point) }

    private func hoverRect() -> NSRect {
        let rect = blobRect(for: shape)
        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + aboveScreen)
    }

    fileprivate func dragEntered() {
        guard shape != .targeted else { return }
        go(.targeted)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    fileprivate func dragExited() {
        if shape == .targeted { go(.waiting) }
    }

    fileprivate func dropped(_ urls: [URL]) {
        plugin.add(urls)
        opensOnHover = false
        vortex.gulp()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in go(.peek) }
    }

    // The window is bigger than the island, so it ignores the mouse until the cursor is over the island.
    // Outside, a global monitor sees every move; inside, a tracking area reports the exit.
    private func watchMouse(_ on: Bool) {
        if on, mouseWatcher == nil {
            mouseWatcher = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.mouseMovedOutside() }
        } else if !on {
            mouseWatcher.map(NSEvent.removeMonitor)
            mouseWatcher = nil
            stopTrackingHover()
        }
    }

    private func mouseMovedOutside() {
        guard hoverRect().contains(mouseLocationOutsideOfEventStream) else {
            opensOnHover = true
            return
        }
        guard hoverArea == nil else { return }
        ignoresMouseEvents = false
        trackHover()
        if shape == .peek && opensOnHover { go(.open) }
    }

    private func trackHover() {
        if let hoverArea { island.removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: hoverRect(), options: [.mouseEnteredAndExited, .activeAlways, .assumeInside], owner: island)
        island.addTrackingArea(hoverArea!)
    }

    private func stopTrackingHover() {
        if let hoverArea { island.removeTrackingArea(hoverArea) }
        hoverArea = nil
    }

    fileprivate func mouseLeftIsland() {
        guard hoverArea != nil else { return }
        stopTrackingHover()
        ignoresMouseEvents = !isWaitingForDrop
        opensOnHover = true
        guard shape == .open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if shape == .open && hoverArea == nil { go(.peek) }
        }
    }

    // A click that lands as the island opens under the cursor is not a request to send.
    @objc private func send() {
        if Date().timeIntervalSince(openedAt) > 0.5 { plugin.airDrop() }
    }

    func tuck() { go(.hidden) }

    private func moveToScreenUnderMouse() {
        let mouse = NSEvent.mouseLocation
        moveToScreen(NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
    }

    private func moveToScreen(_ screen: NSScreen?) {
        guard let screen else { return }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let hasNotch = screen.safeAreaInsets.top > 0 && left > 0
        notch = hasNotch ? NSSize(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top) : NSSize(width: 0, height: 32)
        let centerX = hasNotch ? screen.frame.minX + left + notch.width / 2 : screen.frame.midX
        let frame = NSRect(x: centerX - canvas.width / 2, y: screen.frame.maxY + aboveScreen - canvas.height, width: canvas.width, height: canvas.height)
        guard frame != self.frame || blob.path == nil else { return }
        setFrame(frame, display: false)
        layoutContents()
        if shape == .hidden { setOutline(for: .hidden) }
    }

    private func blobRect(for shape: Shape) -> NSRect {
        let top = notch.height
        let size: NSSize
        switch shape {
        case .hidden: size = notch.width > 0 ? NSSize(width: notch.width - 6, height: top - 2) : NSSize(width: 80, height: 0)
        case .peek: size = NSSize(width: max(notch.width, 60) + 96, height: top)
        case .waiting, .open: size = NSSize(width: 360, height: top + 92)
        case .targeted: size = NSSize(width: 392, height: top + 108)
        }
        return NSRect(x: (canvas.width - size.width) / 2, y: canvas.height - aboveScreen - size.height, width: size.width, height: size.height)
    }

    private func go(_ next: Shape) {
        guard next != shape else { return }
        let before = blobRect(for: shape)
        let rect = blobRect(for: next)
        let isGrowing = rect.width * rect.height > before.width * before.height
        shape = next
        alphaValue = 1
        orderFrontRegardless()
        let settles = springOutline(to: next, bouncy: isGrowing)
        if next == .hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + settles) { [self] in if shape == .hidden { alphaValue = 0 } }
        }
        vortex.isHot = next == .targeted
        if isWaitingForDrop { vortex.isSpinning = true }
        let showing = contents(of: next)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            for view in contents(of: .waiting) + contents(of: .peek) + contents(of: .open) where !showing.contains(view) {
                view.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (isGrowing ? 0.08 : 0.16)) { [self] in
            guard shape == next else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                showing.forEach { $0.animator().alphaValue = 1 }
            }
        }
        if !isWaitingForDrop { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in vortex.isSpinning = isWaitingForDrop } }
        dropTitle.stringValue = next == .targeted ? "Release to shelve" : "Drop to shelve"
        watchMouse(next == .peek || next == .open)
        if hoverArea != nil { trackHover() }
        ignoresMouseEvents = !isWaitingForDrop && hoverArea == nil
        if next == .open { openedAt = Date() }
    }

    private func contents(of shape: Shape) -> [NSView] {
        switch shape {
        case .hidden: return []
        case .waiting, .targeted: return [vortex, dropTitle, dropSubtitle]
        case .peek: return [smallFan, countLabel]
        case .open: return [bigFan, filesTitle, filesSubtitle, sendButton, sendCaption]
        }
    }

    private func springOutline(to shape: Shape, bouncy: Bool) -> TimeInterval {
        let target = outline(for: shape)
        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = blob.presentation()?.path ?? blob.path
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = bouncy ? 260 : 520
        spring.damping = bouncy ? 22 : 2 * sqrt(520)
        spring.duration = spring.settlingDuration
        blob.add(spring, forKey: "path")
        setOutline(for: shape)
        return spring.duration
    }

    private func setOutline(for shape: Shape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.path = outline(for: shape)
        CATransaction.commit()
    }

    // Same commands for every shape, so Core Animation can morph one outline into another.
    private func outline(for shape: Shape) -> CGPath {
        let rect = blobRect(for: shape)
        let ear: CGFloat = shape == .hidden ? 0 : 7
        let radius = max(0, min(shape == .peek || shape == .hidden ? 10 : 24, rect.height - ear))
        let (left, right, top, bottom) = (rect.minX, rect.maxX, rect.maxY, rect.minY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left - ear, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: top - ear), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: top - ear))
        path.addQuadCurve(to: CGPoint(x: right + ear, y: top), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }

    private func buildContents() {
        island.wantsLayer = true
        island.layer?.backgroundColor = NSColor.black.cgColor
        blob.frame = NSRect(origin: .zero, size: canvas)
        blob.fillColor = NSColor.black.cgColor
        island.layer?.mask = blob
        dropTitle.stringValue = "Drop to shelve"
        dropSubtitle.stringValue = "AirDrop them all at once later"
        smallFan.imageScaling = .scaleProportionallyUpOrDown
        bigFan.imageScaling = .scaleProportionallyUpOrDown
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        sendButton.layer?.cornerRadius = 22
        sendButton.image = NSImage(systemSymbolName: "dot.radiowaves.up.forward", accessibilityDescription: "AirDrop")?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        sendButton.contentTintColor = .white
        sendButton.imagePosition = .imageOnly
        sendButton.toolTip = "AirDrop everything on the shelf"
        sendCaption.stringValue = "AirDrop"
        sendCaption.alignment = .center
        sendButton.target = self
        sendButton.action = #selector(send)
        filesTitle.lineBreakMode = .byTruncatingMiddle
        let all: [NSView] = [vortex, dropTitle, dropSubtitle, smallFan, countLabel, bigFan, filesTitle, filesSubtitle, sendButton, sendCaption]
        all.forEach { $0.alphaValue = 0; island.addSubview($0) }
        layoutContents()
        setOutline(for: .hidden)
    }

    private func layoutContents() {
        let middle = canvas.width / 2
        let below = canvas.height - aboveScreen - notch.height
        vortex.frame.origin = NSPoint(x: middle - 156, y: below - 80)
        dropTitle.frame = NSRect(x: middle - 76, y: below - 44, width: 230, height: 20)
        dropSubtitle.frame = NSRect(x: middle - 76, y: below - 64, width: 230, height: 16)
        let side = max(notch.width, 60) / 2
        smallFan.frame = NSRect(x: middle - side - 40, y: below + (notch.height - 22) / 2, width: 22, height: 22)
        countLabel.frame = NSRect(x: middle + side + 12, y: below + (notch.height - 18) / 2, width: 30, height: 18)
        bigFan.frame = NSRect(x: middle - 160, y: below - 80, width: 64, height: 64)
        filesTitle.frame = NSRect(x: middle - 84, y: below - 44, width: 178, height: 20)
        filesSubtitle.frame = NSRect(x: middle - 84, y: below - 64, width: 160, height: 16)
        sendButton.frame = NSRect(x: middle + 108, y: below - 66, width: 44, height: 44)
        sendCaption.frame = NSRect(x: middle + 100, y: below - 82, width: 60, height: 13)
    }
}

private final class IslandView: NSView {
    weak var island: NotchIsland?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseExited(with event: NSEvent) { island?.mouseLeftIsland() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let island, island.accepts(sender.draggingLocation) else {
            island?.dragExited()
            return []
        }
        island.dragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { island?.dragExited() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard island?.accepts(sender.draggingLocation) == true else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        island?.dropped(urls)
        return true
    }
}

private final class Vortex: NSView {
    private let swirl = CALayer()
    private let rings: [CAShapeLayer] = (0..<3).map { _ in CAShapeLayer() }
    private let colors: [NSColor] = [.systemBlue, .systemCyan, .systemTeal]

    var isHot = false {
        didSet {
            guard isHot != oldValue else { return }
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = swirl.presentation()?.value(forKeyPath: "transform.scale") ?? 1
            grow.toValue = isHot ? 1.18 : 1
            grow.stiffness = 300
            grow.damping = 12
            grow.duration = grow.settlingDuration
            swirl.add(grow, forKey: "grow")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            swirl.setValue(isHot ? 1.18 : 1, forKeyPath: "transform.scale")
            CATransaction.commit()
            for (index, ring) in rings.enumerated() {
                ring.strokeColor = colors[index].withAlphaComponent(isHot ? 1 : 0.75).cgColor
                ring.lineWidth = isHot ? 4 : 3
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swirl.frame = bounds
        layer?.addSublayer(swirl)
        let center = NSPoint(x: frame.width / 2, y: frame.height / 2)
        for (index, ring) in rings.enumerated() {
            let radius = CGFloat(28 - index * 8)
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 1.4, clockwise: false)
            ring.path = path
            ring.frame = bounds
            ring.fillColor = nil
            ring.strokeColor = colors[index].withAlphaComponent(0.75).cgColor
            ring.lineWidth = 3
            ring.lineCap = .round
            swirl.addSublayer(ring)
        }
        let arrow = CALayer()
        arrow.frame = NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
        arrow.contents = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white])))
        arrow.contentsGravity = .resizeAspect
        swirl.addSublayer(arrow)
    }

    required init?(coder: NSCoder) { fatalError() }

    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            for (index, ring) in rings.enumerated() {
                guard isSpinning else { ring.removeAnimation(forKey: "spin"); continue }
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = [1.6, 1.15, 0.8][index]
                spin.repeatCount = .infinity
                ring.add(spin, forKey: "spin")
            }
        }
    }

    func gulp() {
        let gulp = CAKeyframeAnimation(keyPath: "transform.scale")
        gulp.values = [1.18, 0.55, 1.1, 1]
        gulp.keyTimes = [0, 0.35, 0.75, 1]
        gulp.duration = 0.4
        swirl.add(gulp, forKey: "gulp")
    }
}

func fanOfIcons(_ paths: [String]) -> NSImage {
    let side = 128
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let icons = paths.suffix(3).map { NSWorkspace.shared.icon(forFile: $0) }
    for (index, icon) in icons.enumerated() {
        let side: CGFloat = index == icons.count - 1 ? 0 : index == 0 ? 1 : -1
        let turn = NSAffineTransform()
        turn.translateX(by: 64 - side * 22, yBy: 60)
        turn.rotate(byDegrees: side * 14)
        turn.concat()
        icon.draw(in: NSRect(x: -40, y: -40, width: 80, height: 80))
        turn.invert()
        turn.concat()
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.addRepresentation(bitmap)
    return image
}
