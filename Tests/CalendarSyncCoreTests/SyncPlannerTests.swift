import XCTest
@testable import CalendarSyncCore

final class SyncPlannerTests: XCTestCase {
    let source = SourceConfig(kind: .eventKit(calendarID: "client-cal"), calendarName: "Calendar A")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, url: URL? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600, meetingURL: url)
    }

    /// Simulates applying a plan, so tests can check the second run does nothing.
    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "copy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes)
        }
    }

    func testCreatesCopiesWithCalendarPrefixAndMeetingLink() {
        let link = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        let plan = SyncPlanner.plan(
            sources: [(source, .success([event("1", "Sprint planning", at: 1, url: link)]))],
            existing: [], options: SyncOptions())

        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "[Calendar A] Sprint planning")
        XCTAssertEqual(spec.url, link)
        XCTAssertTrue(spec.notes.hasPrefix("Join: https://teams.microsoft.com/l/meetup-join/abc"))
        XCTAssertEqual(CopyMarker.find(in: spec.notes), CopyMarker(sourceID: source.id, key: "1"))
    }

    func testHideMeetingNameKeepsLink() {
        var hidden = source
        hidden.hideMeetingName = true
        let link = URL(string: "https://zoom.us/j/123")!
        let plan = SyncPlanner.plan(
            sources: [(hidden, .success([event("1", "Secret project", at: 1, url: link)]))],
            existing: [], options: SyncOptions())
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "[Calendar A] Busy")
        XCTAssertEqual(spec.url, link)
        XCTAssertFalse(spec.notes.contains("Secret"))
    }

    func testSecondRunIsNoOp() {
        let events = [event("1", "A", at: 1), event("2", "B", at: 3)]
        let first = SyncPlanner.plan(sources: [(source, .success(events))], existing: [], options: SyncOptions())
        let second = SyncPlanner.plan(sources: [(source, .success(events))], existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(second.unchangedCount, 2)
    }

    func testMovedMeetingIsUpdatedNotDuplicated() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))], existing: [], options: SyncOptions())
        let moved = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 5)]))],
                                     existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(moved.updates, 1)
        XCTAssertEqual(moved.creates, 0)
        XCTAssertEqual(moved.deletes, 0)
    }

    func testRemovedMeetingIsDeleted() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1), event("2", "B", at: 2)]))],
                                     existing: [], options: SyncOptions())
        let next = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))],
                                    existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(next.deletes, 1)
        XCTAssertEqual(next.unchangedCount, 1)
    }

    func testFailedSourceKeepsItsCopies() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))], existing: [], options: SyncOptions())
        let next = SyncPlanner.plan(sources: [(source, .failure("Signed out"))],
                                    existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(next.failedSources[source.id], "Signed out")
    }

    func testCopiesOfOtherSourcesAreUntouched() {
        let other = SourceConfig(kind: .outlookWeb, calendarName: "Calendar B")
        let first = SyncPlanner.plan(sources: [(other, .success([event("1", "A", at: 1)]))], existing: [], options: SyncOptions())
        let next = SyncPlanner.plan(sources: [(source, .success([]))], existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
    }

    func testFilters() {
        var declined = event("d", "Declined", at: 1); declined.isDeclined = true
        var cancelled = event("c", "Cancelled", at: 2); cancelled.isCancelled = true
        var allDay = event("a", "Holiday", at: 3); allDay.isAllDay = true
        var ourCopy = event("x", "[Calendar B] Loop", at: 4)
        ourCopy.notes = "Copied\n\n" + CopyMarker(sourceID: UUID(), key: "k").encoded
        let events = [declined, cancelled, allDay, ourCopy, event("ok", "Fine", at: 5)]

        let skipAll = SyncPlanner.plan(sources: [(source, .success(events))], existing: [],
                                       options: SyncOptions(skipDeclined: true, skipAllDay: true))
        XCTAssertEqual(skipAll.creates, 1)

        let keep = SyncPlanner.plan(sources: [(source, .success(events))], existing: [],
                                    options: SyncOptions(skipDeclined: false, skipAllDay: false))
        XCTAssertEqual(keep.creates, 3) // declined + all-day + ok; never cancelled or our own copies
    }

    func testDuplicateCopiesAreCleanedUp() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))], existing: [], options: SyncOptions())
        var dupes = copies(from: first)
        dupes.append(ExistingCopy(eventID: "dupe", marker: dupes[0].marker, title: dupes[0].title, start: dupes[0].start,
                                  end: dupes[0].end, isAllDay: false, url: nil, notes: dupes[0].notes))
        let next = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))], existing: dupes, options: SyncOptions())
        XCTAssertEqual(next.deletes, 1)
        XCTAssertEqual(next.unchangedCount, 1)
    }

    func testEmptyCalendarNameHasNoBrackets() {
        var noName = source
        noName.calendarName = "  "
        XCTAssertEqual(CopyFormatter.title(for: event("1", "Standup", at: 1), source: noName), "Standup")
    }
}

final class CopyMarkerTests: XCTestCase {
    func testRoundTripWithAwkwardKey() {
        let marker = CopyMarker(sourceID: UUID(), key: "AAMkAD/x+y==|2026-10-23T09:00:00Z with space")
        let notes = "Join: https://zoom.us/j/1\n\nsome text\n\n" + marker.encoded
        XCTAssertEqual(CopyMarker.find(in: notes), marker)
    }

    func testNoMarker() {
        XCTAssertNil(CopyMarker.find(in: "Just a normal meeting"))
        XCTAssertNil(CopyMarker.find(in: nil))
        XCTAssertNil(CopyMarker.find(in: "calsync:v1:not-a-uuid:key"))
    }
}

final class MeetingLinkTests: XCTestCase {
    func testFindsLinksInLocationAndNotes() {
        XCTAssertEqual(
            MeetingLink.find(url: nil, location: "Microsoft Teams Meeting", notes: """
                Agenda: https://docs.example.com/agenda
                Join the meeting now <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x>
                """)?.absoluteString,
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x")
        XCTAssertEqual(MeetingLink.find(url: nil, location: "https://acme.zoom.us/j/987654321?pwd=abc.", notes: nil)?.absoluteString,
                       "https://acme.zoom.us/j/987654321?pwd=abc")
        XCTAssertEqual(MeetingLink.find(url: nil, location: nil, notes: "meet.google.com: https://meet.google.com/abc-defg-hij")?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
    }

    func testIgnoresNonMeetingLinks() {
        XCTAssertNil(MeetingLink.find(url: URL(string: "https://example.com/doc"), location: "Room 4", notes: "See https://jira.example.com/X-1"))
    }

    func testEventURLWins() {
        let url = URL(string: "https://company.webex.com/meet/someone")!
        XCTAssertEqual(MeetingLink.find(url: url, location: "https://zoom.us/j/1", notes: nil), url)
    }
}
