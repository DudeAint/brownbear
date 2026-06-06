//
//  CrontabSchedule.swift
//  BrownBear
//
//  Parses and evaluates `@crontab` expressions for background scripts, mirroring ScriptCat:
//    • standard 5-field cron  `min hour dom mon dow`  (`*`, lists `1,2`, ranges `1-5`,
//      steps `*/n` / `a-b/n`, and 3-letter month/day names), with the POSIX day-of-month /
//      day-of-week "either matches" quirk;
//    • `@every <n>(s|m|h|d)` interval schedules;
//    • `once` alone (run a single time), and ScriptCat's per-field `once` keyword which runs at
//      most once per that unit (minute/hour/day/month/week).
//
//  On iOS, background wake-ups are infrequent and irregular, so we evaluate "is a fire time due
//  since the last run?" rather than relying on a live per-minute timer. Pure logic, fully tested.
//

import Foundation

struct CrontabSchedule: Equatable {

    /// A parsed cron field over an inclusive [low, high] range.
    struct Field: Equatable {
        let any: Bool
        let values: Set<Int>
        func matches(_ value: Int) -> Bool { any || values.contains(value) }
        static let wildcard = Field(any: true, values: [])
    }

    /// Which calendar unit a `once` keyword pins de-duplication to.
    enum OnceUnit: Equatable { case minute, hour, day, month, week }

    enum Kind: Equatable {
        case interval(TimeInterval)
        case onceEver
        case cron(minute: Field, hour: Field, dayOfMonth: Field, month: Field, dayOfWeek: Field, once: OnceUnit?)
    }

    let kind: Kind
    let raw: String

    // MARK: - Parsing

    /// Parse a crontab expression, or nil if it is malformed.
    static func parse(_ expression: String) -> CrontabSchedule? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else { return nil }

        if lower == "once" { return CrontabSchedule(kind: .onceEver, raw: trimmed) }

        if lower.hasPrefix("@every") {
            guard let interval = parseEvery(lower) else { return nil }
            return CrontabSchedule(kind: .interval(interval), raw: trimmed)
        }

        var tokens = lower.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // A 6-field expression carries a leading seconds field; iOS can't wake per-second, so we
        // drop it and keep the 5 standard fields.
        if tokens.count == 6 { tokens.removeFirst() }
        guard tokens.count == 5 else { return nil }

        var onceUnit: OnceUnit?
        let unitForIndex: [Int: OnceUnit] = [0: .minute, 1: .hour, 2: .day, 3: .month, 4: .week]

        func field(_ index: Int, _ low: Int, _ high: Int, names: [String: Int] = [:]) -> Field? {
            let token = tokens[index]
            if token == "once" {
                if onceUnit == nil { onceUnit = unitForIndex[index] }
                return .wildcard
            }
            return parseField(token, low: low, high: high, names: names)
        }

