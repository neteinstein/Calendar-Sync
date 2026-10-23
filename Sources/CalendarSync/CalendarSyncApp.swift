import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: SyncController(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(settings)
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.problems.isEmpty ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
        }
    }
}
