import AppKit

// Drawing for the menu bar item: pixel mascot + two aligned text rows.
// Shared by the app and by the script that renders the README image.

// MARK: Mascot

enum Pose { case rest, blink, step, waveL, waveR }

// Pixel mascot drawn from a 12x8 grid (vector, so it's crisp at any scale, no image assets).
func mascotImage(cell: CGFloat = 1.5, pose: Pose = .rest) -> NSImage {
    var grid = Array(repeating: Array(repeating: false, count: 12), count: 8)
    func fill(_ rows: ClosedRange<Int>, _ cols: [Int]) { for r in rows { for c in cols { grid[r][c] = true } } }
    fill(0...5, Array(2...9))                                   // head/body
    fill(2...3, Array(0...11))                                  // arms
    fill(6...7, pose == .step ? [3, 4, 7, 8] : [2, 4, 7, 9])    // legs
    if pose == .waveL { for c in [0, 1] { grid[3][c] = false; grid[1][c] = true } }
    if pose == .waveR { for c in [10, 11] { grid[3][c] = false; grid[1][c] = true } }
    let body = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.36, alpha: 1)
    let eyes: Set<[Int]> = [[1, 3], [1, 8]]   // [row, col]
    let img = NSImage(size: NSSize(width: 12 * cell, height: 8 * cell), flipped: true) { _ in
        for r in 0..<8 { for c in 0..<12 where grid[r][c] {
            (eyes.contains([r, c]) && pose != .blink ? NSColor.black : body).setFill()
            NSRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell).fill()
        } }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: Text rows

struct BarRow {
    let label: String      // "wk" / "5h"
    let pct: String        // "13%"
    let color: NSColor?    // nil = normal text color
    let time: String?      // "6d8h", nil when there is no reset time
}

enum BarLayout {
    static let gap: CGFloat = 4          // mascot → text
    static let height: CGFloat = 22
    static let labelGap: CGFloat = 1     // label → percent
    static let dotPad: CGFloat = 1.5       // either side of the separator dot

    static func font(bold: Bool) -> NSFont {
        .monospacedDigitSystemFont(ofSize: 9, weight: bold ? .semibold : .regular)
    }
    static func text(_ s: String, bold: Bool = false, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font(bold: bold), .foregroundColor: color])
    }

    struct Columns { var label: CGFloat; var pct: CGFloat; var dot: CGFloat; var time: CGFloat
        var total: CGFloat { label + labelGap + pct + dot + time } }

    // Column widths are the widest entry in each column, so the dots line up exactly.
    static func columns(_ rows: [BarRow]) -> Columns {
        func w(_ s: String, _ bold: Bool) -> CGFloat { text(s, bold: bold, color: .white).size().width }
        let times = rows.compactMap { $0.time }
        let dotW = times.isEmpty ? 0 : w("·", false) + 2 * dotPad
        return Columns(label: ceil(rows.map { w($0.label, false) }.max() ?? 0),
                       pct: ceil(rows.map { w($0.pct, true) }.max() ?? 0),
                       dot: ceil(dotW * 2) / 2,
                       time: ceil(times.map { w($0, false) }.max() ?? 0))
    }

    // Old layout: each row is one run of text ("wk 13% · 6d8h"), dots not aligned but no wasted space.
    static func run(_ r: BarRow, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(text(r.label + " ", color: textColor))
        out.append(text(r.pct, bold: true, color: r.color ?? textColor))
        if let t = r.time { out.append(text(" · " + t, color: textColor)) }
        return out
    }

    static func image(rows: [BarRow], pose: Pose, textColor: NSColor = .labelColor) -> NSImage {
        let mascot = mascotImage(pose: pose)
        let cols = columns(rows)
        // Aligned columns need the widest entry of each column; in rare combinations that is wider than
        // the plain runs. Never take more menu bar room than the plain layout would.
        let runs = rows.map { run($0, textColor: textColor) }
        let plainW = ceil(runs.map { $0.size().width }.max() ?? 0)
        if cols.total > plainW + 0.5 { return plainImage(runs: runs, mascot: mascot, width: plainW) }
        let H = height
        let lineH = text("0", color: textColor).size().height
        let total = 2 * lineH - 2
        let y0 = (H - total) / 2
        let x0 = mascot.size.width + gap
        let width = x0 + cols.total

        return NSImage(size: NSSize(width: width, height: H), flipped: false) { _ in
            mascot.draw(in: NSRect(x: 0, y: (H - mascot.size.height) / 2,
                                   width: mascot.size.width, height: mascot.size.height))
            for (i, r) in rows.enumerated() {
                let y = i == 0 ? y0 + lineH - 2 : y0          // row 0 on top
                text(r.label, color: textColor).draw(at: NSPoint(x: x0, y: y))
                let p = text(r.pct, bold: true, color: r.color ?? textColor)
                let pctBase = x0 + cols.label + labelGap
                p.draw(at: NSPoint(x: pctBase + cols.pct - p.size().width, y: y))   // right-aligned
                if let t = r.time {
                    let dx = pctBase + cols.pct
                    text("·", color: textColor).draw(at: NSPoint(x: dx + dotPad, y: y))
                    text(t, color: textColor).draw(at: NSPoint(x: dx + cols.dot, y: y))
                }
            }
            return true
        }
    }

    static func plainImage(runs: [NSAttributedString], mascot: NSImage, width: CGFloat) -> NSImage {
        let H = height
        let lineH = runs.first?.size().height ?? 11
        let y0 = (H - (2 * lineH - 2)) / 2
        let x0 = mascot.size.width + gap
        return NSImage(size: NSSize(width: x0 + width, height: H), flipped: false) { _ in
            mascot.draw(in: NSRect(x: 0, y: (H - mascot.size.height) / 2,
                                   width: mascot.size.width, height: mascot.size.height))
            for (i, r) in runs.enumerated() { r.draw(at: NSPoint(x: x0, y: i == 0 ? y0 + lineH - 2 : y0)) }
            return true
        }
    }
}
