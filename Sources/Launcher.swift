import AppKit

struct Item {
    let title: String
    var subtitle = ""
    var badge = ""
    var action = ""
    var staysOpen = false
    var preview: Preview?
    var section: String?
    let icon: () -> NSImage?
    let run: () -> Void
}

enum Preview {
    case text(String)
    case image(URL)
    case calculation(expression: String, result: String)
}

protocol Source: AnyObject {
    var name: String { get }
    var icon: NSImage { get }
    var placeholder: String { get }
    var actionName: String { get }
    var hasPreview: Bool { get }
    func search(_ query: String) -> [Item]
}

extension Source {
    var hasPreview: Bool { false }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editing: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                           "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:))]
        if event.modifierFlags.contains(.command), let action = editing[event.charactersIgnoringModifiers ?? ""],
           firstResponder?.tryToPerform(action, with: self) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class Launcher: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let sources: [Source]
    private var current = 0
    private var openedFromSearch = false
    private var results: [Item] = []
    private let width: CGFloat = 750, height: CGFloat = 485
    private let searchHeight: CGFloat = 56, headerHeight: CGFloat = 30, footerHeight: CGFloat = 40
    private let panel: Panel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let header = label(12, .semibold, .secondaryLabelColor)
    private let emptyState = label(13, .regular, .tertiaryLabelColor)
    private let resultCount = label(12, .regular, .tertiaryLabelColor)
    private let actionHint = label(12, .medium, .secondaryLabelColor)
    private let switchHint = label(12, .medium, .secondaryLabelColor)
    private let listWidthWithPreview: CGFloat = 330
    private let previewScroll = NSTextView.scrollableTextView()
    private var previewText: NSTextView { previewScroll.documentView as! NSTextView }
    private let previewImage = NSImageView()
    private let previewDivider = NSBox()

    init(sources: [Source]) {
        self.sources = sources
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        buildPanel()
    }

