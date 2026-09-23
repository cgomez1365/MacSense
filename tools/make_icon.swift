import AppKit

// Draws the MacSense icon at every size an .iconset needs. build.sh runs this, so the icon is
// generated from code and there's no binary artwork to lose.
// Design: the macOS icon grid (824pt body on a 1024 canvas), a dark squircle, and a pulse line
// shaped like an M that goes from Nitro red to blue.

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let s = CGFloat(pixels) / 1024
    cg.scaleBy(x: s, y: s)

    // Body with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000, 0.45).cgColor)
    cg.addPath(shape)
    cg.setFillColor(srgb(0x0d1017).cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [srgb(0x1b2130).cgColor, srgb(0x0a0c12).cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint grid, like a chart.
    cg.setStrokeColor(srgb(0xffffff, 0.06).cgColor)
    cg.setLineWidth(3)
    for y in stride(from: 250.0, through: 800.0, by: 110.0) {
        cg.move(to: CGPoint(x: 100, y: y))
        cg.addLine(to: CGPoint(x: 924, y: y))
    }
    cg.strokePath()

    // The pulse: a flat line, an M-shaped double peak, a flat line.
    let pulse = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: 200, y: 470), CGPoint(x: 330, y: 470), CGPoint(x: 400, y: 700), CGPoint(x: 512, y: 455),
        CGPoint(x: 624, y: 700), CGPoint(x: 694, y: 470), CGPoint(x: 824, y: 470),
    ]
    pulse.addLines(between: points)
    let stroked = pulse.copy(strokingWithWidth: 58, lineCap: .round, lineJoin: .round, miterLimit: 10)

    // Glow under the line.
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 46, color: srgb(0xff1e44, 0.7).cgColor)
    cg.addPath(stroked)
    cg.setFillColor(srgb(0xff1e44).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // The line itself: red to blue.
    cg.saveGState()
    cg.addPath(stroked)
    cg.clip()
    let line = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [srgb(0xff1e44).cgColor, srgb(0xff4d6d).cgColor, srgb(0x3987e5).cgColor] as CFArray,
                          locations: [0, 0.45, 1])!
    // Extend past both ends so the round caps take the end colours too.
    cg.drawLinearGradient(line, start: CGPoint(x: 200, y: 512), end: CGPoint(x: 824, y: 512),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    cg.restoreGState()

    // A hairline edge so the icon holds up on light and dark Docks.
    cg.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    cg.setStrokeColor(srgb(0xffffff, 0.10).cgColor)
    cg.setLineWidth(3)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let png = render(pixels: pixels) else { fatalError("could not draw \(name)") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
print("icon set written to \(output.path)")
