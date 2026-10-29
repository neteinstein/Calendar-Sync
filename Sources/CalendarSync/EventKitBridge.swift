import CalendarSyncCore
import EventKit
import Foundation

/// Everything that touches Calendar.app's data goes through here.
@MainActor
final class EventKitBridge {
    let store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// All event calendars, grouped by account then name.
    func calendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
    }

    func calendar(id: String?) -> EKCalendar? {
        id.flatMap { store.calendar(withIdentifier: $0) }
    }

    // MARK: - Reading

    func sourceEvents(calendarID: String, from start: Date, to end: Date) -> SourceFetchResult {
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            return .failure("Calendar not found in Calendar.app")
        }
        // EventKit expands recurring meetings into one EKEvent per occurrence.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return .success(store.events(matching: predicate).compactMap { Self.sourceEvent($0) })
    }

    /// Nil for an event without dates. EventKit declares them as never nil but doesn't
    /// promise it, and reading a missing one would crash the app on every sync.
    static func sourceEvent(_ event: EKEvent) -> SourceEvent? {
        guard let start = event.startDate as Date?, let end = event.endDate as Date? else { return nil }
        let id: String = event.calendarItemIdentifier
        // Occurrences of a recurring meeting share one identifier, so add the original
        // occurrence date (which stays the same when one occurrence is moved).
        let isRecurring = event.hasRecurrenceRules || event.isDetached
        let occurrence: Date = event.occurrenceDate ?? start
        let key = isRecurring ? "\(id)|\(occurrence.ISO8601Format())" : id

        let myStatus = event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus

        return SourceEvent(
            key: key,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            timeZone: event.timeZone,
            isDeclined: myStatus == .declined,
            isCancelled: event.status == .canceled,
            // Exchange's "Out of office" comes through as unavailable.
            isOutOfOffice: event.availability == .unavailable,
            meetingURL: MeetingLink.find(url: event.url, location: event.location, notes: event.notes),
            notes: event.notes,
            location: event.location
        )
    }

    /// Copies this app made in the target calendar (recognised by the marker in their notes).
    func existingCopies(targetID: String, from start: Date, to end: Date) -> [ExistingCopy]? {
        guard let calendar = store.calendar(withIdentifier: targetID) else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).compactMap { event in
            guard let marker = CopyMarker.find(in: event.notes), let eventID = event.eventIdentifier,
                  let start = event.startDate as Date?, let end = event.endDate as Date?
            else { return nil }
            // Exchange and Google may drop the event URL. Read it the way we wrote it, so
            // unchanged copies aren't rewritten on every sync.
            let notes = Self.storedNotes(event)
            return ExistingCopy(
                eventID: eventID,
                marker: marker,
                title: event.title ?? "",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                url: event.url ?? MeetingLink.firstMeetingLink(in: notes),
                notes: notes,
                location: event.location
            )
        }
    }

    /// The Busy events in a secondary calendar (see `CopyFormatter.isBusyEvent`). Ones made by
    /// older versions come with their marker.
    func busyEvents(calendarID: String, from start: Date, to end: Date) -> [ExistingCopy]? {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).compactMap { event in
            // Busy events never have attendees or repeat, so a secondary-calendar meeting that only looks
            // like one is left alone.
            guard !event.hasAttendees, !event.hasRecurrenceRules,
                  CopyFormatter.isBusyEvent(title: event.title, notes: event.notes),
                  let eventID = event.eventIdentifier,
                  let start = event.startDate as Date?, let end = event.endDate as Date?
            else { return nil }
            return ExistingCopy(
                eventID: eventID,
                marker: CopyMarker.find(in: event.notes),
                title: event.title ?? "",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                url: event.url,
                notes: Self.storedNotes(event),
                location: event.location
            )
        }
    }

    /// Exchange and Google may change line endings. Read notes the way we wrote them, so
    /// unchanged events aren't rewritten on every sync.
    private static func storedNotes(_ event: EKEvent) -> String {
        (event.notes ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    /// Applies the plan in one commit. Returns a message per action that failed.
    func apply(_ plan: SyncPlan, targetID: String) -> [String] {
        guard let calendar = store.calendar(withIdentifier: targetID) else {
            return ["Target calendar not found in Calendar.app"]
        }
        guard calendar.allowsContentModifications else {
            return ["“\(calendar.title)” is read-only. Pick a calendar you can edit."]
        }

        var errors: [String] = []
        for action in plan.actions {
            do {
                switch action {
                case .create(let spec):
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    fill(event, with: spec, calendar: calendar)
                    try store.save(event, span: .thisEvent, commit: false)
                case .update(let eventID, let spec):
                    guard let event = store.event(withIdentifier: eventID) else { continue }
                    fill(event, with: spec, calendar: calendar)
                    try store.save(event, span: .thisEvent, commit: false)
                case .delete(let eventID, _, _):
                    guard let event = store.event(withIdentifier: eventID) else { continue }
                    try store.remove(event, span: .thisEvent, commit: false)
                }
            } catch {
                errors.append("\(action.title): \(error.localizedDescription)")
            }
        }

        do {
            try store.commit()
        } catch {
            store.reset()
            errors.append("Saving to Calendar failed: \(error.localizedDescription)")
        }
        return errors
    }

    private func fill(_ event: EKEvent, with spec: CopySpec, calendar: EKCalendar) {
        event.title = spec.title
        event.isAllDay = spec.isAllDay
        if let timeZone = spec.timeZone { event.timeZone = timeZone }
        event.startDate = spec.start
        event.endDate = spec.end
        event.url = spec.url
        event.notes = spec.notes
        event.location = spec.location
        if spec.isOutOfOffice, calendar.supportedEventAvailabilities.contains(.unavailable) {
            event.availability = .unavailable
        } else if calendar.supportedEventAvailabilities.contains(.busy) {
            event.availability = .busy
        }
    }
}

extension SyncAction {
    var title: String {
        switch self {
        case .create(let spec), .update(_, let spec): spec.title
        case .delete(_, let title, _): title
        }
    }

    var start: Date {
        switch self {
        case .create(let spec), .update(_, let spec): spec.start
        case .delete(_, _, let start): start
        }
    }

    var verb: String {
        switch self {
        case .create: "Add"
        case .update: "Update"
        case .delete: "Remove"
        }
    }
}