    func toggle(_ index: Int) {
        if panel.isVisible && current == index { return hide() }
        current = index
        let source = sources[index]
        field.stringValue = ""
        field.placeholderString = source.placeholder
        switchHint.stringValue = sources[(index + 1) % sources.count].name
        refresh()
        if panel.isVisible { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.maxY - frame.height * 0.2 - height))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        openedFromSearch = false
        panel.orderOut(nil)
    }

    private func goBack() {
        if openedFromSearch { toggle(0) } else { hide() }
        openedFromSearch = false
    }

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        results = commands(matching: query) + sources[current].search(query)
        header.stringValue = results.first?.section ?? sources[current].name
        layoutList(withPreview: sources[current].hasPreview || results.first?.preview != nil)
        table.reloadData()
        emptyState.isHidden = !results.isEmpty
        resultCount.stringValue = "\(results.count) result\(results.count == 1 ? "" : "s")"
        select(0)
        showSelection()
    }

    private func layoutList(withPreview: Bool) {
        let listWidth = withPreview ? listWidthWithPreview : width
        scroll.frame.size.width = listWidth
        table.sizeLastColumnToFit()
        header.frame.size.width = listWidth - 44
        emptyState.frame.size.width = listWidth
        previewDivider.isHidden = !withPreview
    }

    private func commands(matching query: String) -> [Item] {
        guard current == 0 && query.count >= 2 else { return [] }
        let plugins = sources.indices.dropFirst().map { index in
            Item(title: sources[index].name, badge: "Command", action: "Open", staysOpen: true, section: "Commands",
                 icon: { [unowned self] in sources[index].icon },
                 run: { [unowned self] in
                     toggle(index)
                     openedFromSearch = true
                 })
        }
        let quit = Item(title: "Quit Hop", badge: "Command", action: "Quit", section: "Commands",
                        icon: { tile("power", .systemRed) },
                        run: { NSApp.terminate(nil) })
        // Above 600 means a prefix, word-start or initials match, so loose matches don't push commands over apps.
        return (plugins + [quit]).filter { (fuzzyScore(query, $0.title) ?? 0) > 600 }
    }

    private func showSelection() {
        let row = table.selectedRow
        let item = results.indices.contains(row) ? results[row] : nil
        let action = item?.action ?? ""
        actionHint.stringValue = action.isEmpty ? sources[current].actionName : action

        previewScroll.isHidden = true
        previewImage.isHidden = true
        switch item?.preview {
        case .text(let text):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                             .foregroundColor: NSColor.labelColor]
            // shortcut: shows the first 20k characters, enough for a glance; add paging if huge clips matter.
            showPreviewText(NSAttributedString(string: String(text.prefix(20_000)), attributes: attributes), inset: NSSize(width: 14, height: 14))
        case .calculation(let expression, let result):
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let text = NSMutableAttributedString(string: expression + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered])
            text.append(NSAttributedString(string: result, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]))
            showPreviewText(text, inset: NSSize(width: 24, height: 135))
        case .image(let url):
            previewImage.image = thumbnail(of: url, maxPixels: 1000)
            previewImage.isHidden = false
        case nil:
            break
        }
    }

    private func showPreviewText(_ text: NSAttributedString, inset: NSSize) {
        previewText.textContainerInset = inset
        previewText.textStorage?.setAttributedString(text)
        previewText.scroll(.zero)
        previewScroll.isHidden = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    private func select(_ row: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, row))
        table.selectRowIndexes([row], byExtendingSelection: false)
        let clip = scroll.contentView, rowRect = table.rect(ofRow: row)
        var top = clip.bounds.minY
        if rowRect.minY < top { top = rowRect.minY }
        if rowRect.maxY > top + clip.bounds.height { top = rowRect.maxY - clip.bounds.height }
        // Jump instead of scrollRowToVisible's animation, which lags behind key repeat.
        clip.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func runSelected() {
        guard results.indices.contains(table.selectedRow) else { return }
        let item = results[table.selectedRow]
        if !item.staysOpen { hide() }
        item.run()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): goBack()
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && openedFromSearch: goBack()
        case #selector(NSResponder.insertTab(_:)): toggle((current + 1) % sources.count)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell()
        cell.show(results[row])
        return cell
    }

    private func buildPanel() {
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let background = NSVisualEffectView(frame: bounds)
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        let mask = NSImage(size: NSSize(width: 32, height: 32), flipped: false) {
            NSBezierPath(roundedRect: $0, xRadius: 14, yRadius: 14).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        background.maskImage = mask
        panel.contentView = background

        let searchTop = height - searchHeight
        let searchIcon = NSImageView(frame: NSRect(x: 22, y: searchTop + 18, width: 20, height: 20))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        searchIcon.contentTintColor = .secondaryLabelColor

        field.frame = NSRect(x: 52, y: searchTop + 14, width: width - 72, height: 28)
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let listTop = searchTop - 1 - headerHeight
        header.frame = NSRect(x: 22, y: listTop + 8, width: width - 44, height: 16)

        let column = NSTableColumn(identifier: Cell.id)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)

        scroll.frame = NSRect(x: 0, y: footerHeight + 6, width: width, height: listTop - footerHeight - 6)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = table
        table.sizeLastColumnToFit()

        emptyState.stringValue = "No results"
        emptyState.alignment = .center
        emptyState.frame = NSRect(x: 0, y: scroll.frame.midY - 8, width: width, height: 18)

        let footer = Decoration(frame: NSRect(x: 0, y: 0, width: width, height: footerHeight),
                                fill: NSColor.black.withAlphaComponent(0.18))
        resultCount.frame = NSRect(x: 22, y: 12, width: 200, height: 16)
        let hints = NSStackView(views: [actionHint, Pill("↵"), divider(), switchHint, Pill("Tab")])
        hints.spacing = 6
        hints.setCustomSpacing(10, after: hints.views[1])
        hints.setCustomSpacing(10, after: hints.views[2])
        hints.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hints)
        NSLayoutConstraint.activate([
            hints.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            hints.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        let separators = [searchTop - 1, footerHeight].map { y -> NSBox in
            let line = NSBox(frame: NSRect(x: 0, y: y, width: width, height: 1))
            line.boxType = .separator
            return line
        }
        let outline = Decoration(frame: bounds, border: NSColor.white.withAlphaComponent(0.12), radius: 14)

        let previewFrame = NSRect(x: listWidthWithPreview + 1, y: footerHeight, width: width - listWidthWithPreview - 1,
                                  height: searchTop - 1 - footerHeight)
        previewDivider.boxType = .separator
        previewDivider.frame = NSRect(x: listWidthWithPreview, y: footerHeight, width: 1, height: previewFrame.height)
        previewScroll.frame = previewFrame
        previewScroll.drawsBackground = false
        previewScroll.scrollerStyle = .overlay
        previewText.isEditable = false
        previewText.isSelectable = false
        previewText.drawsBackground = false
        previewText.textContainerInset = NSSize(width: 14, height: 14)
        previewImage.frame = previewFrame.insetBy(dx: 20, dy: 20)
        previewImage.imageScaling = .scaleProportionallyDown

        let tint = Decoration(frame: bounds, fill: NSColor(white: 0.08, alpha: 0.55))
        [tint, searchIcon, field, header, scroll, emptyState, previewDivider, previewScroll, previewImage, footer, resultCount, outline]
            .forEach(background.addSubview)
        separators.forEach(background.addSubview)
    }

    private func divider() -> NSView {
        let line = Decoration(frame: .zero, fill: NSColor.white.withAlphaComponent(0.15))
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }
}

