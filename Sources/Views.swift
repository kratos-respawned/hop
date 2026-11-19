import AppKit

func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
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
    private let shortcut = label(12, .medium, .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Cell.id
        shortcut.isHidden = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        title.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        subtitle.setContentHuggingPriority(.init(1), for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let row = NSStackView(views: [icon, title, subtitle, badge, shortcut])
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
        showShortcut(nil)
    }

    func showShortcut(_ number: Int?) {
        shortcut.stringValue = number.map { "⌘\($0)" } ?? ""
        shortcut.isHidden = number == nil
    }
}

final class SectionHeader: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("section")
    private let title = label(12, .semibold, .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = SectionHeader.id
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        title.stringValue = text
    }
}
