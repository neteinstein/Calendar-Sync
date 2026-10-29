import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = name.isEmpty ? "Busy" : name
        return calendar.isEmpty ? meeting : "[\(calendar)] \(meeting)"
    }

    /// The meeting link (if any) goes first so it's visible and clickable in Calendar, then the
    /// meeting's description when the source copies details; the hidden marker goes last.
    public static func notes(meetingURL: URL?, details: String? = nil, marker: CopyMarker) -> String {
        var lines: [String] = []
        if let meetingURL { lines.append("Join: \(meetingURL.absoluteString)") }
        if let details, !details.isEmpty { lines.append(details) }
        lines.append("Copied by Calendar Sync. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
    }

    /// Longest description copied into a copy's notes.
    static let maxDetailsLength = 8000

    /// The description and location to copy, or nil for both when the source doesn't copy
    /// details (or hides meeting names, which would make the details give it away).
    static func details(for event: SourceEvent, source: SourceConfig) -> (notes: String?, location: String?) {
        guard source.copyDetails, !source.hideMeetingName else { return (nil, nil) }
        var notes = event.notes.map(HTMLText.normalize)
        if let text = notes, text.count > maxDetailsLength {
            notes = HTMLText.normalize(String(text.prefix(maxDetailsLength))) + "…"
        }
        let location = event.location.map(HTMLText.normalize)
        return (notes?.isEmpty == false ? notes : nil, location?.isEmpty == false ? location : nil)
    }

    /// A main-calendar event shown in a secondary calendar: the time and "Busy" (or "Out of
    /// office"), nothing else. The description says "Busy" too, and there is no hidden marker,
    /// so nothing in the secondary calendar points back to the original event or to this app.
    public static func busySpec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        CopySpec(
            marker: nil,
            title: source.busyStyle.title,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: nil,
            notes: busyNotes,
            isOutOfOffice: source.busyStyle == .outOfOffice
        )
    }

    /// The whole description of every Busy event. It's how they are told apart from the
    /// secondary calendar's own events.
    public static let busyNotes = "Busy"

    /// Whether an event in a secondary calendar is a Busy event: titled like one with "Busy" as
    /// its description, or carrying the hidden marker older versions gave them.
    public static func isBusyEvent(title: String?, notes: String?) -> Bool {
        if let marker = CopyMarker.find(in: notes) { return marker.key.hasPrefix(busyKeyPrefix) }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Calendar servers can hand the description back as HTML.
        return BusyStyle.allCases.contains { $0.title == title }
            && HTMLText.plainText(from: notes ?? "") == busyNotes
    }

    /// Starts the marker key of the Busy events older versions made.
    static let busyKeyPrefix = "busy-"

    public static func spec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = CopyMarker(sourceID: source.id, key: event.key)
        let details = details(for: event, source: source)
        return CopySpec(
            marker: marker,
            title: title(for: event, source: source),
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: event.meetingURL,
            notes: notes(meetingURL: event.meetingURL, details: details.notes, marker: marker),
            location: details.location
        )
    }
}
