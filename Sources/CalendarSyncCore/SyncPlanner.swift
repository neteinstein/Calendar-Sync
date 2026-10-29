import Foundation

/// One change to make in the target calendar.
public enum SyncAction: Hashable, Sendable {
    case create(CopySpec)
    case update(eventID: String, CopySpec)
    case delete(eventID: String, title: String, start: Date)
}

public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    /// Sources that couldn't be read this run, with the reason. Their copies are untouched.
    public var failedSources: [UUID: String]
    public var unchangedCount: Int

    public var creates: Int { actions.filter { if case .create = $0 { true } else { false } }.count }
    public var updates: Int { actions.filter { if case .update = $0 { true } else { false } }.count }
    public var deletes: Int { actions.filter { if case .delete = $0 { true } else { false } }.count }
    public var isEmpty: Bool { actions.isEmpty }
}

/// Decides what to create, update and delete. Pure logic, no calendar access, so it can be
/// unit tested and used for the dry-run preview.
public enum SyncPlanner {
    /// - Parameters:
    ///   - sources: every configured source with the result of reading it for the sync window.
    ///   - existing: copies currently in the target calendar for the same window (anything
    ///     carrying a marker).
    ///   - calendar: whose days all-day events are compared by.
    public static func plan(
        sources: [(config: SourceConfig, result: SourceFetchResult)],
        existing: [ExistingCopy],
        options: SyncOptions,
        calendar: Calendar = .current
    ) -> SyncPlan {
        var desired: [CopyMarker: CopySpec] = [:]
        var desiredOrder: [CopyMarker] = []
        var syncedSourceIDs: Set<UUID> = []
        var failed: [UUID: String] = [:]

        for (config, result) in sources where config.isEnabled {
            switch result {
            case .failure(let reason):
                failed[config.id] = reason
            case .success(let events):
                syncedSourceIDs.insert(config.id)
                for event in events where shouldCopy(event, options: options) {
                    let spec = CopyFormatter.spec(for: event, source: config)
                    if let marker = spec.marker, desired[marker] == nil {
                        desired[marker] = spec
                        desiredOrder.append(marker)
                    }
                }
            }
        }

        let (actions, unchanged) = diff(desired: desired, order: desiredOrder, existing: existing,
                                        owners: syncedSourceIDs, calendar: calendar)
        return SyncPlan(actions: actions, failedSources: failed, unchangedCount: unchanged)
    }

