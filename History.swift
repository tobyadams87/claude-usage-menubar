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
    static let height: CGFloat = 84

    var points: [Sample] = [] { didSet { needsDisplay = true } }
    var windowStart = Date()
    var windowEnd = Date()
    var forecast: Double?            // projected % at the reset; nil = no forecast
    var forecastRunsOut: Date?       // when set, the forecast line ends at 100% at this time instead
    var warn = false

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: UsageBarView.leftInset, y: 16,
                          width: max(0, bounds.width - UsageBarView.leftInset - UsageBarView.rightInset),
                          height: bounds.height - 16 - 22)
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
        label("Usage this week", size: 10).draw(at: NSPoint(x: plot.minX, y: bounds.height - 15))
        // Y axis
        for (pct, text) in [(0.0, "0%"), (50, "50%"), (100, "100%")] {
            let l = label(text); l.draw(at: NSPoint(x: plot.minX - 4 - l.size().width, y: y(pct) - l.size().height / 2))
        }
        // X axis: a label at the start of each day, and where the week resets.
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE"
        let rs = label("reset"); rs.draw(at: NSPoint(x: plot.maxX - rs.size().width, y: 2))
        for d in 0..<7 {
            let l = label(dayFmt.string(from: windowStart.addingTimeInterval(Double(d) * 86400)))
            let x0 = plot.minX + plot.width * CGFloat(d) / 7 + 2
            if x0 + l.size().width + 6 < plot.maxX - rs.size().width { l.draw(at: NSPoint(x: x0, y: 2)) }
        }

        // Frame: baseline, a faint 50% line, and a tick at each day.
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSRect(x: plot.minX, y: y(50), width: plot.width, height: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        for d in 1..<7 { NSRect(x: plot.minX + plot.width * CGFloat(d) / 7, y: plot.minY, width: 1, height: 3).fill() }

        guard let first = points.first, let last = points.last else { return }
        let line = NSColor.systemBlue
        let area = NSBezierPath()
        area.move(to: NSPoint(x: x(first.t), y: plot.minY))
        for p in points { area.line(to: NSPoint(x: x(p.t), y: y(p.w))) }
        area.line(to: NSPoint(x: x(last.t), y: plot.minY))
        area.close()
        line.withAlphaComponent(0.18).setFill()
        area.fill()

        let path = NSBezierPath()
        path.lineWidth = 1.5; path.lineJoinStyle = .round; path.lineCapStyle = .round
        path.move(to: NSPoint(x: x(first.t), y: y(first.w)))
        for p in points.dropFirst() { path.line(to: NSPoint(x: x(p.t), y: y(p.w))) }
        line.setStroke()
        path.stroke()

        // Forecast: dotted from now to the reset (or to 100% at the time you'd run out).
        let now = NSPoint(x: x(last.t), y: y(last.w))
        var end: NSPoint?
        if let r = forecastRunsOut { end = NSPoint(x: x(r.timeIntervalSince1970), y: y(100)) }
        else if let f = forecast { end = NSPoint(x: plot.maxX, y: y(f)) }
        if end != nil {
            let k = label(forecastRunsOut != nil ? "forecast: runs out" : "forecast", size: 10,
                          color: warn ? .systemOrange : .secondaryLabelColor)
            let kx = plot.maxX - k.size().width
            k.draw(at: NSPoint(x: kx, y: bounds.height - 15))
            (warn ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
            let key = NSBezierPath(); key.lineWidth = 1.5; key.lineCapStyle = .round
            key.setLineDash([1.5, 3.5], count: 2, phase: 0)
            key.move(to: NSPoint(x: kx - 26, y: bounds.height - 9)); key.line(to: NSPoint(x: kx - 5, y: bounds.height - 9))
            key.stroke()
        }
        if let end {
            let dash = NSBezierPath()
            dash.lineWidth = 1.5; dash.lineCapStyle = .round
            dash.setLineDash([1.5, 3.5], count: 2, phase: 0)
            dash.move(to: now); dash.line(to: end)
            (warn ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
            dash.stroke()
        }
        let cur = label("\(Int(last.w.rounded()))% now", bold: true, color: .labelColor)
        let cx = min(max(plot.minX, now.x - cur.size().width / 2), plot.maxX - cur.size().width)
        let above = now.y + 5 + cur.size().height < bounds.height - 16
        cur.draw(at: NSPoint(x: cx, y: above ? now.y + 4 : now.y - 4 - cur.size().height))
        line.setFill()
        NSBezierPath(ovalIn: NSRect(x: now.x - 2.5, y: now.y - 2.5, width: 5, height: 5)).fill()
    }
}
