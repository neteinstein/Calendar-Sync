import CalendarSyncCore
import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab().tabItem { Label("Client calendars", systemImage: "calendar") }
            PreviewTab().tabItem { Label("Preview", systemImage: "eye") }
        }
        .frame(width: 620, height: 460)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Main calendar", selection: $settings.targetCalendarID) {
                    Text("Choose a calendar…").tag(String?.none)
                    ForEach(controller.eventKit.calendars().filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                        CalendarLabel(calendar: calendar).tag(Optional(calendar.calendarIdentifier))
                    }
                }
                .onChange(of: settings.targetCalendarID) { _, _ in Task { await controller.sync() } }
                Text("Client meetings are copied into this calendar. It must be added to Calendar.app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Today plus the next \(settings.options.daysAhead) days",
                        value: $settings.options.daysAhead, in: 0...30)
                Stepper("Sync every \(settings.intervalMinutes) minutes",
                        value: $settings.intervalMinutes, in: 5...240, step: 5)
                    .onChange(of: settings.intervalMinutes) { _, _ in controller.restartTimer() }
                Toggle("Skip meetings I declined", isOn: $settings.options.skipDeclined)
                Toggle("Skip all-day events", isOn: $settings.options.skipAllDay)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if !controller.hasCalendarAccess {
                    Text("Calendar Sync doesn't have calendar access. Allow it in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var showingLinkSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.sources.isEmpty {
                ContentUnavailableView(
                    "No client calendars yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a client calendar to start copying its meetings."))
            } else {
                Form {
                    ForEach($settings.sources) { $source in
                        SourceRow(source: $source)
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Menu("Add client calendar") {
                    Section("From Calendar.app") {
                        ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                            Button("\(calendar.title) (\(calendar.source.title))") {
                                settings.sources.append(SourceConfig(
                                    kind: .eventKit(calendarID: calendar.calendarIdentifier),
                                    calendarName: calendar.title))
                            }
                        }
                    }
                    Section("Not in Calendar.app") {
                        Button("Outlook on the web (sign in)…") {
                            let source = SourceConfig(kind: .outlookWeb, calendarName: "Outlook")
                            settings.sources.append(source)
                            controller.showOutlookWindow(for: source)
                        }
                        Button("Calendar link (.ics)…") { showingLinkSheet = true }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingLinkSheet) { CalendarLinkSheet() }
    }

    private var availableCalendars: [EKCalendar] {
        let used = Set(settings.sources.compactMap { source -> String? in
            if case .eventKit(let id) = source.kind { return id } else { return nil }
        })
        return controller.eventKit.calendars().filter {
            !used.contains($0.calendarIdentifier) && $0.calendarIdentifier != settings.targetCalendarID
        }
    }
}

private struct SourceRow: View {
    @Binding var source: SourceConfig
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    /// Calendar.app sources use the calendar's current name; Outlook web sources use the typed one.
    private var displayName: String {
        if case .eventKit(let calendarID) = source.kind, let calendar = controller.eventKit.calendar(id: calendarID) {
            return calendar.title
        }
        return source.calendarName
    }

    var body: some View {
        Section {
            if source.kind == .outlookWeb {
                TextField("Calendar name", text: $source.calendarName, prompt: Text("e.g. Calendar A"))
            }
            Toggle("Hide meeting names (copy as “[\(displayName)] Busy”)", isOn: $source.hideMeetingName)
            Toggle("Sync this calendar", isOn: $source.isEnabled)
            HStack {
                if source.kind == .outlookWeb {
                    Button("Open Outlook window") { controller.showOutlookWindow(for: source) }
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    if source.kind == .outlookWeb { controller.forgetOutlookSession(for: source.id) }
                    let id = source.id
                    // Removed on the next run loop so SwiftUI isn't still reading this row's binding.
                    DispatchQueue.main.async { settings.sources.removeAll { $0.id == id } }
                }
            }
        } header: {
            switch source.kind {
            case .eventKit(let calendarID):
                if let calendar = controller.eventKit.calendar(id: calendarID) {
                    CalendarLabel(calendar: calendar)
                } else {
                    Label("Calendar no longer in Calendar.app", systemImage: "exclamationmark.triangle")
                }
            case .outlookWeb:
                Label("Outlook on the web (experimental)", systemImage: "globe")
            }
        } footer: {
            Text("Copies are titled “[\(displayName)] \(source.hideMeetingName ? "Busy" : "Meeting name")” and include the meeting link when there is one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Subscribes to a client calendar link through Calendar.app, which then keeps it updated.
private struct CalendarLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a calendar link").font(.headline)
            Text("""
                In Outlook on the web: Settings › Calendar › Shared calendars › Publish a calendar, \
                then copy the ICS link. In Google Calendar: Settings › your calendar › \
                Secret address in iCal format.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…/calendar.ics", text: $link)
            Text("Calendar.app will ask how to add it. Once it's added, choose it here under “From Calendar.app”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open in Calendar") {
                    if let url = Self.webcalURL(link) { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Self.webcalURL(link) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func webcalURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "webcal", "webcals"].contains(scheme),
              components.host != nil
        else { return nil }
        components.scheme = "webcal"
        return components.url
    }
}

// MARK: - Preview

private struct PreviewTab: View {
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("See what the next sync would change, without changing anything.")
                Spacer()
                Button("Preview") { Task { await controller.sync(apply: false) } }
                    .disabled(controller.isSyncing)
            }
            if let plan = controller.preview {
                Text(plan.isEmpty
                     ? "Nothing to change (\(plan.unchangedCount) copies up to date)."
                     : "\(plan.creates) to add, \(plan.updates) to update, \(plan.deletes) to remove, \(plan.unchangedCount) unchanged.")
                    .foregroundStyle(.secondary)
                List(Array(plan.actions.enumerated()), id: \.offset) { _, action in
                    HStack {
                        Text(action.verb).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                        Text(action.title)
                        Spacer()
                        Text(action.start, format: .dateTime.weekday().day().month().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer()
            }
            ForEach(controller.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding()
    }
}

private struct CalendarLabel: View {
    let calendar: EKCalendar

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 9, height: 9)
            Text(calendar.title)
            Text(calendar.source.title).foregroundStyle(.secondary)
        }
    }
}