    /// Plans the "Busy" events that show the main calendar inside one secondary calendar.
    ///
    /// Busy events carry nothing but their times, so they're matched to the main calendar by
    /// time: one per distinct time, and a meeting that moves gets its Busy event removed and
    /// another added at the new time.
    ///
    /// - Parameters:
    ///   - source: the secondary calendar to write into.
    ///   - mainEvents: the main calendar's events for the sync window.
    ///   - existing: the Busy events currently in the secondary calendar.
    ///   - calendar: whose days all-day events are compared by.
    public static func planBusy(
        for source: SourceConfig,
        mainEvents: SourceFetchResult,
        existing: [ExistingCopy],
        options: SyncOptions,
        calendar: Calendar = .current
    ) -> SyncPlan {
        let events: [SourceEvent]
        switch mainEvents {
        case .failure(let reason):
            // Leave existing Busy events alone rather than deleting them.
            return SyncPlan(actions: [], failedSources: [source.id: reason], unchangedCount: 0)
        case .success(let list):
            events = list
        }

        var desired: [CopySpec] = []
        for event in events where shouldShowBusy(event, in: source, options: options) {
            let spec = CopyFormatter.busySpec(for: event, source: source)
            if !desired.contains(where: { $0.start == spec.start && $0.end == spec.end && $0.isAllDay == spec.isAllDay }) {
                desired.append(spec)
            }
        }
        desired.sort { $0.start < $1.start }

        var actions: [SyncAction] = []
        var unchanged = 0
        for busy in existing.sorted(by: { $0.start < $1.start }) {
            guard let index = desired.firstIndex(where: {
                $0.isAllDay == busy.isAllDay && sameTimes(busy, $0, calendar: calendar)
            }) else {
                // Nothing in the main calendar at that time any more, or a duplicate.
                actions.append(.delete(eventID: busy.eventID, title: busy.title, start: busy.start))
                continue
            }
            let spec = desired.remove(at: index)
            if needsBusyUpdate(busy, to: spec) {
                actions.append(.update(eventID: busy.eventID, spec))
            } else {
                unchanged += 1
            }
        }
        actions += desired.map { .create($0) }
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: unchanged)
    }

    /// Takes back the Busy events in a secondary calendar that no longer asks for them. Left
    /// there, they'd go on showing the main calendar as it was when they were last updated.
    ///
    /// - Parameter addedHere: whether Busy events were added to this calendar since they stopped
    ///   carrying a marker. If not, only the ones with a marker are taken back, so an event the
    ///   user made that just looks like a Busy event is left alone.
    public static func planBusyRemoval(existing: [ExistingCopy], addedHere: Bool) -> SyncPlan {
        let actions = existing
            .filter { addedHere || $0.marker != nil }
            .sorted { $0.start < $1.start }
            .map { SyncAction.delete(eventID: $0.eventID, title: $0.title, start: $0.start) }
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: 0)
    }

    /// For a Busy event already matched by time. The description is compared as text, so one
    /// a calendar server stored as HTML isn't rewritten on every sync, while the marker of a
    /// Busy event made by an older version is replaced.
    static func needsBusyUpdate(_ busy: ExistingCopy, to spec: CopySpec) -> Bool {
        busy.title != spec.title
            || HTMLText.plainText(from: busy.notes) != spec.notes
            || busy.url != nil
            || !(busy.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldShowBusy(_ event: SourceEvent, in source: SourceConfig, options: SyncOptions) -> Bool {
        if event.isCancelled { return false }
        if options.skipDeclined && event.isDeclined { return false }
        if options.skipAllDay && event.isAllDay { return false }
        // Copies of this calendar's own meetings are already in its calendar. Copies from other
        // secondary calendars are shown, so each one sees time booked by the others.
        if CopyMarker.find(in: event.notes)?.sourceID == source.id { return false }
        return event.end >= event.start
    }

    /// Matches desired copies against existing ones. Only copies owned by `owners` are
    /// touched, so copies of sources that failed, are disabled or were removed stay as they are.
    static func diff(
        desired: [CopyMarker: CopySpec],
        order: [CopyMarker],
        existing: [ExistingCopy],
        owners: Set<UUID>,
        calendar: Calendar
    ) -> ([SyncAction], Int) {
        var actions: [SyncAction] = []
        var matched: Set<CopyMarker> = []
        var unchanged = 0

        for copy in existing.sorted(by: { $0.start < $1.start }) {
            guard let marker = copy.marker, owners.contains(marker.sourceID) else { continue }

            guard let spec = desired[marker], !matched.contains(marker) else {
                // Source occurrence is gone (cancelled, declined, deleted) or this is a duplicate.
                actions.append(.delete(eventID: copy.eventID, title: copy.title, start: copy.start))
                continue
            }
            matched.insert(marker)
            if needsUpdate(copy, to: spec, calendar: calendar) {
                actions.append(.update(eventID: copy.eventID, spec))
            } else {
                unchanged += 1
            }
        }

        for marker in order where !matched.contains(marker) {
            actions.append(.create(desired[marker]!))
        }
        return (actions, unchanged)
    }

    static func shouldCopy(_ event: SourceEvent, options: SyncOptions) -> Bool {
        if event.isCancelled { return false }
        if options.skipDeclined && event.isDeclined { return false }
        if options.skipAllDay && event.isAllDay { return false }
        if options.skipOutOfOffice && event.isOutOfOffice { return false }
        // Never copy our own copies or Busy events back (two-way setups would loop forever).
        if CopyMarker.isCopy(event.notes) || CopyFormatter.isBusyEvent(title: event.title, notes: event.notes) {
            return false
        }
        return event.end >= event.start
    }

    /// Notes and location are compared after tidying whitespace, since calendar servers
    /// (Exchange, Google) change line endings and spacing when they store them.
    static func needsUpdate(_ copy: ExistingCopy, to spec: CopySpec, calendar: Calendar) -> Bool {
        copy.title != spec.title
            || !sameTimes(copy, spec, calendar: calendar)
            || copy.isAllDay != spec.isAllDay
            || copy.url != spec.url
            || HTMLText.normalize(copy.notes) != HTMLText.normalize(spec.notes)
            || HTMLText.normalize(copy.location ?? "") != HTMLText.normalize(spec.location ?? "")
    }

    /// All-day events are compared by their first and last day: an all-day event's end can
    /// be a second before midnight or midnight itself, depending on who wrote it.
    static func sameTimes(_ copy: ExistingCopy, _ spec: CopySpec, calendar: Calendar) -> Bool {
        if copy.isAllDay && spec.isAllDay {
            return calendar.isDate(copy.start, inSameDayAs: spec.start)
                && calendar.isDate(copy.end - 1, inSameDayAs: spec.end - 1)
        }
        return abs(copy.start.timeIntervalSince(spec.start)) < 1 && abs(copy.end.timeIntervalSince(spec.end)) < 1
    }
}
