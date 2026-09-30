import Foundation

// "At this pace..." prediction, worked out the same way the Claude app does:
// extrapolate the usage so far, in a straight line, over the rest of the window.

enum Projection {
    case none               // nothing useful to say (no usage yet, too early in the window, already at limit)
    case onPace(Double)     // projected % used at reset, below 100
    case runsOut(Date)      // projected to hit 100% at this time, before the window resets

    static func make(utilization: Double, resetsAt: Date?, window: TimeInterval, now: Date = Date()) -> Projection {
        guard let resetsAt, resetsAt > now, utilization > 0, utilization < 100 else { return .none }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-window))
        guard elapsed > window * 0.04 else { return .none }       // too early in the window to trust
        let rate = utilization / elapsed                          // percent per second so far
        let runOut = now.addingTimeInterval((100 - utilization) / rate)
        return runOut < resetsAt ? .runsOut(runOut) : .onPace(utilization * window / elapsed)
    }

    var runsOutSoon: Bool { if case .runsOut = self { return true } else { return false } }

    // MARK: Wording

    private static func part(_ d: Date, _ cal: Calendar) -> String {
        switch cal.component(.hour, from: d) {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
    private static let clock: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    // "Monday morning", "tomorrow afternoon", "this evening"
    static func dayPhrase(_ d: Date, now: Date, cal: Calendar = .current) -> String {
        let p = part(d, cal)
        if cal.isDate(d, inSameDayAs: now) { return p == "night" ? "tonight" : "this \(p)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            return "tomorrow \(p)"
        }
        return "\(weekday.string(from: d)) \(p)"
    }

    // "Tuesday's reset", "tomorrow's reset", "today's reset"
    static func resetPhrase(_ d: Date, now: Date, cal: Calendar = .current) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "today's reset" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            return "tomorrow's reset"
        }
        return "\(weekday.string(from: d))'s reset"
    }

    func weeklyText(resetsAt: Date?, now: Date = Date()) -> String? {
        switch self {
        case .none: return nil
        case .onPace(let p): return "On pace for about \(Int(p.rounded()))% by reset"
        case .runsOut(let d):
            guard let r = resetsAt else { return nil }
            return "At this pace you'll run out \(Self.dayPhrase(d, now: now)), before \(Self.resetPhrase(r, now: now))"
        }
    }

    func sessionText(resetsAt: Date?, now: Date = Date()) -> String? {
        switch self {
        case .none: return nil
        case .onPace(let p): return "On pace for about \(Int(p.rounded()))% by reset"
        case .runsOut(let d):
            guard let r = resetsAt else { return nil }
            return "At this pace you'll run out at \(Self.clock.string(from: d)), before the \(Self.clock.string(from: r)) reset"
        }
    }
}