        guard let minute = field(0, 0, 59),
              let hour = field(1, 0, 23),
              let dom = field(2, 1, 31),
              let month = field(3, 1, 12, names: monthNames),
              let dow = field(4, 0, 7, names: dayNames) else {
            return nil
        }
        return CrontabSchedule(
            kind: .cron(minute: minute, hour: hour, dayOfMonth: dom, month: month,
                        dayOfWeek: normalizeWeekday(dow), once: onceUnit),
            raw: trimmed)
    }

    private static func parseEvery(_ token: String) -> TimeInterval? {
        let value = token.dropFirst("@every".count).trimmingCharacters(in: .whitespaces)
        guard let unit = value.last, let amount = Double(value.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3600
        case "d": return amount * 86400
        default: return nil
        }
    }

    /// Parse one field (comma-separated terms of `*`, `n`, `a-b`, `*/n`, `a-b/n`).
    private static func parseField(_ token: String, low: Int, high: Int, names: [String: Int]) -> Field? {
        if token == "*" { return .wildcard }
        var values = Set<Int>()
        for term in token.split(separator: ",") {
            guard let parsed = parseTerm(String(term), low: low, high: high, names: names) else { return nil }
            values.formUnion(parsed)
        }
        return values.isEmpty ? nil : Field(any: false, values: values)
    }

    private static func parseTerm(_ term: String, low: Int, high: Int, names: [String: Int]) -> Set<Int>? {
        var base = term
        var step = 1
        if let slash = term.firstIndex(of: "/") {
            guard let parsedStep = Int(term[term.index(after: slash)...]), parsedStep > 0 else { return nil }
            step = parsedStep
            base = String(term[term.startIndex..<slash])
        }

        var rangeLow = low
        var rangeHigh = high
        if base == "*" {
            // keep full range
        } else if let dash = base.firstIndex(of: "-") {
            guard let lo = resolve(String(base[base.startIndex..<dash]), names: names),
                  let hi = resolve(String(base[base.index(after: dash)...]), names: names) else { return nil }
            rangeLow = lo
            rangeHigh = hi
        } else {
            guard let single = resolve(base, names: names), single >= low, single <= high else { return nil }
            if step == 1 { return [single] }
            rangeLow = single
            rangeHigh = high
        }

        guard rangeLow >= low, rangeHigh <= high, rangeLow <= rangeHigh else { return nil }
        var result = Set<Int>()
        var value = rangeLow
        while value <= rangeHigh {
            result.insert(value)
            value += step
        }
        return result
    }

    private static func resolve(_ token: String, names: [String: Int]) -> Int? {
        if let number = Int(token) { return number }
        return names[token.lowercased()]
    }

    /// Normalize day-of-week so 7 (also Sunday) folds into 0.
    private static func normalizeWeekday(_ field: Field) -> Field {
        guard !field.any, field.values.contains(7) else { return field }
        var values = field.values
        values.remove(7)
        values.insert(0)
        return Field(any: false, values: values)
    }

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                     "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    // MARK: - Evaluation

    /// Whether a fire is due at `now` given the last time the script ran (nil = never).
    func isDue(now: Date, lastFire: Date?, calendar: Calendar = .gregorianUTC) -> Bool {
        switch kind {
        case .interval(let seconds):
            return (lastFire ?? .distantPast).addingTimeInterval(seconds) <= now
        case .onceEver:
            return lastFire == nil
        case .cron(_, _, _, _, _, let once):
            let from = lastFire ?? now.addingTimeInterval(-60)
            guard let next = nextFireDate(after: from, calendar: calendar), next <= now else { return false }
            if let once, let lastFire, sameUnit(lastFire, now, once, calendar: calendar) {
                return false   // already ran this minute/hour/day/month/week
            }
            return true
        }
    }

    /// The next datetime strictly after `date` that the cron matches, or nil (interval/once or
    /// no match within the search horizon).
    func nextFireDate(after date: Date, calendar: Calendar = .gregorianUTC) -> Date? {
        guard case let .cron(minute, hour, dom, month, dow, _) = kind else {
            if case let .interval(seconds) = kind { return date.addingTimeInterval(seconds) }
            return nil
        }

        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        guard let truncated = calendar.date(from: comps) else { return nil }
        var candidate = truncated.addingTimeInterval(60)   // strictly after `date`

        var iterations = 0
        let maxIterations = 367 * 24 * 60   // ~ a year of minutes; day/month skips converge faster
        while iterations < maxIterations {
            iterations += 1
            let parts = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: candidate)
            guard let mo = parts.month, let day = parts.day, let hr = parts.hour,
                  let mi = parts.minute, let weekday = parts.weekday else { return nil }
            let cronDow = weekday - 1   // Calendar 1=Sun → cron 0=Sun

            if !month.matches(mo) {
                candidate = startOfNextMonth(candidate, calendar) ?? candidate.addingTimeInterval(86400)
                continue
            }
            if !dayMatches(dom: dom, dow: dow, day: day, weekday: cronDow) {
                candidate = startOfNextDay(candidate, calendar) ?? candidate.addingTimeInterval(86400)
                continue
            }
            if !hour.matches(hr) {
                candidate = startOfNextHour(candidate, calendar) ?? candidate.addingTimeInterval(3600)
                continue
            }
            if !minute.matches(mi) {
                candidate = candidate.addingTimeInterval(60)
                continue
            }
            return candidate
        }
        return nil
    }

    // MARK: - Day matching (POSIX quirk)

    private func dayMatches(dom: Field, dow: Field, day: Int, weekday: Int) -> Bool {
        let domMatch = dom.matches(day)
        let dowMatch = dow.matches(weekday)
        if !dom.any && !dow.any {
            // Both restricted: match if EITHER matches (standard cron behavior).
            return domMatch || dowMatch
        }
        return domMatch && dowMatch
    }

    private func sameUnit(_ a: Date, _ b: Date, _ unit: OnceUnit, calendar: Calendar) -> Bool {
        switch unit {
        case .minute: return calendar.isDate(a, equalTo: b, toGranularity: .minute)
        case .hour: return calendar.isDate(a, equalTo: b, toGranularity: .hour)
        case .day: return calendar.isDate(a, equalTo: b, toGranularity: .day)
        case .month: return calendar.isDate(a, equalTo: b, toGranularity: .month)
        case .week: return calendar.isDate(a, equalTo: b, toGranularity: .weekOfYear)
        }
    }

    private func startOfNextHour(_ date: Date, _ calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        comps.minute = 0
        comps.second = 0
        guard let hourStart = calendar.date(from: comps) else { return nil }
        return calendar.date(byAdding: .hour, value: 1, to: hourStart)
    }

    private func startOfNextDay(_ date: Date, _ calendar: Calendar) -> Date? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return nil }
        return next
    }

    private func startOfNextMonth(_ date: Date, _ calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        guard let monthStart = calendar.date(from: comps) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }
}

extension Calendar {
    /// A stable calendar for schedule math (gregorian, UTC) so behavior is deterministic and
    /// testable regardless of device timezone.
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}
