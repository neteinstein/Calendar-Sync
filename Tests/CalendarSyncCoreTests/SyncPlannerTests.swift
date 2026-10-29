import XCTest
@testable import CalendarSyncCore

final class SyncPlannerTests: XCTestCase {
    let source = SourceConfig(kind: .eventKit(calendarID: "secondary-cal"), calendarName: "Calendar A")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, url: URL? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600, meetingURL: url)
    }

    /// Simulates applying a plan, so tests can check the second run does nothing.
    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "copy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes, location: s.location)
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

    func testDisabledSourceKeepsItsCopies() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1)]))], existing: [], options: SyncOptions())
        var off = source
        off.isEnabled = false
        let next = SyncPlanner.plan(sources: [(off, .success([]))], existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
        XCTAssertTrue(next.failedSources.isEmpty, "turned off isn't a failure")
    }

    func testCancelledOccurrenceRemovesItsCopy() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1), event("2", "B", at: 2)]))],
                                     existing: [], options: SyncOptions())
        var cancelled = event("2", "Canceled: B", at: 2)
        cancelled.isCancelled = true
        let next = SyncPlanner.plan(sources: [(source, .success([event("1", "A", at: 1), cancelled]))],
                                    existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(next.actions.count, 1)
        guard case .delete(let id, _, _) = next.actions[0] else { return XCTFail() }
        XCTAssertEqual(id, "copy-1")
    }

    func testLongDescriptionsAreCut() {
        var detailed = source
        detailed.copyDetails = true
        var e = event("1", "Review", at: 1)
        e.notes = String(repeating: "word ", count: 3000)
        let details = CopyFormatter.details(for: e, source: detailed)
        XCTAssertLessThanOrEqual(details.notes?.count ?? .max, CopyFormatter.maxDetailsLength + 1)
        XCTAssertEqual(details.notes?.hasSuffix("word…"), true)
        XCTAssertNil(details.location)
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

    func testOutOfOfficeIsSkippedUnlessTurnedOff() {
        var holiday = event("h", "Holiday", at: 1); holiday.isOutOfOffice = true
        let events = [holiday, event("ok", "Fine", at: 2)]
        XCTAssertEqual(SyncPlanner.plan(sources: [(source, .success(events))], existing: [], options: SyncOptions()).creates, 1)
        XCTAssertEqual(SyncPlanner.plan(sources: [(source, .success(events))], existing: [],
                                        options: SyncOptions(skipOutOfOffice: false)).creates, 2)
    }

    func testCopyDetailsAddsLocationAndDescription() {
        var detailed = source
        detailed.copyDetails = true
        var e = event("1", "Review", at: 1, url: URL(string: "https://zoom.us/j/1"))
        e.location = "Room 4.1"
        e.notes = "Agenda:\r\n- demo\u{00A0} \r\n\r\n\r\n\r\nBring laptops"

        let plan = SyncPlanner.plan(sources: [(detailed, .success([e]))], existing: [], options: SyncOptions())
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.location, "Room 4.1")
        XCTAssertTrue(spec.notes.hasPrefix("Join: https://zoom.us/j/1\n\nAgenda:\n- demo\n\nBring laptops\n\nCopied by Calendar Sync."))
        XCTAssertEqual(CopyMarker.find(in: spec.notes)?.key, "1")

        // Off by default, and never while meeting names are hidden.
        guard case .create(let plain) = SyncPlanner.plan(sources: [(source, .success([e]))], existing: [], options: SyncOptions()).actions[0]
        else { return XCTFail() }
        XCTAssertNil(plain.location)
        XCTAssertFalse(plain.notes.contains("Agenda"))
        detailed.hideMeetingName = true
        guard case .create(let hidden) = SyncPlanner.plan(sources: [(detailed, .success([e]))], existing: [], options: SyncOptions()).actions[0]
        else { return XCTFail() }
        XCTAssertNil(hidden.location)
        XCTAssertFalse(hidden.notes.contains("Agenda"))
    }

    func testDetailsSurviveServerWhitespaceChanges() {
        var detailed = source
        detailed.copyDetails = true
        var e = event("1", "Review", at: 1)
        e.location = "Room 4.1"
        e.notes = "Line one\nLine two"
        let first = SyncPlanner.plan(sources: [(detailed, .success([e]))], existing: [], options: SyncOptions())
        // Exchange hands notes back with CRLF and trailing spaces.
        let stored = copies(from: first).map { copy -> ExistingCopy in
            var copy = copy
            copy.notes = copy.notes.replacingOccurrences(of: "\n", with: " \r\n")
            copy.location = "Room 4.1 "
            return copy
        }
        let second = SyncPlanner.plan(sources: [(detailed, .success([e]))], existing: stored, options: SyncOptions())
        XCTAssertTrue(second.isEmpty)

        // Turning details on later updates the existing copies.
        let before = SyncPlanner.plan(sources: [(source, .success([e]))], existing: [], options: SyncOptions())
        let after = SyncPlanner.plan(sources: [(detailed, .success([e]))], existing: copies(from: before), options: SyncOptions())
        XCTAssertEqual(after.updates, 1)
    }

    func testAllDayCopiesAreComparedByDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        var release = SourceEvent(key: "r", title: "Release day", start: day, end: day + 86400 - 1, isAllDay: true)
        func plan(_ existing: [ExistingCopy]) -> SyncPlan {
            SyncPlanner.plan(sources: [(source, .success([release]))], existing: existing, options: SyncOptions(), calendar: utc)
        }
        // The calendar hands the copy back ending at midnight rather than a second before it.
        var stored = copies(from: plan([]))
        stored[0].end = day + 86400
        XCTAssertTrue(plan(stored).isEmpty, "the same day either way, so it isn't rewritten on every sync")

        release.end += 86400
        XCTAssertEqual(plan(stored).updates, 1, "a second day is a change")
        release.start += 86400
        release.end = release.start + 86400 - 1
        XCTAssertEqual(plan(stored).updates, 1, "so is moving to another day")
    }

    func testOptionsSavedByOlderVersionsKeepDefaults() throws {
        let old = #"{"daysAhead":7,"skipDeclined":false,"skipAllDay":true}"#
        let options = try JSONDecoder().decode(SyncOptions.self, from: Data(old.utf8))
        XCTAssertEqual(options, SyncOptions(daysAhead: 7, skipDeclined: false, skipAllDay: true, skipOutOfOffice: true))

        let source = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"A"}"#
        let config = try JSONDecoder().decode(SourceConfig.self, from: Data(source.utf8))
        XCTAssertFalse(config.copyDetails)
        XCTAssertNil(config.intervalMinutes)
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

    func testMarkerEndsWhereItsEncodingEnds() {
        let marker = CopyMarker(sourceID: UUID(), key: "outlook:Réunion d’équipe|2026-10-23T09:00:00Z")
        // Calendar servers can store notes as HTML, or put other text right after the marker.
        for notes in ["<p>\(marker.encoded)</p>", "\(marker.encoded)\"", "x \(marker.encoded)\u{00A0}more", marker.encoded + ")",
                      marker.encoded + "été", marker.encoded + "５"] {
            XCTAssertEqual(CopyMarker.find(in: notes), marker, notes)
        }
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

    func testUnwrapsSafeLinksAndHTML() {
        let html = #"<a href="https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F42%3Fpwd%3Dx&amp;data=05&amp;reserved=0">Join</a>"#
        XCTAssertEqual(MeetingLink.firstMeetingLink(in: html)?.absoluteString, "https://acme.zoom.us/j/42?pwd=x")
        let wrapped = URL(string: "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fmeet.google.com%2Fabc-defg-hij&data=1")
        XCTAssertEqual(MeetingLink.find(url: wrapped, location: nil, notes: nil)?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(MeetingLink.firstMeetingLink(in: "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com"))
    }

    func testEventURLWins() {
        let url = URL(string: "https://company.webex.com/meet/someone")!
        XCTAssertEqual(MeetingLink.find(url: url, location: "https://zoom.us/j/1", notes: nil), url)
    }
}

final class HTMLTextTests: XCTestCase {
    func testPlainText() {
        let html = """
        <html><head><title>x</title></head><body><!-- hidden --><div>Hello&nbsp;<b>there</b> &amp; welcome</div>
        <p>Line&#160;two &#x2014; done</p><br/><br/><br/><ul><li>One</li><li>Two</li></ul><script>alert(1)</script></body></html>
        """
        XCTAssertEqual(HTMLText.plainText(from: html), "Hello there & welcome\nLine two — done\n\nOne\nTwo")
    }
}

final class SyncScheduleTests: XCTestCase {
    func testEachSourceUsesItsOwnInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usual = SourceConfig(kind: .eventKit(calendarID: "a"), calendarName: "A")
        let hourly = SourceConfig(kind: .outlookWeb, calendarName: "B", intervalMinutes: 60)
        let fresh = SourceConfig(kind: .outlookWeb, calendarName: "C", intervalMinutes: 5)
        let off = SourceConfig(kind: .outlookWeb, calendarName: "D", isEnabled: false)
        let sources = [usual, hourly, fresh, off]
        let twentyMinutesAgo = now - 20 * 60
        let lastRead = [usual.id: twentyMinutesAgo, hourly.id: twentyMinutesAgo, off.id: twentyMinutesAgo]

        XCTAssertEqual(SyncSchedule.dueSources(sources, lastRead: lastRead, defaultMinutes: 15, now: now),
                       [usual.id, fresh.id], "15 min passed, 60 min not; never read is due; disabled never is")
        XCTAssertEqual(SyncSchedule.dueSources(sources, lastRead: lastRead, defaultMinutes: 30, now: now), [fresh.id])
        // A tick that lands a few seconds early still counts.
        XCTAssertEqual(SyncSchedule.dueSources([usual], lastRead: [usual.id: now - 14 * 60 - 45], defaultMinutes: 15, now: now),
                       [usual.id])
        XCTAssertEqual(SyncSchedule.interval(for: SourceConfig(kind: .outlookWeb, calendarName: "E", intervalMinutes: 0),
                                             defaultMinutes: 15), 1)
        XCTAssertEqual(SyncSchedule.interval(for: SourceConfig(kind: .outlookWeb, calendarName: "F", intervalMinutes: 100_000),
                                             defaultMinutes: 15), SyncSchedule.maxMinutes)
    }

    func testClockSetBackDoesNotPostponeReads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = SourceConfig(kind: .eventKit(calendarID: "a"), calendarName: "A")
        // Last read "two hours from now": the clock was moved back after it.
        XCTAssertEqual(SyncSchedule.dueSources([source], lastRead: [source.id: now + 2 * 3600], defaultMinutes: 15, now: now),
                       [source.id])
        XCTAssertEqual(SyncSchedule.dueSources([source], lastRead: [source.id: now - 60], defaultMinutes: 15, now: now), [])
    }
}
