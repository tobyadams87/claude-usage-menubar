import AppKit

// A slim usage bar for the dropdown, like the ones on the Claude usage page:
// a rounded track with a fill from the left. Drawn as a custom view so macOS doesn't dim it.
final class UsageBarView: NSView {
    static let leftInset: CGFloat = 30     // lines up with the text (labels have a ~2pt inner margin)
    static let rightInset: CGFloat = 16
    static let barHeight: CGFloat = 6

    var fraction: Double = 0 { didSet { needsDisplay = true } }      // 0...1
    var fillColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let h = Self.barHeight
        let track = NSRect(x: Self.leftInset, y: (bounds.height - h) / 2,
                           width: max(0, bounds.width - Self.leftInset - Self.rightInset), height: h)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()                 // works in light and dark
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        let f = CGFloat(min(1, max(0, fraction)))
        guard f > 0 else { return }
        var fill = track
        fill.size.width = max(h, track.width * f)                             // never thinner than a dot
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2).fill()
    }
}
