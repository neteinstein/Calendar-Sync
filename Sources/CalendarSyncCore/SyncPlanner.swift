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
    public static func plan(
        sources: [(config: SourceConfig, result: SourceFetchResult)],
        existing: [ExistingCopy],
        options: SyncOptions
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
                    if desired[spec.marker] == nil {
                        desired[spec.marker] = spec
                        desiredOrder.append(spec.marker)
                    }
                }
            }
        }

        var actions: [SyncAction] = []
        var matched: Set<CopyMarker> = []
        var unchanged = 0

        for copy in existing.sorted(by: { $0.start < $1.start }) {
            // Only touch copies of sources we read successfully. Copies from sources that
            // failed, are disabled or were removed are left alone.
            guard syncedSourceIDs.contains(copy.marker.sourceID) else { continue }

            guard let spec = desired[copy.marker], !matched.contains(copy.marker) else {
                // Source occurrence is gone (cancelled, declined, deleted) or this is a duplicate.
                actions.append(.delete(eventID: copy.eventID, title: copy.title, start: copy.start))
                continue
            }
            matched.insert(copy.marker)
            if needsUpdate(copy, to: spec) {
                actions.append(.update(eventID: copy.eventID, spec))
            } else {
                unchanged += 1
            }
        }

        for marker in desiredOrder where !matched.contains(marker) {
            actions.append(.create(desired[marker]!))
        }

        return SyncPlan(actions: actions, failedSources: failed, unchangedCount: unchanged)
    }

    static func shouldCopy(_ event: SourceEvent, options: SyncOptions) -> Bool {
        if event.isCancelled { return false }
        if options.skipDeclined && event.isDeclined { return false }
        if options.skipAllDay && event.isAllDay { return false }
        // Never copy our own copies back (two-way setups would loop forever).
        if CopyMarker.isCopy(event.notes) { return false }
        return event.end >= event.start
    }

    static func needsUpdate(_ copy: ExistingCopy, to spec: CopySpec) -> Bool {
        copy.title != spec.title
            || abs(copy.start.timeIntervalSince(spec.start)) >= 1
            || abs(copy.end.timeIntervalSince(spec.end)) >= 1
            || copy.isAllDay != spec.isAllDay
            || copy.url != spec.url
            || copy.notes != spec.notes
    }
}
