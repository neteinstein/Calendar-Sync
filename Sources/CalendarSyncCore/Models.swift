import Foundation

/// Where a source calendar's events come from.
public enum SourceKind: Codable, Hashable, Sendable {
    /// A calendar Calendar.app already knows about (Google, Exchange, iCloud, or a
    /// subscribed calendar link). Identified by `EKCalendar.calendarIdentifier`.
    case eventKit(calendarID: String)
    /// An Outlook / Microsoft 365 calendar read through the built-in browser window.
    case outlookWeb
}

/// What the main calendar's events are shown as inside a secondary calendar.
public enum BusyStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case busy
    case outOfOffice

    /// The copy's title. Like the copy itself, it carries no detail of the original event.
    public var title: String {
        switch self {
        case .busy: "Busy"
        case .outOfOffice: "Out of office"
        }
    }
}

/// One secondary calendar the user wants copied into the target calendar.
public struct SourceConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    /// The source calendar's name, shown in brackets at the start of every copied title,
    /// e.g. `[Calendar A] Standup`. For Calendar.app sources the app keeps it in step with the
    /// calendar's current name; for Outlook web sources the user types it.
    public var calendarName: String
    /// When on, copies are titled `[Calendar A] Busy` instead of using the meeting name.
    public var hideMeetingName: Bool
    public var isEnabled: Bool
    /// While syncing both ways, events in the main calendar are also added to this secondary
    /// calendar as plain "Busy" or "Out of office" events with no other details. Only possible
    /// for calendars that can be edited.
    public var showBusyInSecondary: Bool
    /// What those events say: "Busy" or "Out of office".
    public var busyStyle: BusyStyle
    /// When on, copies also get the meeting's location and description. Ignored while
    /// `hideMeetingName` is on, so hidden meetings don't leak through their details.
    public var copyDetails: Bool
    /// How often this calendar is read, in minutes. `nil` uses the app-wide interval.
    public var intervalMinutes: Int?

    // `showBusyInSecondary` keeps the key older versions saved it under.
    enum CodingKeys: String, CodingKey {
        case id, kind, calendarName, hideMeetingName, isEnabled
        case showBusyInSecondary = "showBusyInClient"
        case busyStyle, copyDetails, intervalMinutes
    }

    public init(
        id: UUID = UUID(),
        kind: SourceKind,
        calendarName: String,
        hideMeetingName: Bool = false,
        isEnabled: Bool = true,
        showBusyInSecondary: Bool = false,
        busyStyle: BusyStyle = .busy,
        copyDetails: Bool = false,
        intervalMinutes: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.calendarName = calendarName
        self.hideMeetingName = hideMeetingName
        self.isEnabled = isEnabled
        self.showBusyInSecondary = showBusyInSecondary
        self.busyStyle = busyStyle
        self.copyDetails = copyDetails
        self.intervalMinutes = intervalMinutes
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        calendarName = try c.decode(String.self, forKey: .calendarName)
        hideMeetingName = try c.decodeIfPresent(Bool.self, forKey: .hideMeetingName) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showBusyInSecondary = try c.decodeIfPresent(Bool.self, forKey: .showBusyInSecondary) ?? false
        busyStyle = try c.decodeIfPresent(BusyStyle.self, forKey: .busyStyle) ?? .busy
        copyDetails = try c.decodeIfPresent(Bool.self, forKey: .copyDetails) ?? false
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes)
    }
}

/// Settings that apply to every source.
public struct SyncOptions: Codable, Hashable, Sendable {
    public var daysAhead: Int
    public var skipDeclined: Bool
    public var skipAllDay: Bool
    /// Skip secondary-calendar events shown as "Out of office" (holidays, leave), so they don't block the
    /// main calendar.
    public var skipOutOfOffice: Bool

    public init(daysAhead: Int = 5, skipDeclined: Bool = true, skipAllDay: Bool = false, skipOutOfOffice: Bool = true) {
        self.daysAhead = daysAhead
        self.skipDeclined = skipDeclined
        self.skipAllDay = skipAllDay
        self.skipOutOfOffice = skipOutOfOffice
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SyncOptions()
        daysAhead = try c.decodeIfPresent(Int.self, forKey: .daysAhead) ?? defaults.daysAhead
        skipDeclined = try c.decodeIfPresent(Bool.self, forKey: .skipDeclined) ?? defaults.skipDeclined
        skipAllDay = try c.decodeIfPresent(Bool.self, forKey: .skipAllDay) ?? defaults.skipAllDay
        skipOutOfOffice = try c.decodeIfPresent(Bool.self, forKey: .skipOutOfOffice) ?? defaults.skipOutOfOffice
    }
}

/// What the menu bar icon shows next to today's date while the menu calendar is on.
public struct MenuBarOptions: Codable, Hashable, Sendable {
    public var showsWeekday: Bool
    public var showsMoonPhase: Bool
    public var showsTime: Bool

