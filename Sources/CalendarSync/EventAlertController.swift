import AppKit
import CalendarSyncCore
import Combine
import SwiftUI

/// Shows a full-screen alert when a main-calendar event starts, with buttons to join the
/// call, go to the room, or ignore it. Each occurrence alerts once.
@MainActor
final class EventAlertController: ObservableObject {
    private let settings: SettingsStore
    private let eventKit: EventKitBridge
    private var timer: Timer?
    /// Occurrence keys already alerted, with when, so each event alerts once. Pruned daily.
    private var shown: [String: Date] = [:]
    private var window: NSWindow?
    /// Keeps App Nap away while alerts are on. A menu bar app with no window open naps, and
    /// then its timers fire minutes late or not at all, so alerts came late or never.
    private var activity: NSObjectProtocol?
    private var enabledObserver: AnyCancellable?

    init(settings: SettingsStore, eventKit: EventKitBridge) {
        self.settings = settings
        self.eventKit = eventKit
        // On the main run loop, so the block runs on the main actor; in the common modes, so
        // it keeps checking while the menu is open.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        enabledObserver = settings.$alerts.map(\.enabled).removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.preventAppNap(enabled) }
        }
    }

    private func preventAppNap(_ prevent: Bool) {
        if prevent, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Showing a full-screen alert when an event starts")
        } else if !prevent, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func check() {
        guard settings.alerts.enabled, window == nil, eventKit.hasAccess,
              let targetID = settings.targetCalendarID else { return }
        let now = Date()
        // Events overlapping this window: already under way, or starting within the lead time.
        let ahead = now.addingTimeInterval(60 * Double(settings.alerts.leadMinutes) + 60)
        guard case .success(let events) = eventKit.sourceEvents(calendarID: targetID, from: now, to: ahead) else { return }

        shown = shown.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        let due = EventAlertPlanner.dueAlerts(
            events: events, shown: Set(shown.keys), now: now, leadMinutes: settings.alerts.leadMinutes)
        // Marked only once it's on screen, so an alert that couldn't show is tried again.
        guard let event = due.first, show(event) else { return }
        shown[event.key] = now
    }

    private func show(_ event: SourceEvent) -> Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let panel = AlertPanel(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.ignoresKeysUntil = Date().addingTimeInterval(1.5)
        panel.contentView = NSHostingView(rootView: EventAlertView(event: event) { [weak self] in
            self?.dismiss()
        })
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        // If another event is due at the same time, show it next.
        check()
    }
}

/// Borderless windows can't become key by default, but the alert's buttons need the keyboard
/// (Return joins, Escape ignores).
private final class AlertPanel: NSPanel {
    /// Return or Escape typed into another app just as the alert appears would otherwise
    /// dismiss it before it was seen.
    var ignoresKeysUntil = Date.distantPast

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Date() < ignoresKeysUntil || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if [.keyDown, .keyUp].contains(event.type), Date() < ignoresKeysUntil { return }
        super.sendEvent(event)
    }
}

private struct EventAlertView: View {
    let event: SourceEvent
    let dismiss: () -> Void

    /// The first line of the location, for the "Go to …" button. Room names are short;
    /// addresses pasted into the location field are not.
    private var room: String? {
        guard let line = event.location?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("\(Text(event.start, format: .dateTime.hour().minute())) – \(Text(event.end, format: .dateTime.hour().minute()))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(event.title.isEmpty ? "Busy" : event.title)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let room {
                    Label(room, systemImage: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let url = event.meetingURL {
                        Button {
                            NSWorkspace.shared.open(url)
                            dismiss()
                        } label: {
                            Label("Join call", systemImage: "video.fill").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        if let room {
                            Button { dismiss() } label: {
                                Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if let room {
                        Button { dismiss() } label: {
                            Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    Button("Ignore", action: dismiss)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.large)
                .padding(.top, 12)
            }
            .padding(44)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
