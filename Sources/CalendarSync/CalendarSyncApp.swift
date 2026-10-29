import CalendarSyncCore
import SwiftUI

@main
struct CalendarSyncApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController
    @StateObject private var updates = UpdateChecker()
    @StateObject private var clock = Clock()
    @StateObject private var menuBarItem = MenuBarItem.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Held until the process ends. See `InstanceLock`.
    private static var instanceLock: InstanceLock?

    init() {
        Self.quitIfAlreadyRunning()
        Self.linkIntoApplicationsOnce()
        let settings = SettingsStore()
        let controller = SyncController(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit))
    }

    /// A copy already running would sync the same calendars: an "Open at login" item next to
    /// a `brew services` one, or a source build next to a Homebrew one. Every copy shares the
    /// lock file, so a later one quits here, before it asks for calendar access, syncs or shows
    /// anything. If the lock can't be taken at all, running beats not running.
    private static func quitIfAlreadyRunning() {
        guard instanceLock == nil else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.neteinstein.calendarsync/instance.lock")
        do {
            guard let lock = try InstanceLock.acquire(at: url) else {
                NSLog("Calendar Sync is already running, so this copy quits.")
                AppDelegate.askRunningCopyToShowMenuBarItem()
                exit(0)
            }
            instanceLock = lock
        } catch {
            NSLog("Calendar Sync couldn't check for another running copy, so it runs anyway: \(error)")
        }
    }

    /// A Homebrew install links itself into ~/Applications, through the opt path so the link
    /// follows upgrades. Skipped when /Applications already has the app, say a link an admin
    /// made. Only once: a link the user removes stays removed. If it fails, the next launch
    /// tries again.
    private static func linkIntoApplicationsOnce() {
        let defaults = UserDefaults.standard
        let key = "linkedIntoApplications"
        let fileManager = FileManager.default
        guard !defaults.bool(forKey: key),
              let target = ApplicationsLink.homebrewOptBundle(
                  forResolvedBundle: Bundle.main.bundleURL.resolvingSymlinksInPath()
              ),
              fileManager.fileExists(atPath: target.path)
        else { return }
        let home = fileManager.urls(for: .applicationDirectory, in: .userDomainMask)[0]
        let system = fileManager.urls(for: .applicationDirectory, in: .localDomainMask)[0]
        do {
            if try ApplicationsLink.ensure(linkTo: target, in: home, unlessIn: [system]) == .created {
                NSLog("Calendar Sync linked itself into \(home.path).")
            }
            defaults.set(true, forKey: key)
        } catch {
            NSLog("Calendar Sync couldn't link itself into \(home.path): \(error)")
        }
    }

    /// The icon in the menu bar: a calendar glyph, plus today's date when the menu calendar
    /// is on, and with it the week day, the time and the moon phase when those are on too.
    /// `Clock` keeps the date and time right as the minutes pass. Not a TimelineView: in a
    /// menu bar label it re-renders the button in an endless loop and the app hangs at launch.
    private struct MenuBarLabel: View {
        @ObservedObject var settings: SettingsStore
        @ObservedObject var controller: SyncController
        @ObservedObject var clock: Clock

        /// "26 Oct", or "Mon 26 Oct" with the week day, in the locale's own field order.
        private var dateStyle: Date.FormatStyle {
            let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            return settings.menuBar.showsWeekday ? style.weekday(.abbreviated) : style
        }

        var body: some View {
            let icon = controller.problems.isEmpty ? "calendar" : "calendar.badge.exclamationmark"
            if settings.menuCalendarEnabled {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                    Text(clock.now, format: dateStyle)
                    if settings.menuBar.showsTime {
                        Text(clock.now, format: .dateTime.hour().minute())
                            .monospacedDigit()
                            .padding(.leading, 3)
                    }
                    if settings.menuBar.showsMoonPhase {
                        let phase = MoonPhase.phase(on: clock.now)
                        Image(systemName: phase.symbolName)
                            .accessibilityLabel(phase.name)
                    }
                }
            } else {
                Image(systemName: controller.problems.isEmpty ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarItem.isInserted) {
            MenuView()
                .environmentObject(settings)
                .environmentObject(controller)
        } label: {
            MenuBarLabel(settings: settings, controller: controller, clock: clock)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
                .environmentObject(updates)
        }
    }
}

/// Whether the menu bar icon is in the menu bar, as the `MenuBarExtra`'s binding. Without a
/// binding, SwiftUI quits the app when the icon is removed: hidden in System Settings › Menu Bar,
/// or ⌘-dragged out. Then every launch ended a second later and nothing synced. With it the app
/// keeps running and syncing without the icon, and opening the app again puts the icon back.
@MainActor
final class MenuBarItem: ObservableObject {
    static let shared = MenuBarItem()

    /// Publishes only real changes: SwiftUI writes the binding back while it updates the scene,
    /// and publishing every write re-renders the scene, which writes it again, without end.
    var isInserted: Bool {
        get { inserted }
        set {
            guard newValue != inserted else { return }
            objectWillChange.send()
            inserted = newValue
            NSLog(newValue
                  ? "Calendar Sync's menu bar icon is back."
                  : "Calendar Sync's menu bar icon was removed. The app keeps syncing; open it again to bring the icon back.")
        }
    }

    private var inserted = true
}

/// Puts the menu bar icon back when the app is opened again while it runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a later copy as it quits, so opening the app again works whichever way it was
    /// started.
    nonisolated private static let showMenuBarItem = Notification.Name("org.neteinstein.calendarsync.showMenuBarItem")

    nonisolated static func askRunningCopyToShowMenuBarItem() {
        DistributedNotificationCenter.default().postNotificationName(
            showMenuBarItem, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showMenuBarItem, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarItem.shared.isInserted = true }
        }
    }

    /// Opening the app while it runs: Finder, Spotlight or `open`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarItem.shared.isInserted = true
        return true
    }
}

/// The current minute, for the menu bar label. Ticks on the minute, so a shown time changes
/// when the system clock does, and the label redraws at most once a minute.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Clock.minute(of: Date())
    private var timer: Timer?

    init() {
        // On the main run loop, so the block runs on the main actor; in the common modes, so
        // it keeps ticking while the menu is open.
        let timer = Timer(fire: now + 60, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let minute = Self.minute(of: Date())
        if minute != now { now = minute }
    }

    /// `date` with its seconds dropped.
    private static func minute(of date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

extension MoonPhase {
    /// The SF Symbol for the phase, lit on the right while waxing as seen from the northern
    /// hemisphere. The inverse variants fill the lit part, as almanacs do (● full, ○ new), so
    /// the glyph reads the same way in a dark menu bar.
    var symbolName: String {
        switch self {
        case .newMoon: "moonphase.new.moon.inverse"
        case .waxingCrescent: "moonphase.waxing.crescent.inverse"
        case .firstQuarter: "moonphase.first.quarter.inverse"
        case .waxingGibbous: "moonphase.waxing.gibbous.inverse"
        case .fullMoon: "moonphase.full.moon.inverse"
        case .waningGibbous: "moonphase.waning.gibbous.inverse"
        case .lastQuarter: "moonphase.last.quarter.inverse"
        case .waningCrescent: "moonphase.waning.crescent.inverse"
        }
    }
}