    public init(showsWeekday: Bool = false, showsMoonPhase: Bool = false, showsTime: Bool = false) {
        self.showsWeekday = showsWeekday
        self.showsMoonPhase = showsMoonPhase
        self.showsTime = showsTime
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showsWeekday = try c.decodeIfPresent(Bool.self, forKey: .showsWeekday) ?? false
        showsMoonPhase = try c.decodeIfPresent(Bool.self, forKey: .showsMoonPhase) ?? false
        showsTime = try c.decodeIfPresent(Bool.self, forKey: .showsTime) ?? false
    }
}

/// How the menu's month view lays out a week, and how its event lists are colored.
public struct MenuCalendarOptions: Codable, Hashable, Sendable {
    public enum WeekStart: String, Codable, CaseIterable, Sendable {
        /// Whatever macOS uses for the current region.
        case system, sunday, monday
    }

    public var weekStart: WeekStart
    public var showsWeekends: Bool
    /// All-day events get a stronger background than timed ones.
    public var shadesAllDay: Bool
    /// Each event is tinted with the color of the calendar it was copied from.
    public var colorsByCalendar: Bool
    /// A day's morning and afternoon events sit in blocks of their own color.
    public var shadesTimeOfDay: Bool

    public init(weekStart: WeekStart = .system, showsWeekends: Bool = true, shadesAllDay: Bool = true,
                colorsByCalendar: Bool = true, shadesTimeOfDay: Bool = true) {
        self.weekStart = weekStart
        self.showsWeekends = showsWeekends
        self.shadesAllDay = shadesAllDay
        self.colorsByCalendar = colorsByCalendar
        self.shadesTimeOfDay = shadesTimeOfDay
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try c.decodeIfPresent(WeekStart.self, forKey: .weekStart) ?? .system
        showsWeekends = try c.decodeIfPresent(Bool.self, forKey: .showsWeekends) ?? true
        shadesAllDay = try c.decodeIfPresent(Bool.self, forKey: .shadesAllDay) ?? true
        colorsByCalendar = try c.decodeIfPresent(Bool.self, forKey: .colorsByCalendar) ?? true
        shadesTimeOfDay = try c.decodeIfPresent(Bool.self, forKey: .shadesTimeOfDay) ?? true
    }

    /// `calendar` with its first weekday set to the chosen one.
    public func applied(to calendar: Calendar) -> Calendar {
        var calendar = calendar
        switch weekStart {
        case .system: break
        case .sunday: calendar.firstWeekday = 1
        case .monday: calendar.firstWeekday = 2
        }
        return calendar
    }
}

/// A single meeting occurrence read from a source, independent of where it came from.
public struct SourceEvent: Hashable, Sendable {
    /// Stable per occurrence: stays the same when the meeting is moved, so the copy is
    /// updated rather than deleted and recreated.
    public var key: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone?
    public var isDeclined: Bool
    public var isCancelled: Bool
    /// Shown as "Out of office" in the source calendar.
    public var isOutOfOffice: Bool
    public var meetingURL: URL?
    /// Notes (description) of the source event, as plain text. Used to recognise events this
    /// app created (so two-way syncing doesn't loop), and copied when the source asks for details.
    public var notes: String?
    public var location: String?

    public init(
        key: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        timeZone: TimeZone? = nil,
        isDeclined: Bool = false,
        isCancelled: Bool = false,
        isOutOfOffice: Bool = false,
        meetingURL: URL? = nil,
        notes: String? = nil,
        location: String? = nil
    ) {
        self.key = key
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.isDeclined = isDeclined
        self.isCancelled = isCancelled
        self.isOutOfOffice = isOutOfOffice
        self.meetingURL = meetingURL
        self.notes = notes
        self.location = location
    }
}

/// What a copy in the target calendar, or a Busy event in a secondary calendar, should look like.
public struct CopySpec: Hashable, Sendable {
    /// The hidden tag at the end of the notes. Nil for a Busy event, which carries none.
    public var marker: CopyMarker?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone?
    public var url: URL?
    public var notes: String
    public var location: String?
    /// Saved with "Out of office" availability where the calendar supports it, "Busy" otherwise.
    public var isOutOfOffice: Bool

    public init(marker: CopyMarker?, title: String, start: Date, end: Date, isAllDay: Bool,
                timeZone: TimeZone?, url: URL?, notes: String, location: String? = nil,
                isOutOfOffice: Bool = false) {
        self.marker = marker
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.url = url
        self.notes = notes
        self.location = location
        self.isOutOfOffice = isOutOfOffice
    }
}

/// A copy that already exists in the target calendar, or a Busy event in a secondary calendar.
public struct ExistingCopy: Hashable, Sendable {
    /// `EKEvent.eventIdentifier`, used to update or delete it.
    public var eventID: String
    /// Nil for a Busy event, unless an older version made it.
    public var marker: CopyMarker?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var url: URL?
    public var notes: String
    public var location: String?

    public init(eventID: String, marker: CopyMarker?, title: String, start: Date, end: Date,
                isAllDay: Bool, url: URL?, notes: String, location: String? = nil) {
        self.eventID = eventID
        self.marker = marker
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.url = url
        self.notes = notes
        self.location = location
    }
}

/// The result of reading one source.
public enum SourceFetchResult: Sendable {
    case success([SourceEvent])
    /// The source couldn't be read (signed out, network, permission). Copies from it are
    /// left untouched rather than deleted.
    case failure(String)
}