private var tiles: [String: NSImage] = [:]

// macOS app icons fill about 80% of their square, so tiles and thumbnails keep the same margin to sit level with them.
private let iconBox = NSRect(x: 0, y: 0, width: 26, height: 26).insetBy(dx: 2.5, dy: 2.5)

func tile(_ symbol: String, _ color: NSColor) -> NSImage {
    if let cached = tiles[symbol] { return cached }
    let image = NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
        let shape = NSBezierPath(roundedRect: iconBox, xRadius: 5, yRadius: 5)
        NSGradient(starting: color.blended(withFraction: 0.3, of: .white) ?? color, ending: color)?.draw(in: shape, angle: -90)
        let style = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(style) {
            glyph.draw(in: NSRect(x: iconBox.midX - glyph.size.width / 2, y: iconBox.midY - glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
        }
        return true
    }
    tiles[symbol] = image
    return image
}

func framed(_ picture: NSImage) -> NSImage {
    NSImage(size: NSSize(width: 26, height: 26), flipped: false) { _ in
        NSBezierPath(roundedRect: iconBox, xRadius: 5, yRadius: 5).addClip()
        let scale = max(iconBox.width / picture.size.width, iconBox.height / picture.size.height)
        let size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
        picture.draw(in: NSRect(x: iconBox.midX - size.width / 2, y: iconBox.midY - size.height / 2, width: size.width, height: size.height))
        return true
    }
}

private func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

final class Decoration: NSView {
    init(frame: NSRect, fill: NSColor = .clear, border: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = border == .clear ? 0 : 1
        layer?.cornerRadius = radius
        translatesAutoresizingMaskIntoConstraints = frame == .zero ? false : true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class Pill: NSView {
    let text = label(11, .medium, .secondaryLabelColor)

    init(_ string: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        text.stringValue = string
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class Row: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

final class Cell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    private let icon = NSImageView()
    private let title = label(14, .medium)
    private let subtitle = label(13, .regular, .secondaryLabelColor)
    private let badge = Pill("")

    init() {
        super.init(frame: .zero)
        identifier = Cell.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        subtitle.setContentHuggingPriority(.init(1), for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let row = NSStackView(views: [icon, title, subtitle, badge])
        row.distribution = .fill
        row.spacing = 12
        row.setCustomSpacing(8, after: title)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: Item) {
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle
        badge.text.stringValue = item.badge
        badge.isHidden = item.badge.isEmpty
        icon.image = item.icon()
    }
}
