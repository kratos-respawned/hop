import AppKit

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
    private let pages: [Page]
    private var shown: Page
    private var backStack: [Visit] = []
    private var results: [Item] = []
    private var rows: [ListRow] = []
    private var showsShortcuts = false

    private struct Visit {
        let page: Page
        let query: String
        let row: Int
    }

    private enum ListRow {
        case header(String)
        case item(Item)
    }
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
    private let previewCharacterLimit = 20_000
    private let previewScroll = NSTextView.scrollableTextView()
    private var previewText: NSTextView { previewScroll.documentView as! NSTextView }
    private let previewImage = NSImageView()
    private let previewDivider = NSBox()

    init(pages: [Page]) {
        self.pages = pages
        shown = pages[0]
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        buildPanel()
        drawOnceHidden()
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return handleShortcut(event) ? nil : event
        }
        NotificationCenter.default.addObserver(forName: .pageChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, panel.isVisible, note.object == nil || note.object as AnyObject? === shown else { return }
            refresh(selecting: max(table.selectedRow, 0))
        }
    }

    func toggle(_ page: Page) {
        if panel.isVisible && shown === page { return hide() }
        backStack = []
        show(page)
    }

    private var nextPage: Page {
        let index = pages.firstIndex { $0 === shown } ?? -1
        return pages[(index + 1) % pages.count]
    }

    private func show(_ page: Page, returningTo visit: Visit? = nil) {
        shown = page
        field.stringValue = visit?.query ?? ""
        field.placeholderString = page.placeholder
        switchHint.stringValue = nextPage.name
        refresh(selecting: visit?.row ?? 0)
        if panel.isVisible { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.maxY - frame.height * 0.2 - height))
        panel.alphaValue = 0
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
    }

    // The first open used to build layers, the blur and the text editor mid fade, which flashed for a frame.
    private func drawOnceHidden() {
        refresh()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        _ = panel.fieldEditor(true, for: field)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
    }

    private func hide() {
        backStack = []
        showsShortcuts = false
        panel.orderOut(nil)
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return hide() }
        show(previous.page, returningTo: previous)
    }

    private func open(_ page: Page) {
        if page === shown { return refresh(selecting: table.selectedRow) }
        guard let index = backStack.firstIndex(where: { $0.page === page }) else {
            backStack.append(Visit(page: shown, query: field.stringValue, row: table.selectedRow))
            return show(page)
        }
        let previous = backStack[index]
        backStack.removeSubrange(index...)
        show(page, returningTo: previous)
    }

    private func refresh(selecting row: Int = 0) {
        results = shown.search(query)
        header.stringValue = results.first?.section ?? shown.name
        rows = listRows(for: results)
        layoutList(withPreview: shown.hasPreview || results.first?.preview != nil)
        table.reloadData()
        emptyState.isHidden = !results.isEmpty
        resultCount.stringValue = "\(results.count) result\(results.count == 1 ? "" : "s")"
        select(min(row, rows.count - 1))
        showSelection()
    }

    private func listRows(for items: [Item]) -> [ListRow] {
        var rows: [ListRow] = [], section = items.first?.section
        for item in items {
            if let nextSection = item.section, nextSection != section {
                rows.append(.header(nextSection))
                section = nextSection
            }
            rows.append(.item(item))
        }
        return rows
    }

    private func item(at row: Int) -> Item? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item
    }

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    private func layoutList(withPreview: Bool) {
        let listWidth = withPreview ? listWidthWithPreview : width
        scroll.frame.size.width = listWidth
        table.sizeLastColumnToFit()
        header.frame.size.width = listWidth - 44
        emptyState.frame.size.width = listWidth
        previewDivider.isHidden = !withPreview
    }

    private func showSelection() {
        let row = table.selectedRow
        let item = item(at: row)
        let action = item?.action ?? ""
        actionHint.stringValue = action.isEmpty ? shown.actionName : action

        previewScroll.isHidden = true
        previewImage.isHidden = true
        switch item?.preview {
        case .text(let text):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                             .foregroundColor: NSColor.labelColor]
            showPreviewText(NSAttributedString(string: String(text.prefix(previewCharacterLimit)), attributes: attributes), inset: NSSize(width: 14, height: 14))
        case .rich(let text):
            showPreviewText(text, inset: NSSize(width: 18, height: 16))
        case .code(let text):
            showPreviewText(highlightedCode(String(text.prefix(previewCharacterLimit))), inset: NSSize(width: 16, height: 16))
        case .answer(let expression, let result):
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            let text = NSMutableAttributedString(string: expression + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered])
            text.append(NSAttributedString(string: result, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]))
            showPreviewText(text, inset: NSSize(width: 24, height: 135))
        case .image(let url):
            previewImage.image = nil
            previewImage.isHidden = false
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let image = thumbnail(of: url, maxPixels: 1000)
                DispatchQueue.main.async { [self] in
                    if case .image(let selected)? = self.item(at: table.selectedRow)?.preview, selected == url { previewImage.image = image }
                }
            }
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

    private func select(_ row: Int, direction: Int = 1) {
        var row = row
        while rows.indices.contains(row) && item(at: row) == nil { row += direction }
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        scrollInstantly(toShow: row)
        updateShortcuts()
    }

    private var groupStarts: [Int] { rows.indices.filter { item(at: $0) != nil && item(at: $0 - 1) == nil } }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let commandHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if event.type == .flagsChanged {
            showsShortcuts = commandHeld
            updateShortcuts()
            return false
        }
        guard commandHeld, let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number) else { return false }
        let numbered = shortcutRows()
        guard numbered.indices.contains(number - 1) else { return true }
        select(numbered[number - 1])
        runSelected()
        return true
    }

    private func shortcutRows() -> [Int] {
        let visible = scroll.contentView.documentVisibleRect
        let range = table.rows(in: visible)
        return Array((range.lowerBound..<range.upperBound).filter { row in
            let rect = table.rect(ofRow: row)
            return item(at: row) != nil && rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1
        }.prefix(9))
    }

    private func updateShortcuts() {
        let numbered = showsShortcuts ? shortcutRows() : []
        let range = table.rows(in: scroll.contentView.documentVisibleRect)
        for row in range.lowerBound..<range.upperBound {
            let number = numbered.firstIndex(of: row).map { $0 + 1 }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell)?.showShortcut(number)
        }
    }

    // Not scrollRowToVisible: its animation lags behind a held arrow key.
    private func scrollInstantly(toShow row: Int) {
        let visible = scroll.contentView
        var rowRect = table.rect(ofRow: row)
        if row > 0 && item(at: row - 1) == nil { rowRect = rowRect.union(table.rect(ofRow: row - 1)) }
        var top = visible.bounds.minY
        if rowRect.minY < top { top = rowRect.minY }
        if rowRect.maxY > top + visible.bounds.height { top = rowRect.maxY - visible.bounds.height }
        visible.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(visible)
    }

    @objc private func runSelected() {
        guard let item = item(at: table.selectedRow), item.opens != nil || item.run != nil else { return }
        shown.didSelect(item, query: query)
        if let page = item.opens {
            item.run?()
            open(page)
            return
        }
        hide()
        item.run?()
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1, direction: -1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            select(groupStarts.last { $0 < table.selectedRow } ?? groupStarts.first ?? 0)
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            select(groupStarts.first { $0 > table.selectedRow } ?? rows.count - 1, direction: -1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): goBack()
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && !backStack.isEmpty: goBack()
        case #selector(NSResponder.insertTab(_:)): toggle(nextPage)
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { item(at: row) == nil ? 30 : 44 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(at: row) != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let header = tableView.makeView(withIdentifier: SectionHeader.id, owner: nil) as? SectionHeader ?? SectionHeader()
            header.show(title)
            return header
        case .item(let item):
            let cell = tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell()
            cell.show(item)
            return cell
        }
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

