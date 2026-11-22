import AppKit

private var tiles: [String: NSImage] = [:]

private let appIconMargin: CGFloat = 2.5
private let iconBox = NSRect(x: 0, y: 0, width: 26, height: 26).insetBy(dx: appIconMargin, dy: appIconMargin)

func tile(_ symbol: String, _ color: NSColor) -> NSImage {
    let key = "\(symbol) \(color)"
    if let cached = tiles[key] { return cached }
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
    tiles[key] = image
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


func thumbnail(of url: URL, maxPixels: Int) -> NSImage? {
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
    let source = url.pathExtension == "sealed" ? Sealed.read(url).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } : CGImageSourceCreateWithURL(url as CFURL, nil)
    guard let source,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
}
