import CalendarSyncCore
import Foundation

/// User settings, saved to UserDefaults as JSON.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var sources: [SourceConfig] { didSet { save(sources, "sources") } }
    @Published var options: SyncOptions { didSet { save(options, "options") } }
    @Published var targetCalendarID: String? { didSet { defaults.set(targetCalendarID, forKey: "targetCalendarID") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sources = Self.load([SourceConfig].self, "sources", defaults) ?? []
        options = Self.load(SyncOptions.self, "options", defaults) ?? SyncOptions()
        targetCalendarID = defaults.string(forKey: "targetCalendarID")
        let interval = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = interval > 0 ? interval : 15
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
