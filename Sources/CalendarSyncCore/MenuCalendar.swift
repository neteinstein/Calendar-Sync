import Foundation

/// Date math for the menu's month view and event list. Pure logic, unit tested.
public enum MenuCalendar {
    /// Every day shown in a month grid: the month's days, padded to whole weeks with the
    /// neighbouring months' days. Always whole weeks, starting on the calendar's first weekday.
    /// Without weekends, each week keeps only its working days.
    public static func gridDays(for month: Date, calendar: Calendar, showsWeekends: Bool = true) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)
        else { return [] }

        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            if showsWeekends || !calendar.isDateInWeekend(day) {
                days.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The weekdays (1 is Sunday) of a grid's columns, in order, starting on the calendar's
    /// first weekday.
    public static func weekdays(calendar: Calendar, showsWeekends: Bool = true) -> [Int] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start),
                  showsWeekends || !calendar.isDateInWeekend(day) else { return nil }
            return calendar.component(.weekday, from: day)
        }
    }

    /// One day of the list view, with its events soonest first.
    public struct DaySection: Hashable, Sendable {
        public var day: Date
        public var events: [SourceEvent]

        public init(day: Date, events: [SourceEvent]) {
            self.day = day
            self.events = events
        }
    }

    /// Groups events into days for the list view, both sorted. A multi-day event appears
    /// under the day it starts.
    public static func sections(for events: [SourceEvent], calendar: Calendar) -> [DaySection] {
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            DaySection(day: day, events: byDay[day]!.sorted { ($0.start, $0.title) < ($1.start, $1.title) })
        }
    }

    /// One day's events split for the event lists: all-day events first, then the timed ones
    /// starting before noon, then the rest. Each part keeps its order.
    public struct DayParts: Hashable, Sendable {
        public var allDay: [SourceEvent] = []
        public var morning: [SourceEvent] = []
        public var afternoon: [SourceEvent] = []
    }

    public static func parts(of events: [SourceEvent], calendar: Calendar) -> DayParts {
        var parts = DayParts()
        for event in events {
            if event.isAllDay {
                parts.allDay.append(event)
            } else if calendar.component(.hour, from: event.start) < 12 {
                parts.morning.append(event)
            } else {
                parts.afternoon.append(event)
            }
        }
        return parts
    }

    /// The secondary calendar an event in the main calendar was copied from, or nil for the main
    /// calendar's own events.
    public static func originID(of event: SourceEvent) -> UUID? {
        CopyMarker.find(in: event.notes)?.sourceID
    }
}
