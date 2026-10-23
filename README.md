# Calendar Sync

A macOS menu bar app that copies meetings from client calendars into your Mindera calendar, so colleagues can see when you're busy. It replaces the "How To: Calendar Sync" Shortcut and cron job.

- Each copy is titled **`[Calendar name] Meeting name`**, for example `[Calendar A] Sprint planning`. For calendars in Calendar.app this is the calendar's own name (renames are picked up). For Outlook on the web you type the name.
- If the meeting has a Teams, Zoom, Google Meet or Webex link, **the link is copied too**. It's set as the event's URL and is the first line of its notes.
- Per calendar, you can **hide meeting names**. Copies are then titled `[Calendar A] Busy`, and the meeting link is still copied.
- Moved meetings are **updated** and cancelled or deleted ones are **removed**. Recurring meetings work.
- Optional: skip meetings you declined and skip all-day events.
- It syncs every 15 minutes (adjustable). Calendar.app sources also sync about 10 seconds after a change.
- Calendar Sync never sends invites. It doesn't copy attendees, and it never copies its own copies back, so syncing both ways doesn't loop.

## Client calendars it can read

| Client calendar | How |
|---|---|
| Added to Calendar.app (Exchange, Google, iCloud, …) | Pick it under **Add client calendar › From Calendar.app**. |
| Browser only, but the client allows a published calendar link | **Add client calendar › Calendar link (.ics)**. Calendar.app subscribes to the link, then you pick the new calendar like any other. |
| Browser only: Outlook / Microsoft 365 | **Add client calendar › Outlook on the web**. Sign in once in the app's own window (MFA included). Each sync reloads Outlook's week view in the background and reads the meetings it loads. **Experimental:** see below. |

### About the Outlook on the web option

- It reads the same data your browser shows you. Nothing is sent anywhere except into your own calendar.
- It depends on how Outlook's web app works internally, which Microsoft can change without notice. If a sync can't find calendar data, or you've been signed out, the existing copies are **left as they are**. The menu bar icon then shows a warning and an **Open Outlook** button.
- Reading a client's calendar this way may go against the client's IT or security policy. **Check with the client first.** Consider turning on **Hide meeting names** for that calendar.
- Each Outlook client keeps its own sign-in, so you can add more than one.

## Build and run

You need macOS 14 or later and Xcode 15+ (or just the Xcode command line tools).

```bash
scripts/build-app.sh
open "build/Calendar Sync.app"
```

On first launch, allow calendar access. Then open **Settings…** from the menu bar icon:

1. **General:** choose the calendar to copy into (your Mindera calendar), how many days ahead, and how often to sync.
2. **Client calendars:** add each client calendar. For Outlook on the web, also give it a calendar name.
3. **Preview:** see what a sync would change before it changes anything.

The build is ad-hoc signed, so macOS asks for calendar access again after each rebuild.

### Run the tests

```bash
swift test
```

The tests cover the sync rules: titles, meeting links, moves, deletes, filters, no loops, and the Outlook data parser. They also run on Linux.

### Sharing with colleagues

To install without Gatekeeper warnings, the app needs a Developer ID certificate (Apple Developer Program, $99/year) and notarization:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" UNIVERSAL=1 scripts/build-app.sh
ditto -c -k --keepParent "build/Calendar Sync.app" CalendarSync.zip
xcrun notarytool submit CalendarSync.zip --keychain-profile <profile> --wait
xcrun stapler staple "build/Calendar Sync.app"
```

Before sharing, change `CFBundleIdentifier` in `Support/Info.plist` from `com.example.calendarsync` to your own identifier.

## How it works

- `Sources/CalendarSyncCore`: platform-independent rules.
  - `SyncPlanner` decides what to add, update and remove.
  - `CopyFormatter` builds titles and notes.
  - `MeetingLink` finds meeting links.
  - `CopyMarker` is the hidden tag that ties each copy to its original.
  - `OutlookWebParser` reads Outlook's web data.
- `Sources/CalendarSync`: the macOS app.
  - `EventKitBridge` reads and writes Calendar.app data.
  - `OutlookWebSource` is the built-in Outlook browser.
  - `SyncController` handles scheduling.
  - SwiftUI views make up the rest.

Each copy carries a line like `calsync:v1:<source id>:<occurrence id>` at the end of its notes. That's how the app recognises its own copies. Copies are matched on this tag, not on title and time, which is why moved meetings get updated instead of duplicated.

### Known limits

- Calendar.app refreshes accounts every few minutes, so changes made on the client side show up with that delay.
- Copies made from a client calendar that you later remove from the app are left in place. Delete them in Calendar if you no longer want them.
