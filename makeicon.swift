import AppKit

// Renders the app icon (pixel mascot + usage bar) into an .iconset folder.
// Usage: makeicon <output.iconset>

func draw(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .none
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile (standard macOS icon grid: 824pt tile inside 1024 canvas)
    let tile = r(100, 100, 824, 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.white.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1),
               ending: NSColor(srgbRed: 0.90, green: 0.87, blue: 0.81, alpha: 1))!.draw(in: path, angle: -90)

    // Mascot: 12x8 grid, rows top→bottom
    let cell: CGFloat = 46
    let mw = 12 * cell, mh = 8 * cell
    let ox = (1024 - mw) / 2, oy = 1024 - ((1024 - mh) / 2 - 32) // top of mascot (y-up coords)
    let rows: [[Int]] = [Array(2...9), Array(2...9), Array(0...11), Array(0...11),
                         Array(2...9), Array(2...9), [2, 4, 7, 9], [2, 4, 7, 9]]
    let body = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.36, alpha: 1)
    // Snap every cell edge to a whole device pixel (and don't antialias): neighbouring cells then share
    // exact edges, so no faint seams show between the mascot's pixels at any icon size.
    ctx.shouldAntialias = false
    for (ri, cols) in rows.enumerated() {
        for c in cols {
            let eye = (ri == 1 && (c == 3 || c == 8))
            (eye ? NSColor.black : body).setFill()
            let x0 = ((ox + CGFloat(c) * cell) * s).rounded(), x1 = ((ox + CGFloat(c + 1) * cell) * s).rounded()
            let y0 = ((oy - CGFloat(ri + 1) * cell) * s).rounded(), y1 = ((oy - CGFloat(ri) * cell) * s).rounded()
            NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).fill()
        }
    }
    ctx.shouldAntialias = true

    // Usage bar under the mascot
    let bw: CGFloat = 480, bh: CGFloat = 44
    let bx = (1024 - bw) / 2, by: CGFloat = 250
    NSColor(srgbRed: 0.75, green: 0.71, blue: 0.64, alpha: 0.55).setFill()
    NSBezierPath(roundedRect: r(bx, by, bw, bh), xRadius: bh / 2 * s, yRadius: bh / 2 * s).fill()
    body.setFill()
    NSBezierPath(roundedRect: r(bx, by, bw * 0.42, bh), xRadius: bh / 2 * s, yRadius: bh / 2 * s).fill()

    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: out)
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
