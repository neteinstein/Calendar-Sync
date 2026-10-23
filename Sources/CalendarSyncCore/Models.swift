import Foundation

/// Where a source calendar's events come from.
public enum SourceKind: Codable, Hashable, Sendable {
    /// A calendar Calendar.app already knows about (Google, Exchange, iCloud, or a
    /// subscribed calendar link). Identified by `EKCalendar.calendarIdentifier`.
    case eventKit(calendarID: String)
    /// A client's Outlook / Microsoft 365 calendar read through the built-in browser window.
    case outlookWeb
}

/// One client calendar the user wants copied into the target calendar.
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

    public init(
        id: UUID = UUID(),
        kind: SourceKind,
        calendarName: String,
        hideMeetingName: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.calendarName = calendarName
        self.hideMeetingName = hideMeetingName
        self.isEnabled = isEnabled
    }
}

/// Settings that apply to every source.
public struct SyncOptions: Codable, Hashable, Sendable {
    public var daysAhead: Int
    public var skipDeclined: Bool
    public var skipAllDay: Bool

    public init(daysAhead: Int = 5, skipDeclined: Bool = true, skipAllDay: Bool = false) {
        self.daysAhead = daysAhead
        self.skipDeclined = skipDeclined
        self.skipAllDay = skipAllDay
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
    public var meetingURL: URL?
    /// Notes of the source event, used only to recognise events this app created
    /// (so two-way syncing doesn't loop).
    public var notes: String?

    public init(
        key: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        timeZone: TimeZone? = nil,
        isDeclined: Bool = false,
        isCancelled: Bool = false,
        meetingURL: URL? = nil,
        notes: String? = nil
    ) {
        self.key = key
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.isDeclined = isDeclined
        self.isCancelled = isCancelled
        self.meetingURL = meetingURL
        self.notes = notes
    }
}

/// What a copy in the target calendar should look like.
public struct CopySpec: Hashable, Sendable {
    public var marker: CopyMarker
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: TimeZone?
    public var url: URL?
    public var notes: String

    public init(marker: CopyMarker, title: String, start: Date, end: Date, isAllDay: Bool,
                timeZone: TimeZone?, url: URL?, notes: String) {
        self.marker = marker
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.url = url
        self.notes = notes
    }
}

/// A copy that already exists in the target calendar.
public struct ExistingCopy: Hashable, Sendable {
    /// `EKEvent.eventIdentifier`, used to update or delete it.
    public var eventID: String
    public var marker: CopyMarker
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var url: URL?
    public var notes: String

    public init(eventID: String, marker: CopyMarker, title: String, start: Date, end: Date,
                isAllDay: Bool, url: URL?, notes: String) {
        self.eventID = eventID
        self.marker = marker
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.url = url
        self.notes = notes
    }
}

/// The result of reading one source.
public enum SourceFetchResult: Sendable {
    case success([SourceEvent])
    /// The source couldn't be read (signed out, network, permission). Copies from it are
    /// left untouched rather than deleted.
    case failure(String)
}
