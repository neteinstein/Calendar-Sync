import XCTest
@testable import CalendarSyncCore

final class BusyPlannerTests: XCTestCase {
    let secondaryA = SourceConfig(kind: .eventKit(calendarID: "secondary-a"), calendarName: "Calendar A", showBusyInSecondary: true)
    let secondaryB = SourceConfig(kind: .eventKit(calendarID: "secondary-b"), calendarName: "Calendar B")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, notes: String? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600,
                    meetingURL: URL(string: "https://zoom.us/j/1"), notes: notes)
    }

    /// A main-calendar event that is itself a copy made from `source`.
    func copyOf(_ source: SourceConfig, key: String, at hour: Double) -> SourceEvent {
        event("main-\(key)", "[\(source.calendarName)] Meeting", at: hour,
              notes: "Copied by Calendar Sync.\n\n" + CopyMarker(sourceID: source.id, key: key).encoded)
    }

    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "busy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes)
        }
    }

    func testBusyEventsCarryNoDetails() {
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Busy")
        XCTAssertNil(spec.url)
        XCTAssertNil(spec.location)
        XCTAssertEqual(spec.notes, "Busy", "the description is just Busy")
        XCTAssertNil(spec.marker, "no hidden marker")
        XCTAssertNil(CopyMarker.find(in: spec.notes))
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("calsync"))
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("Calendar Sync"))
        XCTAssertEqual(spec.start, base + 2 * 3600)
    }

    func testOutOfOfficeStyleCarriesNoDetailsEither() {
        var secondary = secondaryA
        secondary.busyStyle = .outOfOffice
        let plan = SyncPlanner.planBusy(for: secondary, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
        XCTAssertTrue(spec.isOutOfOffice)
        XCTAssertNil(spec.url)
        XCTAssertEqual(spec.notes, "Busy")
        XCTAssertNil(spec.marker)
    }

    func testAllDayEventsStayAllDayAndTimedOnesKeepTheirZone() {
        var holiday = event("h", "Holiday", at: 0)
        holiday.isAllDay = true
        holiday.timeZone = TimeZone(identifier: "Europe/Lisbon")
        var call = event("c", "Call", at: 4)
        call.timeZone = TimeZone(identifier: "America/New_York")
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([holiday, call]), existing: [], options: SyncOptions())
        let specs = plan.actions.compactMap { if case .create(let s) = $0 { s } else { nil } }
        XCTAssertEqual(specs.map(\.isAllDay), [true, false])
        XCTAssertNil(specs[0].timeZone, "all-day events are floating")
        XCTAssertEqual(specs[1].timeZone?.identifier, "America/New_York")
    }

    func testSwitchingStyleUpdatesExistingCopies() {
        let main = [event("m1", "A", at: 1)]
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        var secondary = secondaryA
        secondary.busyStyle = .outOfOffice
        let switched = SyncPlanner.planBusy(for: secondary, mainEvents: .success(main),
                                            existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(switched.updates, 1, "the same event is kept, only the title changes")
        XCTAssertEqual(switched.creates, 0)
        XCTAssertEqual(switched.deletes, 0)
        guard case .update(_, let spec) = switched.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
    }

    func testSkipsCopiesOfTheSameCalendarButShowsOtherSecondaryCalendars() {
        let main = [copyOf(secondaryA, key: "a1", at: 1), copyOf(secondaryB, key: "b1", at: 3), event("own", "Dentist", at: 5)]
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let starts = plan.actions.compactMap { if case .create(let s) = $0 { s.start } else { nil } }
        XCTAssertEqual(starts, [base + 3 * 3600, base + 5 * 3600])
    }

    func testBusyEventsAreNeverCopiedBackIntoMain() {
        var ooo = secondaryA
        ooo.busyStyle = .outOfOffice
        for secondary in [secondaryA, ooo] {
            let plan = SyncPlanner.planBusy(for: secondary, mainEvents: .success([event("m1", "Dentist", at: 2)]),
                                            existing: [], options: SyncOptions(skipOutOfOffice: false))
            guard case .create(let busy) = plan.actions[0] else { return XCTFail() }
            // The secondary calendar now holds the Busy event; syncing that calendar into main must skip it,
            // also when the server hands the description back as HTML.
            let secondaryEvents = [event("busy-event", busy.title, at: 2, notes: busy.notes),
                                event("busy-html", busy.title, at: 3, notes: "<p>\(busy.notes)</p>\r\n")]
            let forward = SyncPlanner.plan(sources: [(secondary, .success(secondaryEvents))], existing: [],
                                           options: SyncOptions(skipOutOfOffice: false))
            XCTAssertTrue(forward.isEmpty)
        }
    }

    func testRecognisesBusyEvents() {
        XCTAssertTrue(CopyFormatter.isBusyEvent(title: "Busy", notes: "Busy"))
        XCTAssertTrue(CopyFormatter.isBusyEvent(title: "Out of office", notes: "Busy\n"))
        XCTAssertTrue(CopyFormatter.isBusyEvent(title: "Busy", notes: "<html><body><p>Busy</p></body></html>"))
        // Made by an older version, with a hidden marker.
        let legacy = CopyMarker(sourceID: secondaryA.id, key: "busy-1a2b").encoded
        XCTAssertTrue(CopyFormatter.isBusyEvent(title: "Busy", notes: legacy))
        // The secondary calendar's own events.
        XCTAssertFalse(CopyFormatter.isBusyEvent(title: "Busy", notes: nil))
        XCTAssertFalse(CopyFormatter.isBusyEvent(title: "Busy", notes: "Busy with the release"))
        XCTAssertFalse(CopyFormatter.isBusyEvent(title: "Focus time", notes: "Busy"))
        // A copy in the main calendar isn't a Busy event.
        let copy = "Copied by Calendar Sync.\n\n" + CopyMarker(sourceID: secondaryA.id, key: "m1").encoded
        XCTAssertFalse(CopyFormatter.isBusyEvent(title: "Busy", notes: copy))
    }

    func testOneBusyEventPerTime() {
        let main = [event("m1", "A", at: 1), event("m2", "B", at: 1), event("m3", "C", at: 2)]
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 2)
        // A duplicate already in the secondary calendar is removed.
        var existing = copies(from: plan)
        existing.append(ExistingCopy(eventID: "dupe", marker: nil, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                     isAllDay: false, url: nil, notes: "Busy"))
        let next = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: existing, options: SyncOptions())
        XCTAssertEqual(next.actions.count, 1)
        XCTAssertEqual(next.deletes, 1)
        XCTAssertEqual(next.unchangedCount, 2)
    }

    func testBusyEventsFromOlderVersionsLoseTheirMarker() {
        let marker = CopyMarker(sourceID: secondaryA.id, key: "busy-1a2b")
        let legacy = ExistingCopy(eventID: "old", marker: marker, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                  isAllDay: false, url: nil, notes: marker.encoded)
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1)]),
                                        existing: [legacy], options: SyncOptions())
        XCTAssertEqual(plan.actions.count, 1)
        guard case .update(let id, let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(id, "old")
        XCTAssertEqual(spec.notes, "Busy")
    }

    func testHTMLDescriptionIsNotRewrittenEverySync() {
        let stored = ExistingCopy(eventID: "e", marker: nil, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                  isAllDay: false, url: nil, notes: "<p>Busy</p>")
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1)]),
                                        existing: [stored], options: SyncOptions())
        XCTAssertTrue(plan.isEmpty)
    }

    func testSecondRunIsNoOpAndChangesFollow() {
        let main = [event("m1", "A", at: 1), event("m2", "B", at: 3)]
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let existing = copies(from: first)
        XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: existing, options: SyncOptions()).isEmpty)

        // Busy events are matched by time: a moved meeting's Busy event is replaced.
        let moved = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 6)]),
                                         existing: existing, options: SyncOptions())
        XCTAssertEqual(moved.creates, 1)
        XCTAssertEqual(moved.deletes, 2)
        XCTAssertEqual(moved.updates, 0)
    }

    func testFailureLeavesBusyEventsAlone() {
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1)]),
                                         existing: [], options: SyncOptions())
        let next = SyncPlanner.planBusy(for: secondaryA, mainEvents: .failure("Main calendar not found"),
                                        existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(next.failedSources[secondaryA.id], "Main calendar not found")
    }

    func testTurningBusyOffTakesBackBusyEvents() {
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1), event("m2", "B", at: 3)]),
                                         existing: [], options: SyncOptions())
        var existing = copies(from: first)
        let marker = CopyMarker(sourceID: secondaryA.id, key: "busy-1a2b")
        existing.append(ExistingCopy(eventID: "legacy", marker: marker, title: "Busy", start: base, end: base + 3600,
                                     isAllDay: false, url: nil, notes: marker.encoded))

        let plan = SyncPlanner.planBusyRemoval(existing: existing, addedHere: true)
        let deleted = plan.actions.compactMap { if case .delete(let id, _, _) = $0 { id } else { nil } }
        XCTAssertEqual(Set(deleted), ["busy-0", "busy-1", "legacy"])
        XCTAssertTrue(SyncPlanner.planBusyRemoval(existing: [], addedHere: true).isEmpty)

        // In a calendar no Busy events were added to, look-alikes are the user's own: only the
        // ones an older version marked are taken back.
        let untouched = SyncPlanner.planBusyRemoval(existing: existing, addedHere: false)
        XCTAssertEqual(untouched.actions.compactMap { if case .delete(let id, _, _) = $0 { id } else { nil } }, ["legacy"])
    }

    func testFiltersFollowOptions() {
        var declined = event("d", "Declined", at: 1); declined.isDeclined = true
        var allDay = event("a", "Holiday", at: 2); allDay.isAllDay = true
        var cancelled = event("c", "Cancelled", at: 3); cancelled.isCancelled = true
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([declined, allDay, cancelled]),
                                        existing: [], options: SyncOptions(skipDeclined: true, skipAllDay: true))
        XCTAssertTrue(plan.isEmpty)
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"Calendar B","hideMeetingName":true,"isEnabled":true}"#
        let decoded = try JSONDecoder().decode(SourceConfig.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.showBusyInSecondary)
        XCTAssertEqual(decoded.busyStyle, .busy)
        XCTAssertTrue(decoded.hideMeetingName)
        var ooo = secondaryA
        ooo.busyStyle = .outOfOffice
        let roundTrip = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(ooo))
        XCTAssertEqual(roundTrip, ooo)
    }

    func testShowBusyKeepsItsSavedKey() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"Calendar B","showBusyInClient":true}"#
        XCTAssertTrue(try JSONDecoder().decode(SourceConfig.self, from: Data(saved.utf8)).showBusyInSecondary)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(secondaryA)) as? [String: Any]
        XCTAssertEqual(encoded?["showBusyInClient"] as? Bool, true)
    }
}
