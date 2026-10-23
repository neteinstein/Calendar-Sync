import XCTest
@testable import CalendarSyncCore

final class OutlookWebParserTests: XCTestCase {
    func testOWAServiceShape() throws {
        let json = """
        {"Body":{"ResponseClass":"Success","Items":[
          {"__type":"CalendarItem:#Exchange","ItemId":{"Id":"AAMk1","ChangeKey":"x"},
           "Subject":"Sprint planning","Start":"2026-10-23T09:00:00+01:00","End":"2026-10-23T10:00:00+01:00",
           "IsAllDayEvent":false,"IsCancelled":false,"ResponseType":"Accept",
           "Location":{"DisplayName":"Microsoft Teams Meeting"},
           "Preview":"Join: https://teams.microsoft.com/l/meetup-join/19%3aabc/0?context=1"},
          {"ItemId":{"Id":"AAMk2"},"Subject":"Optional sync","Start":"2026-10-23T11:00:00Z","End":"2026-10-23T11:30:00Z",
           "ResponseType":"Decline"},
          {"ItemId":{"Id":"AAMk3"},"Subject":"Old","Start":"2026-10-23T12:00:00Z","End":"2026-10-23T12:30:00Z",
           "IsCancelled":true}
        ]}}
        """
        let events = OutlookWebParser.events(fromPayloads: [Data(json.utf8)])
        XCTAssertEqual(events.count, 3)

        let first = events[0]
        XCTAssertEqual(first.key, "AAMk1")
        XCTAssertEqual(first.title, "Sprint planning")
        XCTAssertEqual(first.start, ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
        XCTAssertEqual(first.meetingURL?.host, "teams.microsoft.com")
        XCTAssertFalse(first.isDeclined)

        XCTAssertTrue(events[1].isDeclined)
        XCTAssertTrue(events[2].isCancelled)
    }

    func testGraphShapeWithWindowsTimeZoneAndSeriesKey() throws {
        let json = """
        {"value":[{"id":"occ-1","subject":"Standup","type":"occurrence",
          "seriesMasterId":"master-9","originalStart":"2026-10-26T09:30:00Z",
          "start":{"dateTime":"2026-10-27T09:30:00.0000000","timeZone":"GMT Standard Time"},
          "end":{"dateTime":"2026-10-27T09:45:00.0000000","timeZone":"GMT Standard Time"},
          "isAllDay":false,"isCancelled":false,"responseStatus":{"response":"accepted"},
          "onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/xyz"},
          "location":{"displayName":""}}]}
        """
        let events = OutlookWebParser.events(fromPayloads: [Data(json.utf8)])
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.key, "series:master-9|2026-10-26T09:30:00Z")
        // 27 Oct 2026 is after the UK clocks change, so GMT == UTC.
        XCTAssertEqual(e.start, ISO8601DateFormatter().date(from: "2026-10-27T09:30:00Z"))
        XCTAssertEqual(e.meetingURL?.absoluteString, "https://teams.microsoft.com/l/meetup-join/xyz")
    }

    func testIgnoresNonEventsAndDuplicates() {
        let a = #"{"Items":[{"ItemId":{"Id":"1"},"Subject":"A","Start":"2026-10-23T09:00:00Z","End":"2026-10-23T10:00:00Z"}]}"#
        let noise = #"{"Folders":[{"DisplayName":"Calendar","Id":"f1"}],"start":"x"}"#
        let events = OutlookWebParser.events(fromPayloads: [Data(a.utf8), Data(noise.utf8), Data(a.utf8), Data("not json".utf8)])
        XCTAssertEqual(events.map(\.key), ["1"])
    }

    func testDaylightSavingLocalTime() {
        // 23 Oct 2026 is still British Summer Time (UTC+1).
        let date = OutlookWebParser.parseDate("2026-10-23T09:00:00", zone: "GMT Standard Time")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-10-23T08:00:00Z"))
    }
}
