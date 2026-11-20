import AppKit

enum DigestCard {
    static let width: CGFloat = 370

    static func header(title: String, subreddit: String, symbol: String, color: NSColor, upvotes: Int, comments: Int, buzz: Int) -> NSImage {
        let titleFont = NSFont.systemFont(ofSize: 17, weight: .bold)
        let titleHeight = ceil(height(of: title, font: titleFont, width: width - 36))
        return NSImage(size: NSSize(width: width, height: titleHeight + 92), flipped: true) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            NSGradient(starting: color, ending: color.blended(withFraction: 0.45, of: .black) ?? color)?.draw(in: shape, angle: 90)
            shape.addClip()
            draw(symbol, size: 74, color: .white.withAlphaComponent(0.16), at: NSPoint(x: rect.maxX - 92, y: 4))
            chip("r/\(subreddit)", at: NSPoint(x: 16, y: 14))
            (title as NSString).draw(with: NSRect(x: 18, y: 44, width: width - 36, height: titleHeight), options: .usesLineFragmentOrigin,
                                     attributes: [.font: titleFont, .foregroundColor: NSColor.white])
            let statsY = rect.maxY - 30
            var x: CGFloat = 18
            for (glyph, number) in [("arrow.up", upvotes), ("bubble.left", comments)] {
                draw(glyph, size: 11, color: .white.withAlphaComponent(0.85), at: NSPoint(x: x, y: statsY + 2))
                let text = number.formatted() as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
                text.draw(at: NSPoint(x: x + 17, y: statsY), withAttributes: attributes)
                x += 17 + text.size(withAttributes: attributes).width + 16
            }
            ("Buzz" as NSString).draw(at: NSPoint(x: rect.maxX - 104, y: statsY), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
            for dot in 0..<5 {
                NSColor.white.withAlphaComponent(dot < buzz ? 0.95 : 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 70 + CGFloat(dot) * 11, y: statsY + 4, width: 7, height: 7)).fill()
            }
            return true
        }
    }

    static func visual(kind: String, title: String, left: String, right: String, items: [(label: String, number: Double, side: String)], color: NSColor) -> NSImage? {
        guard !items.isEmpty || kind == "quote" else { return nil }
        switch kind {
        case "bars": return bars(title, items.prefix(5).map { ($0.label, $0.number) }, color: color)
        case "steps": return steps(title, items.prefix(5).map(\.label), color: color)
        case "versus": return versus(left: left, right: right, items.map { ($0.label, $0.side) }, color: color)
        case "quote": return quote(title, by: left, color: color)
        default: return nil
        }
    }

    private static let inner = width - 28
    private static let small = NSFont.systemFont(ofSize: 12)
    private static let heading = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private static func panel(height: CGFloat, title: String, draw body: @escaping (_ top: CGFloat) -> Void) -> NSImage {
        let top: CGFloat = title.isEmpty ? 14 : 38
        return NSImage(size: NSSize(width: width, height: top + height + 14), flipped: true) { rect in
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            line(title.uppercased(), in: NSRect(x: 14, y: 14, width: inner, height: 16), font: .systemFont(ofSize: 10.5, weight: .bold), color: .secondaryLabelColor)
            body(top)
            return true
        }
    }

    private static func bars(_ title: String, _ items: [(label: String, number: Double)], color: NSColor) -> NSImage {
        let largest = max(items.map { abs($0.number) }.max() ?? 1, 0.0001)
        return panel(height: CGFloat(items.count) * 26 - 6, title: title) { top in
            for (index, item) in items.enumerated() {
                let y = top + CGFloat(index) * 26
                line(item.label, in: NSRect(x: 14, y: y + 2, width: 104, height: 16), font: small, color: .labelColor)
                let track = NSRect(x: 124, y: y + 3, width: inner - 110 - 58, height: 14)
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(track.width * abs(item.number) / largest, 4), height: track.height),
                             xRadius: 4, yRadius: 4).fill()
                line(item.number.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))),
                     in: NSRect(x: track.maxX + 8, y: y + 1, width: 50, height: 18), font: .systemFont(ofSize: 12, weight: .bold), color: .labelColor)
            }
        }
    }

    private static func steps(_ title: String, _ items: [String], color: NSColor) -> NSImage {
        let heights = items.map { max(ceil(height(of: $0, font: small, width: inner - 32)), 20) }
        return panel(height: heights.reduce(0, +) + CGFloat(items.count - 1) * 10, title: title) { top in
            var y = top
            for (index, item) in items.enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: y, width: 20, height: 20)).fill()
                let number = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
                let size = number.size(withAttributes: attributes)
                number.draw(at: NSPoint(x: 24 - size.width / 2, y: y + 10 - size.height / 2), withAttributes: attributes)
                (item as NSString).draw(with: NSRect(x: 46, y: y + 2, width: inner - 32, height: heights[index]), options: .usesLineFragmentOrigin,
                                        attributes: [.font: small, .foregroundColor: NSColor.labelColor])
                y += heights[index] + 10
            }
        }
    }

    private static func versus(left: String, right: String, _ items: [(label: String, side: String)], color: NSColor) -> NSImage {
        let column = (inner - 10) / 2
        let sides = [(left, items.filter { $0.side != "right" }.map(\.label), color), (right, items.filter { $0.side == "right" }.map(\.label), NSColor.systemGray)]
        let heights = sides.map { side in side.1.map { ceil(height(of: $0, font: small, width: column - 30)) + 6 }.reduce(24, +) }
        return panel(height: (heights.max() ?? 0) + 8, title: "") { top in
            for (index, side) in sides.enumerated() {
                let x = 14 + CGFloat(index) * (column + 10)
                side.2.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: top, width: column, height: heights[index] + 8), xRadius: 8, yRadius: 8).fill()
                line(side.0, in: NSRect(x: x + 10, y: top + 8, width: column - 20, height: 16), font: heading, color: side.2 == color ? color : .secondaryLabelColor)
                var y = top + 30
                for item in side.1 {
                    let itemHeight = ceil(height(of: item, font: small, width: column - 30))
                    side.2.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x + 10, y: y + 5, width: 5, height: 5)).fill()
                    (item as NSString).draw(with: NSRect(x: x + 20, y: y, width: column - 30, height: itemHeight), options: .usesLineFragmentOrigin,
                                            attributes: [.font: small, .foregroundColor: NSColor.labelColor])
                    y += itemHeight + 6
                }
            }
        }
    }

    private static func quote(_ text: String, by author: String, color: NSColor) -> NSImage {
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14, weight: .medium), toHaveTrait: .italicFontMask)
        let textHeight = ceil(height(of: text, font: font, width: inner - 34))
        return panel(height: textHeight + (author.isEmpty ? 0 : 22), title: "") { top in
            draw("quote.opening", size: 18, color: color, at: NSPoint(x: 14, y: top))
            (text as NSString).draw(with: NSRect(x: 48, y: top, width: inner - 34, height: textHeight), options: .usesLineFragmentOrigin,
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            line(author, in: NSRect(x: 48, y: top + textHeight + 6, width: inner - 34, height: 16), font: small, color: .secondaryLabelColor)
        }
    }

    static func figures(_ figures: [(label: String, value: String, change: String)]) -> NSImage {
        let columns = min(figures.count, 3), gap: CGFloat = 8, tileHeight: CGFloat = 64
        let rows = Int((Double(figures.count) / 3).rounded(.up))
        let tileWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(max(columns, 1))
        return NSImage(size: NSSize(width: width, height: CGFloat(rows) * (tileHeight + gap) - gap), flipped: true) { _ in
            for (index, figure) in figures.enumerated() {
                let tile = NSRect(x: CGFloat(index % 3) * (tileWidth + gap), y: CGFloat(index / 3) * (tileHeight + gap), width: tileWidth, height: tileHeight)
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill()
                let trend: (String, NSColor)? = ["up": ("arrow.up.right", .systemGreen), "down": ("arrow.down.right", .systemRed)][figure.change]
                if let trend { draw(trend.0, size: 11, color: trend.1, at: NSPoint(x: tile.maxX - 22, y: tile.minY + 11)) }
                line(figure.label, in: NSRect(x: tile.minX + 11, y: tile.minY + 9, width: tile.width - 36, height: 16),
                     font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
                line(figure.value, in: NSRect(x: tile.minX + 11, y: tile.minY + 29, width: tile.width - 20, height: 26),
                     font: .systemFont(ofSize: 19, weight: .bold), color: trend?.1 ?? .labelColor)
            }
            return true
        }
    }

    static func callout(_ text: String, symbol: String, color: NSColor) -> NSImage {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textHeight = ceil(height(of: text, font: font, width: width - 52))
        return NSImage(size: NSSize(width: width, height: textHeight + 22), flipped: true) { rect in
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 4, height: rect.height), xRadius: 2, yRadius: 2).fill()
            draw(symbol, size: 13, color: color, at: NSPoint(x: 14, y: 12))
            (text as NSString).draw(with: NSRect(x: 38, y: 11, width: width - 52, height: textHeight), options: .usesLineFragmentOrigin,
                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
    }

    static func split(_ sections: [(name: String, count: Int, color: NSColor)]) -> NSImage {
        let total = CGFloat(max(sections.map(\.count).reduce(0, +), 1))
        return NSImage(size: NSSize(width: width, height: 40), flipped: true) { _ in
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: 10), xRadius: 5, yRadius: 5).addClip()
            var x: CGFloat = 0
            for section in sections {
                section.color.setFill()
                NSRect(x: x, y: 0, width: width * CGFloat(section.count) / total, height: 10).fill()
                x += width * CGFloat(section.count) / total
            }
            NSGraphicsContext.current?.cgContext.resetClip()
            x = 0
            for section in sections {
                section.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: 24, width: 8, height: 8)).fill()
                let label = "\(section.name) \(section.count)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
                label.draw(at: NSPoint(x: x + 13, y: 20), withAttributes: attributes)
                x += 13 + label.size(withAttributes: attributes).width + 16
            }
            return true
        }
    }

    static func bullets(_ points: [String], color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        style.headIndent = 16
        style.paragraphSpacing = 6
        let list = NSMutableAttributedString()
        for point in points {
            list.append(NSAttributedString(string: "●\t", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color, .paragraphStyle: style,
                                                                      .baselineOffset: 2]))
            list.append(NSAttributedString(string: point + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                                                                               .paragraphStyle: style]))
        }
        return list
    }

    static func attached(_ image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: image.size)
        return NSAttributedString(attachment: attachment)
    }

    private static func chip(_ text: String, at origin: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y, width: size.width + 16, height: 20), xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: NSPoint(x: origin.x + 8, y: origin.y + (20 - size.height) / 2), withAttributes: attributes)
    }

    private static func line(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private static func draw(_ symbol: String, size: CGFloat, color: NSColor, at origin: NSPoint) {
        let style = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(style) else { return }
        glyph.draw(in: NSRect(origin: origin, size: glyph.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: .usesLineFragmentOrigin, attributes: [.font: font]).height
    }
}
