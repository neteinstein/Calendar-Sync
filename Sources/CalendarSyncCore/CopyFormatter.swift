import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = name.isEmpty ? "Busy" : name
        return calendar.isEmpty ? meeting : "[\(calendar)] \(meeting)"
    }

    /// The meeting link (if any) goes first so it's visible and clickable in Calendar;
    /// the hidden marker goes last.
    public static func notes(meetingURL: URL?, marker: CopyMarker) -> String {
        var lines: [String] = []
        if let meetingURL { lines.append("Join: \(meetingURL.absoluteString)") }
        lines.append("Copied by Calendar Sync. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
    }

    public static func spec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = CopyMarker(sourceID: source.id, key: event.key)
        return CopySpec(
            marker: marker,
            title: title(for: event, source: source),
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: event.meetingURL,
            notes: notes(meetingURL: event.meetingURL, marker: marker)
        )
    }
}
