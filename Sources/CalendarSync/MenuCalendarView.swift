import AppKit
import CalendarSyncCore
import SwiftUI

/// The month grid and event list shown at the top of the menu when "Show a calendar in the
/// menu" is on. Events come from the main calendar, where secondary-calendar meetings are already copied.
struct MenuCalendarView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @AppStorage("menuCalendarMode") private var mode: Mode = .month
    @State private var shownMonth = Date()
    /// A day picked in the month grid, shown as that day's event list until dismissed.
    @State private var selectedDay: Date?
    @State private var events: [SourceEvent] = []

    enum Mode: String {
        case month, list
    }

    private var calendar: Calendar { settings.menuCalendar.applied(to: .current) }
    private var showsWeekends: Bool { settings.menuCalendar.showsWeekends }

    var body: some View {
        VStack(spacing: 10) {
            Picker("View", selection: $mode) {
                Text("Month").tag(Mode.month)
                Text("List").tag(Mode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .month:
                if let day = selectedDay {
                    dayView(day)
                } else {
                    monthView
                }
            case .list:
                listView
            }
        }
        .onAppear { reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onChange(of: shownMonth) { _, _ in reload() }
        .onChange(of: settings.menuCalendar) { _, _ in reload() }
        .onChange(of: controller.lastSync) { _, _ in reload() }
    }

    // MARK: - Data

    /// Reads the shown month (or the list's window) from the main calendar.
    private func reload() {
        guard let targetID = settings.targetCalendarID else {
            events = []
            return
        }
        let (from, to): (Date, Date)
        switch mode {
        case .month:
            let days = MenuCalendar.gridDays(for: shownMonth, calendar: calendar, showsWeekends: showsWeekends)
            guard let first = days.first, let last = days.last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
            (from, to) = (first, end)
        case .list:
            let today = calendar.startOfDay(for: Date())
            (from, to) = (calendar.date(byAdding: .day, value: -30, to: today)!,
                          calendar.date(byAdding: .day, value: 60, to: today)!)
        }
        if case .success(let fetched) = controller.eventKit.sourceEvents(calendarID: targetID, from: from, to: to) {
            events = fetched.filter { !$0.isCancelled }
        }
    }

    private func events(on day: Date) -> [SourceEvent] {
        events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    // MARK: - Month

    private var monthView: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: { shownMonth = calendar.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth },
                       label: { Image(systemName: "chevron.left") })
                Spacer()
                Text(shownMonth, format: .dateTime.month(.wide).year()).font(.headline)
                Spacer()
                Button("Today") { shownMonth = Date() }
                    .disabled(calendar.isDate(shownMonth, equalTo: Date(), toGranularity: .month))
                Button(action: { shownMonth = calendar.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth },
                       label: { Image(systemName: "chevron.right") })
            }
            .buttonStyle(.borderless)

            let days = MenuCalendar.gridDays(for: shownMonth, calendar: calendar, showsWeekends: showsWeekends)
            let busyDays = Set(events.map { calendar.startOfDay(for: $0.start) })
            let weekdays = MenuCalendar.weekdays(calendar: calendar, showsWeekends: showsWeekends)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: weekdays.count), spacing: 2) {
                // By weekday: the very short symbols repeat (two "T"s, two "S"s).
                ForEach(weekdays, id: \.self) { weekday in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[weekday - 1])
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day, hasEvents: busyDays.contains(calendar.startOfDay(for: day)))
                }
            }
        }
    }

    private func dayCell(_ day: Date, hasEvents: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: shownMonth, toGranularity: .month)
        // Weekends get a soft gray background so they stand apart from working days.
        let background: Color = isToday ? .accentColor
            : calendar.isDateInWeekend(day) ? .secondary.opacity(0.12) : .clear
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                     : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Circle()
                    .fill(hasEvents ? (isToday ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - One day

    private func dayView(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    selectedDay = nil
                } label: {
                    Label("Month", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(day, format: .dateTime.weekday(.wide).day().month()).font(.headline)
            }
            let dayEvents = events(on: day)
            if dayEvents.isEmpty {
                Text("No events")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        eventRows(dayEvents)
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    // MARK: - List

    /// Every event of the window, one section per day. Opens at the first event still to
    /// come; scrolling back shows past events dimmed.
    private var listView: some View {
        let sections = MenuCalendar.sections(for: events, calendar: calendar)
        let now = Date()
        let anchor = sections.flatMap(\.events).first { $0.end >= now }?.key
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if sections.isEmpty {
                        Text("No events")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(sections, id: \.day) { section in
                        Text(sectionTitle(section.day))
                            .font(.caption.bold())
                            .foregroundStyle(section.day < calendar.startOfDay(for: now) ? .tertiary : .secondary)
                            .padding(.top, 8)
                        eventRows(section.events)
                    }
                }
            }
            .frame(height: 300)
            .onAppear {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    // MARK: - Event rows

    /// One day's events: all-day ones first, then the morning and afternoon ones, each in a
    /// colored block when that's on. Rows carry their key as id for the list's scrolling.
    @ViewBuilder
    private func eventRows(_ dayEvents: [SourceEvent]) -> some View {
        let options = settings.menuCalendar
        let parts = MenuCalendar.parts(of: dayEvents, calendar: calendar)
        ForEach(parts.allDay, id: \.key) { row($0) }
        if options.shadesTimeOfDay {
            timeOfDayBlock("Morning", parts.morning, color: .orange)
            timeOfDayBlock("Afternoon", parts.afternoon, color: .indigo)
        } else {
            ForEach(parts.morning + parts.afternoon, id: \.key) { row($0) }
        }
    }

    @ViewBuilder
    private func timeOfDayBlock(_ title: String, _ blockEvents: [SourceEvent], color: Color) -> some View {
        if !blockEvents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                ForEach(blockEvents, id: \.key) { row($0) }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ event: SourceEvent) -> some View {
        EventRow(event: event, tint: originColor(of: event), shadesAllDay: settings.menuCalendar.shadesAllDay)
            .id(event.key)
    }

    /// Soft colors for secondary calendars without one of their own (Outlook on the web).
    private static let fallbackColors: [Color] = [.teal, .orange, .pink, .purple, .green, .blue]

    /// The color of the calendar an event was copied from: its Calendar.app color when it has
    /// one, else one of the fallback colors. The main calendar's own events use its color.
    private func originColor(of event: SourceEvent) -> Color? {
        guard settings.menuCalendar.colorsByCalendar else { return nil }
        guard let originID = MenuCalendar.originID(of: event) else {
            return controller.eventKit.calendar(id: settings.targetCalendarID).map { Color(cgColor: $0.cgColor) }
        }
        guard let index = settings.sources.firstIndex(where: { $0.id == originID }) else { return nil }
        if case .eventKit(let calendarID) = settings.sources[index].kind,
           let source = controller.eventKit.calendar(id: calendarID) {
            return Color(cgColor: source.cgColor)
        }
        return Self.fallbackColors[index % Self.fallbackColors.count]
    }

    private func sectionTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// One event line: time, title, location, and a join button when there's a link.
/// Events already over are dimmed. Tinted with the color of the calendar it came from, if
/// given; all-day events get a stronger background when `shadesAllDay` is on.
private struct EventRow: View {
    let event: SourceEvent
    var tint: Color?
    var shadesAllDay = false

    var body: some View {
        let isPast = event.end < Date()
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? "Busy" : event.title)
                    .font(.callout)
                    .lineLimit(1)
                if let location = event.location?.components(separatedBy: .newlines).first,
                   !location.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = event.meetingURL, !isPast {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(.borderless)
                .help("Join the call")
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if let tint {
                Capsule().fill(tint).frame(width: 3).padding(.vertical, 3)
            }
        }
        .opacity(isPast ? 0.4 : 1)
    }

    private var background: Color {
        let shaded = event.isAllDay && shadesAllDay
        return (tint ?? .secondary).opacity(shaded ? 0.25 : tint == nil ? 0 : 0.1)
    }
}
