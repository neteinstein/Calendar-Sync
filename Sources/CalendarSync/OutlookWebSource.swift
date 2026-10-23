import AppKit
import CalendarSyncCore
import Foundation
import WebKit

/// Reads a client's Outlook / Microsoft 365 calendar through a built-in browser window,
/// for accounts that can't be added to Calendar.app.
///
/// The user signs in once in the window (MFA included). Each sync reloads the Outlook
/// calendar week view in the background and records the JSON that Outlook's own web app
/// downloads; `OutlookWebParser` turns that into events. Nothing is sent anywhere else.
///
/// EXPERIMENTAL: this depends on how Outlook on the web loads its data, which Microsoft can
/// change at any time. If a sync can't find calendar data, the copies are left untouched.
@MainActor
final class OutlookWebSource: NSObject, ObservableObject {
    /// Change if the client uses a different Outlook host (e.g. outlook.office365.com).
    static let host = "https://outlook.office.com"

    @Published private(set) var needsSignIn = false

    let sourceID: UUID
    private let webView: WKWebView
    private var window: NSWindow?
    private var captured: [Data] = []
    private var lastCaptureAt = Date.distantPast
    private var isFetching = false

    init(sourceID: UUID) {
        self.sourceID = sourceID

        let config = WKWebViewConfiguration()
        // One persistent cookie store per source, so several Outlook clients can each stay
        // signed in.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        config.userContentController.addUserScript(
            WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860), configuration: config)
        // Outlook may refuse browsers it doesn't recognise; present as Safari.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        super.init()
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "calsync")
    }

    /// Releases the web view so its stored sign-in can be deleted.
    func tearDown() {
        window?.close()
        window = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Sign-in window

    /// Shows Outlook in a normal window so the user can sign in or check what's loaded.
    func showWindow(title: String) {
        let window = self.window ?? makeWindow()
        window.title = "Outlook – \(title)"
        if webView.url == nil {
            webView.load(URLRequest(url: Self.weekURL(for: Date())))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        return window
    }

    // MARK: - Fetching

    func fetch(from start: Date, to end: Date) async -> SourceFetchResult {
        guard !isFetching else { return .failure("Already reading Outlook") }
        isFetching = true
        defer { isFetching = false }

        captured = []
        // The week view only loads one week, so load every week the sync window touches.
        for weekStart in Self.weekStarts(from: start, to: end) {
            let before = captured.count
            lastCaptureAt = .distantPast
            webView.load(URLRequest(url: Self.weekURL(for: weekStart)))
            await waitForCalendarData(after: before)

            if isSignInPage(webView.url) {
                needsSignIn = true
                return .failure("Signed out of Outlook. Open the Outlook window to sign in again.")
            }
            if captured.count == before {
                return .failure("Couldn't read the Outlook calendar (no calendar data loaded).")
            }
        }

        needsSignIn = false
        let events = OutlookWebParser.events(fromPayloads: captured)
            .filter { $0.end > start && $0.start < end }
        return .success(events)
    }

    /// Waits until Outlook has downloaded calendar data and gone quiet for 3 s, up to 30 s.
    private func waitForCalendarData(after before: Int) async {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isSignInPage(webView.url) { return }
            if captured.count > before, Date().timeIntervalSince(lastCaptureAt) > 3 { return }
        }
    }

    private func isSignInPage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.contains("login.microsoftonline.com") || host.contains("login.live.com")
            || host.contains("login.microsoft.com")
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["body"] as? String else { return }
        captured.append(Data(text.utf8))
        lastCaptureAt = Date()
    }

    // MARK: - URLs

    static func weekURL(for date: Date) -> URL {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return URL(string: "\(host)/calendar/view/week/\(c.year!)/\(c.month!)/\(c.day!)")!
    }

    static func weekStarts(from start: Date, to end: Date) -> [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        var weeks: [Date] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        while cursor < end {
            weeks.append(max(cursor, start))
            cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor)!
        }
        return weeks
    }

    /// Wraps `fetch` and `XMLHttpRequest` in the page and forwards responses from calendar
    /// endpoints to the app. Read-only: requests are passed through unchanged.
    static let captureScript = #"""
    (function () {
      if (window.__calsync) return;
      window.__calsync = true;
      const RX = /calendarview|getcalendarview|finditem|calendaritem|startupdata|\/events/i;
      const MAX = 8 * 1024 * 1024;
      function send(url, text) {
        try {
          if (!text || text.length > MAX) return;
          const c = text.trimStart()[0];
          if (c !== '{' && c !== '[') return;
          window.webkit.messageHandlers.calsync.postMessage({ url: String(url), body: text });
        } catch (e) {}
      }
      const origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          const p = origFetch.apply(this, arguments);
          try {
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            if (RX.test(url)) p.then(r => r.clone().text()).then(t => send(url, t)).catch(() => {});
          } catch (e) {}
          return p;
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const xsend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__calsyncURL = url;
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        if (RX.test(String(this.__calsyncURL || ''))) {
          this.addEventListener('load', function () {
            try {
              if (this.responseType === '' || this.responseType === 'text') send(this.__calsyncURL, this.responseText);
              else if (this.responseType === 'json') send(this.__calsyncURL, JSON.stringify(this.response));
            } catch (e) {}
          });
        }
        return xsend.apply(this, arguments);
      };
    })();
    """#
}

/// Avoids the retain cycle WKUserContentController creates with its message handlers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: OutlookWebSource?

    init(_ target: OutlookWebSource) { self.target = target }

    // WebKit delivers script messages on the main thread.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message) }
    }
}
