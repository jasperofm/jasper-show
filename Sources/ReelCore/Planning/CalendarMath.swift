import Foundation

/// Date helpers for the calendar views.
public enum CalendarMath {
    /// The 6×7 grid of days shown for the month containing `date`.
    public static func monthGrid(containing date: Date, calendar cal: Calendar) -> [Date] {
        guard let month = cal.dateInterval(of: .month, for: date) else { return [] }
        let first = month.start
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// The seven days of the week containing `date`.
    public static func week(containing date: Date, calendar cal: Calendar) -> [Date] {
        guard let w = cal.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: w.start) }
    }

    /// `date` moved to another day, keeping its clock time (DST-safe).
    public static func move(_ date: Date, toDay day: Date, calendar cal: Calendar) -> Date {
        let t = cal.dateComponents([.hour, .minute], from: date)
        var d = cal.dateComponents([.year, .month, .day], from: day)
        d.hour = t.hour; d.minute = t.minute
        return cal.date(from: d) ?? date
    }

    /// `day` at a given hour, keeping the minutes of `date`.
    public static func move(_ date: Date, toDay day: Date, hour: Int, calendar cal: Calendar) -> Date {
        var d = cal.dateComponents([.year, .month, .day], from: day)
        d.hour = hour
        d.minute = cal.component(.minute, from: date)
        return cal.date(from: d) ?? date
    }
}

/// Exports the schedule for other calendars (iCal) and spreadsheets (CSV).
public enum ScheduleExport {
    public struct Row: Sendable {
        public var job: PostJob
        public var accountName: String
        public var platform: String
        public var videoName: String

        public init(job: PostJob, accountName: String, platform: String, videoName: String) {
            self.job = job; self.accountName = accountName; self.platform = platform; self.videoName = videoName
        }
    }

    public static func ics(_ rows: [Row], now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Reel Manager//Schedule//EN", "CALSCALE:GREGORIAN"]
        for r in rows {
            guard let start = r.job.calendarDate else { continue }
            lines += [
                "BEGIN:VEVENT",
                "UID:\(r.job.id.uuidString)@reelmanager",
                "DTSTAMP:\(f.string(from: now))",
                "DTSTART:\(f.string(from: start))",
                "DTEND:\(f.string(from: start.addingTimeInterval(15 * 60)))",
                "SUMMARY:\(escape("\(r.platform) \(r.accountName): \(r.videoName)"))",
                "DESCRIPTION:\(escape("\(r.job.stateLabel). \(r.job.caption)"))",
                "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    public static func csv(_ rows: [Row], timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        func cell(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        var out = ["Date (\(timeZone.identifier)),Platform,Account,Video,State,Caption,Link"]
        for r in rows.sorted(by: { ($0.job.calendarDate ?? .distantFuture) < ($1.job.calendarDate ?? .distantFuture) }) {
            out.append([r.job.calendarDate.map(f.string(from:)) ?? "", r.platform, r.accountName, r.videoName,
                        r.job.stateLabel, r.job.caption, r.job.remoteURL ?? ""].map(cell).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: #"\"#, with: #"\\"#).replacingOccurrences(of: ";", with: #"\;"#)
            .replacingOccurrences(of: ",", with: #"\,"#).replacingOccurrences(of: "\n", with: #"\n"#)
    }

    /// RFC 5545: lines longer than 75 octets are folded.
    static func fold(_ line: String) -> String {
        var out = ""
        var count = 0
        for ch in line {
            let n = String(ch).utf8.count
            if count + n > 75 { out += "\r\n "; count = 1 }
            out.append(ch)
            count += n
        }
        return out
    }
}
