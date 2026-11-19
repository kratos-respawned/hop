import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Hop.iconset")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
}

func castShadow(_ ctx: CGContext, drop: CGFloat, blur: CGFloat, alpha: CGFloat) {
    let scale = ctx.ctm.a
    ctx.setShadow(offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale, color: color(0x000000, alpha))
}

// macOS 26+ puts an .icns on a gray plate unless its tile matches Apple's grid shape exactly, so no custom squircle.
func tileShape(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil)
}

func drawTile(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = tileShape(body)
    let everywhere: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    ctx.saveGState()
    castShadow(ctx, drop: 12, blur: 28, alpha: 0.35)
    ctx.addPath(tile)
    ctx.setFillColor(color(0x101233))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5B5FE0), color(0x101233)]), start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: everywhere)
    ctx.drawRadialGradient(gradient([color(0x3DE0E0, 0.2), color(0x3DE0E0, 0)]), startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 400, options: [])
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    ctx.addPath(tileShape(body.insetBy(dx: 2, dy: 2)))
    ctx.setStrokeColor(color(0xFFFFFF, 0.2))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func drawMark(_ ctx: CGContext) {
    let width: CGFloat = 108
    let stems = CGMutablePath()
    for x: CGFloat in [262, 654] {
        stems.addRoundedRect(in: CGRect(x: x, y: 250, width: width, height: 524), cornerWidth: width / 2, cornerHeight: width / 2)
    }
    let hop = CGMutablePath()
    hop.move(to: CGPoint(x: 316, y: 450))
    hop.addCurve(to: CGPoint(x: 708, y: 450), control1: CGPoint(x: 336, y: 750), control2: CGPoint(x: 688, y: 750))

    ctx.saveGState()
    castShadow(ctx, drop: 10, blur: 24, alpha: 0.3)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(stems)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.addPath(hop.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x3DF2C6), color(0x4FA8FF)]), start: CGPoint(x: 262, y: 0), end: CGPoint(x: 762, y: 0), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawTile(ctx)
    drawMark(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let output = root.appendingPathComponent("Resources/Hop.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", output.path])
iconutil.waitUntilExit()
print(output.path)
