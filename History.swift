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
    static let height: CGFloat = 52

    var points: [Sample] = [] { didSet { needsDisplay = true } }
    var windowStart = Date()
    var windowEnd = Date()
    var forecast: Double?            // projected % at the reset; nil = no forecast
    var forecastRunsOut: Date?       // when set, the forecast line ends at 100% at this time instead
    var warn = false

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: UsageBarView.leftInset, y: 6,
                          width: max(0, bounds.width - UsageBarView.leftInset - UsageBarView.rightInset),
                          height: bounds.height - 12)
        guard plot.width > 20, windowEnd > windowStart else { return }
        let span = windowEnd.timeIntervalSince(windowStart)
        func x(_ t: TimeInterval) -> CGFloat {
            plot.minX + plot.width * CGFloat(min(1, max(0, (t - windowStart.timeIntervalSince1970) / span)))
        }
        func y(_ pct: Double) -> CGFloat { plot.minY + plot.height * CGFloat(min(100, max(0, pct)) / 100) }

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
        if let end {
            let dash = NSBezierPath()
            dash.lineWidth = 1.5; dash.lineCapStyle = .round
            dash.setLineDash([1.5, 3.5], count: 2, phase: 0)
            dash.move(to: now); dash.line(to: end)
            (warn ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
            dash.stroke()
        }
        line.setFill()
        NSBezierPath(ovalIn: NSRect(x: now.x - 2.5, y: now.y - 2.5, width: 5, height: 5)).fill()
    }
}
