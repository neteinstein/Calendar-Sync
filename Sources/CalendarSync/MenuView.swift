import CalendarSyncCore
import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar Sync").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.isSyncing ? "Syncing…" : controller.lastSummary)
                if let lastSync = controller.lastSync {
                    (Text("Last synced ") + Text(lastSync, style: .relative) + Text(" ago"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            ForEach(controller.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let outlookSources = settings.sources.filter { $0.kind == .outlookWeb }
            if !outlookSources.isEmpty {
                Divider()
                ForEach(outlookSources) { source in
                    Button("Open Outlook – \(source.calendarName)") {
                        controller.showOutlookWindow(for: source)
                    }
                }
            }

            Divider()

            HStack {
                Button("Sync now") {
                    Task { await controller.sync() }
                }
                .disabled(controller.isSyncing || !controller.hasCalendarAccess)
                .keyboardShortcut("r")

                Spacer()

                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            }

            Button("Quit Calendar Sync") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
    }
}
