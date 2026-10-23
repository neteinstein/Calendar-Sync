import CalendarSyncCore
import EventKit
import Foundation
import WebKit

/// Runs syncs: on a timer, when Calendar data changes, and on demand.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var hasCalendarAccess = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary = "Not synced yet"
    @Published private(set) var problems: [String] = []
    @Published private(set) var preview: SyncPlan?

    let settings: SettingsStore
    let eventKit = EventKitBridge()
    private var outlookSources: [UUID: OutlookWebSource] = [:]
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?
    private var pendingChangeSync: Task<Void, Never>?
    /// Our own writes also fire EKEventStoreChanged; ignore those.
    private var ignoreStoreChangesUntil = Date.distantPast

    init(settings: SettingsStore) {
        self.settings = settings
        Task { await start() }
    }

    func start() async {
        hasCalendarAccess = await eventKit.requestAccess()
        guard hasCalendarAccess else {
            lastSummary = "No calendar access. Allow it in System Settings › Privacy & Security › Calendars."
            return
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventKit.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDataChanged() }
        }
        restartTimer()
        await sync()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(settings.intervalMinutes, 1) * 60)
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.sync() }
            }
        }
    }

    /// Calendar.app changed (e.g. a client meeting moved): resync the Calendar.app sources
    /// after a short pause. Outlook web sources wait for the timer, since reading them is slow.
    private func calendarDataChanged() {
        guard Date() > ignoreStoreChangesUntil else { return }
        pendingChangeSync?.cancel()
        pendingChangeSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync(includeWebSources: false)
        }
    }

    // MARK: - Sync

    var window: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: settings.options.daysAhead + 1, to: start)!
        return (start, end)
    }

    /// Reads all sources and works out the changes. With `apply == false` nothing is written
    /// (used for the preview).
    @discardableResult
    func sync(apply: Bool = true, includeWebSources: Bool = true) async -> SyncPlan? {
        // Access may have been granted in System Settings since launch; start() then syncs.
        if !hasCalendarAccess, eventKit.hasAccess {
            await start()
            return nil
        }
        guard hasCalendarAccess, !isSyncing else { return nil }
        guard let targetID = settings.targetCalendarID, eventKit.calendar(id: targetID) != nil else {
            lastSummary = "Choose your main calendar to copy into in Settings."
            return nil
        }
        isSyncing = true
        defer { isSyncing = false }

        let (start, end) = window
        var results: [(config: SourceConfig, result: SourceFetchResult)] = []
        for source in settings.sources where source.isEnabled {
            switch source.kind {
            case .eventKit(let calendarID):
                if calendarID == targetID { continue } // never copy a calendar into itself
                // Copies are prefixed with the calendar's current name, even if it was renamed.
                var source = source
                if let calendar = eventKit.calendar(id: calendarID) { source.calendarName = calendar.title }
                results.append((source, eventKit.sourceEvents(calendarID: calendarID, from: start, to: end)))
            case .outlookWeb:
                // Skipped sources aren't passed to the planner, so their copies stay as they are.
                guard includeWebSources else { continue }
                results.append((source, await outlookSource(for: source.id).fetch(from: start, to: end)))
            }
        }

        guard let existing = eventKit.existingCopies(targetID: targetID, from: start, to: end) else {
            lastSummary = "Target calendar not found."
            return nil
        }
        let plan = SyncPlanner.plan(sources: results, existing: existing, options: settings.options)

        var problems = plan.failedSources.map { id, reason in
            "\(settings.sources.first { $0.id == id }?.calendarName ?? "Source"): \(reason)"
        }
        if apply {
            ignoreStoreChangesUntil = Date().addingTimeInterval(5)
            problems += eventKit.apply(plan, targetID: targetID)
            ignoreStoreChangesUntil = Date().addingTimeInterval(5)
            lastSync = Date()
            lastSummary = plan.isEmpty
                ? "Up to date (\(plan.unchangedCount) copied meetings)"
                : "Added \(plan.creates), updated \(plan.updates), removed \(plan.deletes)"
        } else {
            preview = plan
        }
        self.problems = problems.sorted()
        return plan
    }

    // MARK: - Outlook web

    func outlookSource(for sourceID: UUID) -> OutlookWebSource {
        if let existing = outlookSources[sourceID] { return existing }
        let source = OutlookWebSource(sourceID: sourceID)
        outlookSources[sourceID] = source
        return source
    }

    func showOutlookWindow(for source: SourceConfig) {
        outlookSource(for: source.id).showWindow(title: source.calendarName)
    }

    func forgetOutlookSession(for sourceID: UUID) {
        outlookSources[sourceID]?.tearDown()
        outlookSources[sourceID] = nil
        Task {
            // Give WebKit a moment to release the store; it can't be removed while in use.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: sourceID)
            } catch {
                NSLog("Calendar Sync: couldn't delete Outlook sign-in data: \(error)")
            }
        }
    }
}
