import AppKit

// A small local log of usage readings, so the dropdown can chart the week so far.
// Stored as JSON in Application Support; only the last 8 days are kept.

struct Sample: Codable { var t: TimeInterval; var w: Double; var s: Double? }

final class History {
    private(set) var samples: [Sample] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Sample].self, from: d) { samples = s }
    }

    // Keep a reading when something changed, or as a heartbeat every 15 minutes, so a quiet stretch
    // still draws as a flat line without logging every poll.
    func record(weekly: Double, session: Double?, at date: Date = Date()) {
        let t = date.timeIntervalSince1970
        if let l = samples.last, l.w == weekly, l.s == session, t - l.t < 15 * 60 { return }
        samples.append(Sample(t: t, w: weekly, s: session))
        samples.removeAll { $0.t < t - 8 * 86400 }
        if let d = try? JSONEncoder().encode(samples) { try? d.write(to: url, options: .atomic) }
    }

    func samples(since start: Date) -> [Sample] { samples.filter { $0.t >= start.timeIntervalSince1970 } }
}

// The week so far: usage climbing from the left, with the "at this pace" forecast dotted to the reset.
final class HistoryChartView: NSView {
    static let height: CGFloat = 98
    static let plotLeft: CGFloat = 30          // room on the left for the 0% / 50% / 100% labels
    static let rightPad: CGFloat = 3.5       // the chart runs nearly to the edge of the menu

