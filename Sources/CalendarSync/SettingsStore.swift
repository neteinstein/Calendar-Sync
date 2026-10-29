import CalendarSyncCore
import Foundation

/// User settings, saved to UserDefaults as JSON.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var sources: [SourceConfig] { didSet { save(sources, "sources") } }
    @Published var options: SyncOptions { didSet { save(options, "options") } }
    @Published var alerts: EventAlertOptions { didSet { save(alerts, "alerts") } }
    /// The menu bar button opens a month view / event list, and the icon shows today's date.
    @Published var menuCalendarEnabled: Bool { didSet { defaults.set(menuCalendarEnabled, forKey: "menuCalendarEnabled") } }
    /// What the icon shows next to today's date while the menu calendar is on.
    @Published var menuBar: MenuBarOptions { didSet { save(menuBar, "menuBar") } }
    /// How the menu's month view lays out a week.
    @Published var menuCalendar: MenuCalendarOptions { didSet { save(menuCalendar, "menuCalendar") } }
    @Published var targetCalendarID: String? { didSet { defaults.set(targetCalendarID, forKey: "targetCalendarID") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") } }
    /// The main calendar is also shown as Busy in the secondary calendars, in each one whose
    /// `showBusyInSecondary` is on.
    @Published var twoWaySync: Bool { didSet { defaults.set(twoWaySync, forKey: "twoWaySync") } }
    /// Not a setting: the secondary calendars Busy events were added to. Only in these are
    /// events that look like Busy events taken back when they're no longer wanted.
    var busyCalendarIDs: Set<String> {
        didSet { if busyCalendarIDs != oldValue { defaults.set(busyCalendarIDs.sorted(), forKey: "busyCalendarIDs") } }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sources = Self.load([SourceConfig].self, "sources", defaults) ?? []
        self.sources = sources
        options = Self.load(SyncOptions.self, "options", defaults) ?? SyncOptions()
        alerts = Self.load(EventAlertOptions.self, "alerts", defaults) ?? EventAlertOptions()
        menuCalendarEnabled = defaults.bool(forKey: "menuCalendarEnabled")
        menuBar = Self.load(MenuBarOptions.self, "menuBar", defaults) ?? MenuBarOptions()
        menuCalendar = Self.load(MenuCalendarOptions.self, "menuCalendar", defaults) ?? MenuCalendarOptions()
        targetCalendarID = defaults.string(forKey: "targetCalendarID")
        let interval = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = interval > 0 ? interval : 15
        // Older versions had only the per-calendar choice; keep the calendars that made it.
        twoWaySync = defaults.object(forKey: "twoWaySync") as? Bool ?? sources.contains(where: \.showBusyInSecondary)
        busyCalendarIDs = Set(defaults.stringArray(forKey: "busyCalendarIDs") ?? [])
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