    var title = "Usage this week"
    var isSession = false            // 5-hour chart: hourly labels instead of day names
    var points: [(t: TimeInterval, v: Double)] = [] { didSet { needsDisplay = true } }
    var windowStart = Date()
    var windowEnd = Date()
    var forecast: Double?            // projected % at the reset; nil = no forecast
    var forecastRunsOut: Date?       // when set, the forecast line ends at 100% at this time instead
    var warn = false

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: Self.plotLeft, y: 24,
                          width: max(0, bounds.width - Self.plotLeft - Self.rightPad),
                          height: bounds.height - 24 - 28)
        guard plot.width > 20, windowEnd > windowStart else { return }
        let span = windowEnd.timeIntervalSince(windowStart)
        func x(_ t: TimeInterval) -> CGFloat {
            plot.minX + plot.width * CGFloat(min(1, max(0, (t - windowStart.timeIntervalSince1970) / span)))
        }
        func y(_ pct: Double) -> CGFloat { plot.minY + plot.height * CGFloat(min(100, max(0, pct)) / 100) }
        func label(_ t: String, size: CGFloat = 9, bold: Bool = false, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
            NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                                                       .foregroundColor: color])
        }

        // Title and key, so it reads without explanation.
        label(title, size: 10).draw(at: NSPoint(x: Self.rightPad, y: bounds.height - 21))
        // Y axis
        for (pct, text) in [(0.0, "0%"), (50, "50%"), (100, "100%")] {
            let l = label(text); l.draw(at: NSPoint(x: plot.minX - 2 - l.size().width, y: y(pct) - l.size().height / 2))
        }
        // Gridlines: baseline, a faint 50% line, and a firmer line at 100%, the limit.
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSRect(x: plot.minX, y: y(50), width: plot.width, height: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSRect(x: plot.minX, y: y(100) - 1, width: plot.width, height: 1).fill()

        // X axis: a label at the start of each day (or each hour, for the 5-hour chart), and where the window resets.
        let fmt = DateFormatter(); fmt.dateFormat = isSession ? "HH:mm" : "EEE"
        let rs = label("reset", size: 8.5); rs.draw(at: NSPoint(x: plot.maxX - rs.size().width, y: 8))
        let resetLeft = plot.maxX - rs.size().width - 2
        var ticks: [(CGFloat, String)] = []
        if isSession {
            let cal = Calendar.current
            var d = cal.nextDate(after: windowStart.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? windowStart
            while d < windowEnd { ticks.append((x(d.timeIntervalSince1970), fmt.string(from: d))); d = d.addingTimeInterval(3600) }
        } else {
            for d in 0..<7 { ticks.append((plot.minX + plot.width * CGFloat(d) / 7, fmt.string(from: windowStart.addingTimeInterval(Double(d) * 86400)))) }
        }
        for (tx, text) in ticks {
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            NSRect(x: tx, y: plot.minY, width: 1, height: 3).fill()
            let l = label(text, size: 8.5)
            let x0 = tx - l.size().width / 2          // centred on its notch, for days and hours alike
            if x0 + l.size().width < resetLeft, x0 >= plot.minX - 14 { l.draw(at: NSPoint(x: x0, y: 8)) }
        }

        let span0 = (points.last?.t ?? 0) - (points.first?.t ?? 0)
        let showNote = span0 < (isSession ? 1.5 : 12) * 3600
        let note = label("History fills in while the app runs", size: 10)
        let noteRect = NSRect(origin: NSPoint(x: plot.minX + 8, y: y(60)), size: note.size())
        guard let first = points.first, let last = points.last else {
            if showNote { note.draw(at: noteRect.origin) }
            return
        }
        let line = NSColor.systemBlue
        let area = NSBezierPath()
        area.move(to: NSPoint(x: x(first.t), y: plot.minY))
        for p in points { area.line(to: NSPoint(x: x(p.t), y: y(p.v))) }
        area.line(to: NSPoint(x: x(last.t), y: plot.minY))
        area.close()
        line.withAlphaComponent(0.18).setFill()
        area.fill()

        let path = NSBezierPath()
        path.lineWidth = 1.5; path.lineJoinStyle = .round; path.lineCapStyle = .round
        path.move(to: NSPoint(x: x(first.t), y: y(first.v)))
        for p in points.dropFirst() { path.line(to: NSPoint(x: x(p.t), y: y(p.v))) }
        line.setStroke()
        path.stroke()

        // Forecast: dotted from now to the reset (or to 100% at the time you'd run out).
        let now = NSPoint(x: x(last.t), y: y(last.v))
        var end: NSPoint?
        if let r = forecastRunsOut { end = NSPoint(x: x(r.timeIntervalSince1970), y: y(100)) }
        else if let f = forecast { end = NSPoint(x: plot.maxX, y: y(f)) }
        if end != nil {
            let k = label(forecastRunsOut != nil ? "forecast: runs out" : "forecast", size: 10,
                          color: warn ? .systemOrange : .secondaryLabelColor)
            let kx = plot.maxX - k.size().width
            k.draw(at: NSPoint(x: kx, y: bounds.height - 21))
            (warn ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
            let key = NSBezierPath(); key.lineWidth = 1.5; key.lineCapStyle = .round
            key.setLineDash([1.5, 3.5], count: 2, phase: 0)
            key.move(to: NSPoint(x: kx - 26, y: bounds.height - 15)); key.line(to: NSPoint(x: kx - 5, y: bounds.height - 15))
            key.stroke()
        }
        if let end {
            let dash = NSBezierPath()
            dash.lineWidth = 1.5; dash.lineCapStyle = .round
            dash.setLineDash([1.5, 3.5], count: 2, phase: 0)
            dash.move(to: now); dash.line(to: end)
            (warn ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
            dash.stroke()
            // Out of allowance before the reset: the locked-out stretch runs along the limit, in red.
            if forecastRunsOut != nil, end.x < plot.maxX - 1 {
                let lock = NSBezierPath()
                lock.lineWidth = 1.5; lock.lineCapStyle = .round
                lock.setLineDash([1.5, 3.5], count: 2, phase: 0)
                lock.move(to: end); lock.line(to: NSPoint(x: plot.maxX, y: end.y))
                NSColor.systemRed.setStroke()
                lock.stroke()
            }
        }
        // "N% now": above-left of the dot (clear of both the rising line and the forecast), or below-right
        // when the dot is too close to the top.
        let cur = label("\(Int(last.v.rounded()))% now", bold: true, color: .labelColor)
        let h = cur.size().height, w = cur.size().width
        let curOrigin = now.y + 3 + h < bounds.height - 22
            ? NSPoint(x: max(plot.minX, now.x - 6 - w), y: now.y + 3)
            : NSPoint(x: min(now.x + 4, plot.maxX - w), y: now.y - 3 - h)
        cur.draw(at: curOrigin)

        // The "history fills in" note is only shown while nothing would be drawn over it or cross it:
        // not the line, the shaded area under it, the forecast, or the "now" label.
        if showNote {
            let box = noteRect.insetBy(dx: -4, dy: -3)
            var hit = box.intersects(NSRect(origin: curOrigin, size: cur.size()))
            let pts = points.map { NSPoint(x: x($0.t), y: y($0.v)) }
            for (a, b) in zip(pts, pts.dropFirst()) + (pts.count == 1 ? [(pts[0], pts[0])] : []) {
                for i in 0...24 {
                    let f = CGFloat(i) / 24
                    let p = NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                    // under the line is shaded, so anything at or above the note's bottom within its width covers it
                    if p.x >= box.minX && p.x <= box.maxX && p.y >= box.minY { hit = true }
                }
            }
            if let end {
                for i in 0...24 {
                    let f = CGFloat(i) / 24
                    if box.contains(NSPoint(x: now.x + (end.x - now.x) * f, y: now.y + (end.y - now.y) * f)) { hit = true }
                }
            }
            if !hit { note.draw(at: noteRect.origin) }
        }
        line.setFill()
        NSBezierPath(ovalIn: NSRect(x: now.x - 2.5, y: now.y - 2.5, width: 5, height: 5)).fill()
    }
}
