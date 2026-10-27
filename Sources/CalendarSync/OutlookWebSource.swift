import AppKit
import CalendarSyncCore
import Foundation
import WebKit

/// Reads a client's Outlook / Microsoft 365 calendar through a built-in browser window,
/// for accounts that can't be added to Calendar.app.
///
/// The user signs in once in the window (MFA included). Each sync reloads the Outlook
/// calendar week view in the background and records the JSON that Outlook's own web app
/// downloads. The week view leaves out meeting bodies (and so the join links), so the
/// meetings are then loaded in full through Outlook's own service, signed in the same way
/// Outlook's own requests are. `OutlookWebParser` turns all of that into events. Nothing is
/// sent anywhere else.
///
/// To Outlook this is a Safari session: the web view runs the WebKit of the Safari installed
/// on this Mac and reports its user agent, with its own cookie store, so it is one more
/// browser signed in to the account. WebKit doesn't let the web view use a security key
/// itself, so Microsoft's sign-in pages get one from `SecurityKeySignIn` (see `webAuthnScript`).
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
    /// On a clock that setting the time doesn't move, like the waits that use it.
    private var lastCaptureAt: ContinuousClock.Instant?
    private var isFetching = false
    private let securityKey = SecurityKeySignIn()

    init(sourceID: UUID) {
        self.sourceID = sourceID

        let config = WKWebViewConfiguration()
        // One persistent cookie store per source, so several Outlook clients can each stay
        // signed in.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        config.userContentController.addUserScript(
            WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.webAuthnScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hideWebAuthnScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860), configuration: config)
        webView.customUserAgent = Self.safariUserAgent()
        super.init()
        webView.configuration.userContentController.add(WeakMessageHandler(self), name: "calsync")
        webView.configuration.userContentController.addScriptMessageHandler(
            WeakReplyHandler(self), contentWorld: .page, name: "calsyncSecurityKey")
    }

    /// The user agent of the Safari installed on this Mac, whose WebKit is the one the web view
    /// runs. WKWebView's own user agent names no browser, and Outlook turns away browsers it
    /// doesn't recognise and nags about versions it no longer supports. The macOS version is
    /// the one Safari itself has reported since 10.15, and the WebKit build is fixed the same way.
    static func safariUserAgent() -> String {
        let version = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version ?? "26.0") Safari/605.1.15"
    }

    /// Releases the web view so its stored sign-in can be deleted.
    func tearDown() {
        securityKey.cancel()
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
        // Loading would navigate away from whatever the user is doing in the window
        // (e.g. signing in), so wait until it's closed.
        if window?.isVisible == true {
            return .failure("Outlook window is open. Close it after signing in to sync.")
        }
        isFetching = true
        defer { isFetching = false }

        captured = []
        var onScreen: [SourceEvent] = []
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        // The week view only loads one week, so read every week the sync window touches.
        // Outlook ignores the date in the URL and opens the current week, so load that and
        // move on with Outlook's own "next week" button.
        for (index, weekStart) in Self.weekStarts(from: start, to: end).enumerated() {
            var before = captured.count
            lastCaptureAt = nil
            if index == 0 {
                webView.load(URLRequest(url: Self.weekURL(for: weekStart)))
                // Outlook opens the view last used on the account, not the one in the URL. In
                // Day or Month view there's no "next week" button, so switch to Week first.
                switch await ensureWeekView() {
                case .alreadyWeek: break
                case .switched:
                    // What arrived before the switch covers only the old view (e.g. one day).
                    before = captured.count
                    lastCaptureAt = nil
                case .failed:
                    if isSignInPage(webView.url) { break } // reported below
                    return .failure("Couldn't switch Outlook to its week view.")
                }
            } else {
                // The first week's data arrives before Outlook has finished starting up; a
                // click that early can move the page without its data ever being requested.
                if index == 1 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                if await !clickNextWeek() {
                    return .failure("Couldn't move to the next week in Outlook.")
                }
            }
            // Check against the whole week: Outlook loads all of it, including days already
            // past (on a weekend the work week view shows the week just ended).
            let week = calendar.dateInterval(of: .weekOfYear, for: weekStart)
            let weekFrom = week?.start ?? weekStart, weekTo = week?.end ?? end
            var loaded = await waitForCalendarData(after: before, from: weekFrom, to: weekTo)

            if isSignInPage(webView.url) {
                needsSignIn = true
                return .failure("Signed out of Outlook. Open the Outlook window to sign in again.")
            }
            // Outlook doesn't always fetch a week in a way we can capture (it can come from a
            // background worker). The meetings it shows on the page are always there.
            if !loaded {
                let shown = await meetingsOnScreen(from: weekFrom, to: weekTo)
                onScreen += shown
                loaded = !shown.isEmpty
            }
            // No meeting in the week almost always means its data didn't load (Outlook can
            // answer with another week). Fail, so existing copies are left alone.
            if !loaded {
                return .failure("Couldn't read the Outlook calendar (no calendar data loaded).")
            }
        }

        needsSignIn = false
        let itemIDs = OutlookWebParser.itemIDs(fromPayloads: captured)
        let details = await loadDetails(itemIDs: itemIDs)
        // Captured data first: it has more detail (meeting links, declined, all day).
        var seen: Set<String> = []
        let events = (OutlookWebParser.events(fromPayloads: captured, details: details) + onScreen)
            .map { event -> SourceEvent in
                var event = event
                event.title = event.title.trimmingCharacters(in: .whitespaces)
                event.key = OutlookWebParser.screenKey(title: event.title, start: event.start)
                return event
            }
            .filter { seen.insert($0.key).inserted }
            .filter { $0.end > start && $0.start < end }
        let withLinks = events.filter { $0.meetingURL != nil }.count
        NSLog("Calendar Sync: Outlook \(events.count) meetings, \(details.count) detail responses, \(withLinks) with a meeting link")
        return .success(events)
    }

    /// Loads the meetings in full (body, join link). Returns the raw responses, or nothing if
    /// Outlook didn't make a service call the page could copy its sign-in from; the meetings
    /// are then copied without those details.
    private func loadDetails(itemIDs: [String]) async -> [Data] {
        guard !itemIDs.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(Self.detailsScript, arguments: ["ids": itemIDs], in: nil, in: .page) { result in
                let texts = (try? result.get()) as? [String] ?? []
                continuation.resume(returning: texts.map { Data($0.utf8) })
            }
        }
    }

    /// Reads the meetings Outlook shows for `[from, to)` from the page, waiting up to 10 s
    /// for them to render.
    private func meetingsOnScreen(from: Date, to: Date) async -> [SourceEvent] {
        let script = "[...document.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))"
        for _ in 0..<10 {
            let labels = (try? await webView.evaluateJavaScript(script) as? [String]) ?? []
            let events = OutlookWebParser.events(fromScreenLabels: labels)
                .filter { $0.start >= from && $0.start < to }
            if !events.isEmpty { return events }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return []
    }

    /// Waits until Outlook has downloaded a meeting starting in `[from, to)` and gone quiet
    /// for 3 s, up to 15 s. Returns whether that data arrived.
    private func waitForCalendarData(after before: Int, from: Date, to: Date) async -> Bool {
        // Not wall-clock time: the clock set back during a read would keep it waiting for hours.
        let deadline = ContinuousClock.now + .seconds(15)
        var checked = before
        var loaded = false
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isSignInPage(webView.url) { return false }
            if !loaded, captured.count > checked {
                loaded = OutlookWebParser.events(fromPayloads: Array(captured[checked...]))
                    .contains { $0.start >= from && $0.start < to }
                checked = captured.count
            }
            if loaded, let last = lastCaptureAt, ContinuousClock.now - last > .seconds(3) { return true }
        }
        return loaded
    }

    /// Clicks Outlook's "next week" button, waiting up to 5 s for it to render. Clicked once
    /// only: each click moves another week.
    private func clickNextWeek() async -> Bool {
        let script = """
        (() => {
          const button = [...document.querySelectorAll('button[aria-label]')]
            // The label can carry the target dates: "Go to next week October 26–30, 2026".
            .find(b => /^(go to )?next (work ?)?week\\b/i.test(b.getAttribute('aria-label').trim()));
          if (!button) return false;
          button.click();
          return true;
        })()
        """
        for _ in 0..<5 {
            if (try? await webView.evaluateJavaScript(script) as? Bool) == true { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    private enum WeekViewResult { case alreadyWeek, switched, failed }

    /// Makes sure Outlook shows a week (Week or Work week view), clicking its "Week" view
    /// button when it opened in another view (Day, Month, ...). Decided from the page, not
    /// the URL: right after loading, the URL is still the one requested. Clicking also changes
    /// the view Outlook remembers for the account. Waits up to 30 s in all.
    private func ensureWeekView() async -> WeekViewResult {
        let script = """
        (() => {
          const labels = [...document.querySelectorAll('button[aria-label]')]
            .map(b => [b, b.getAttribute('aria-label').trim()]);
          if (labels.some(([, l]) => /^(go to )?next (work ?)?week\\b/i.test(l))) return 'week';
          // "Go to today" is there once the calendar has loaded, in every view.
          if (!labels.some(([, l]) => /^go to today\\b/i.test(l))) return 'loading';
          const week = labels.find(([, l]) => l.toLowerCase() === 'week');
          if (!week) return 'no-week-button';
          week[0].click();
          return 'clicked';
        })()
        """
        var clicked = false
        for _ in 0..<30 {
            if isSignInPage(webView.url) { return .failed }
            switch (try? await webView.evaluateJavaScript(script) as? String) ?? "loading" {
            case "week": return clicked ? .switched : .alreadyWeek
            case "clicked": clicked = true
            case "no-week-button": return .failed
            default: break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .failed
    }

    private func isSignInPage(_ url: URL?) -> Bool {
        url.map(Self.isSignInHost) ?? false
    }

    /// Microsoft's sign-in hosts: work and personal accounts, and the security key page.
    static let signInHosts = ["login.microsoftonline.com", "login.microsoft.com", "login.live.com"]

    static func isSignInHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        // Only a running fetch reads the captured data, and it starts from none. Between
        // fetches Outlook goes on loading data in the background (and mail, if the user reads
        // it in the window), which would otherwise pile up here for as long as the app runs.
        guard isFetching, let text = message.body as? String else { return }
        captured.append(Data(text.utf8))
        lastCaptureAt = .now
    }

    fileprivate func receiveSecurityKey(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        Task { reply(await securityKey.handle(message, window: window), nil) }
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
    /// endpoints to the app. Also remembers the URL and headers of Outlook's own service calls
    /// (which carry its sign-in) for `loadItems`, which `detailsScript` calls. Read-only:
    /// requests are passed through unchanged.
    ///
    /// Everything stays inside the script; the page only gets `window.__calsync.loadItems`.
    /// In particular the remembered sign-in headers are not left on `window`, where any
    /// script in the page could read them.
    static let captureScript = #"""
    (function () {
      if (window.__calsync) return;
      // graphql carries the weeks after the first one. SaveCalendarView only stores which
      // view is shown and has no events.
      const RX = /^(?!.*savecalendarview).*(calendarview|finditem|calendaritem|startupdata|\/events|graphql)/i;
      const MAX = 8 * 1024 * 1024;
      const nativeFetch = window.fetch;
      // Outlook's last service call: { url, headers }.
      let service = null;

      function send(text) {
        try {
          if (!text || text.length > MAX) return;
          const c = text.trimStart()[0];
          if (c !== '{' && c !== '[') return;
          window.webkit.messageHandlers.calsync.postMessage(text);
        } catch (e) {}
      }
      function remember(url, headers) {
        try {
          if (!/\/service\.svc/i.test(String(url))) return;
          service = { url: new URL(String(url), location.href).href, headers: headers };
        } catch (e) {}
      }
      function headersOf(source, into) {
        try { if (source) new Headers(source).forEach((v, k) => { into[k] = v; }); } catch (e) {}
        return into;
      }

      if (nativeFetch) {
        window.fetch = function (input, init) {
          const p = nativeFetch.apply(this, arguments);
          try {
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            if (RX.test(url)) p.then(r => r.clone().text()).then(send).catch(() => {});
            const headers = headersOf(input && input.headers, {});
            remember(url, headersOf(init && init.headers, headers));
          } catch (e) {}
          return p;
        };
      }

      // Per request: { url, headers }, until it is sent.
      const requests = new WeakMap();
      const proto = XMLHttpRequest.prototype;
      const open = proto.open, setHeader = proto.setRequestHeader, xsend = proto.send;
      proto.open = function (method, url) {
        try { requests.set(this, { url: String(url), headers: {} }); } catch (e) {}
        return open.apply(this, arguments);
      };
      proto.setRequestHeader = function (name, value) {
        try {
          const request = requests.get(this);
          if (request) request.headers[String(name).toLowerCase()] = String(value);
        } catch (e) {}
        return setHeader.apply(this, arguments);
      };
      proto.send = function () {
        try {
          const request = requests.get(this);
          if (request) {
            requests.delete(this);
            remember(request.url, request.headers);
            if (RX.test(request.url)) {
              this.addEventListener('load', function () {
                try {
                  if (this.responseType === '' || this.responseType === 'text') send(this.responseText);
                  else if (this.responseType === 'json') send(JSON.stringify(this.response));
                } catch (e) {}
              });
            }
          }
        } catch (e) {}
        return xsend.apply(this, arguments);
      };

      // Asks Outlook's service for the meetings in full, as Outlook itself does when a
      // meeting is opened, with the sign-in headers of its last service call. Sends the
      // request in the body and, if Outlook refuses that, in the x-owa-urlpostdata header that
      // newer Outlook versions use. Returns the response texts, or none without a service
      // call to take the sign-in from.
      async function loadItems(ids) {
        if (!service || !ids || !ids.length) return [];
        const url = new URL(service.url);
        url.searchParams.set('action', 'GetItem');
        url.searchParams.delete('n');
        const base = {};
        for (const [k, v] of Object.entries(service.headers)) {
          if (!/^(content-length|content-type|action|x-owa-urlpostdata|x-owa-actionname|x-owa-actionid)$/i.test(k)) base[k] = v;
        }
        base['action'] = 'GetItem';
        base['content-type'] = 'application/json; charset=utf-8';
        async function post(headers, body) {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 20000);
          try {
            const r = await nativeFetch.call(window, url.href, {
              method: 'POST', headers, body, credentials: 'include', signal: controller.signal,
            });
            return r.ok ? await r.text() : null;
          } catch (e) {
            return null;
          } finally {
            clearTimeout(timer);
          }
        }
        const out = [];
        const size = 10;
        for (let i = 0; i < ids.length; i += size) {
          const request = JSON.stringify({
            __type: 'GetItemJsonRequest:#Exchange',
            Header: { __type: 'JsonRequestHeaders:#Exchange', RequestServerVersion: 'Exchange2013' },
            Body: {
              __type: 'GetItemRequest:#Exchange',
              ItemShape: { __type: 'ItemResponseShape:#Exchange', BaseShape: 'AllProperties', BodyType: 'HTML' },
              ItemIds: ids.slice(i, i + size).map(id => ({ __type: 'ItemId:#Exchange', Id: id })),
            },
          });
          const headers = withNewIDs(base);
          let text = await post(headers, request);
          if (text === null) {
            text = await post(Object.assign({}, headers, { 'x-owa-urlpostdata': encodeURIComponent(request) }), '');
          }
          if (text) out.push(text);
        }
        return out;
      }
      // A correlation or request id identifies one request, so each request gets its own
      // rather than the id of the call the headers were taken from.
      function withNewIDs(headers) {
        const out = Object.assign({}, headers);
        for (const k of Object.keys(out)) {
          if (/correlation|request-?id/i.test(k) && /^[0-9a-f-]{36}$/i.test(out[k])) out[k] = crypto.randomUUID();
        }
        return out;
      }

      window.__calsync = { loadItems };
    })();
    """#

    /// Runs in the page (`callAsyncJavaScript`, with `ids`): loads the meetings in full
    /// through `captureScript`'s `loadItems`. Returns the response texts.
    static let detailsScript = #"""
    const api = window.__calsync;
    return api ? await api.loadItems(ids) : [];
    """#

    /// Gives Microsoft's sign-in pages a `navigator.credentials.get` that works: WebKit's own
    /// fails at once in the web view, which isn't a browser Apple has approved. Requests for a
    /// security key go to `SecurityKeySignIn`, which signs with a USB key itself; the answer is
    /// handed to the page the way a browser would hand it. Other pages keep WebKit's.
    static let webAuthnScript = #"""
    (function () {
      const hosts = \#(signInHostsJSON);
      const host = location.hostname.toLowerCase();
      if (location.protocol !== 'https:' || !hosts.some(h => host === h || host.endsWith('.' + h))) return;
      const container = navigator.credentials;
      const handler = window.webkit && window.webkit.messageHandlers.calsyncSecurityKey;
      if (!container || !handler) return;
      const nativeGet = container.get;

      function bytes(source) {
        if (source instanceof ArrayBuffer) return new Uint8Array(source);
        if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
        throw new TypeError('Expected an ArrayBuffer or a view of one');
      }
      function encode(source) {
        let text = '';
        for (const b of bytes(source)) text += String.fromCharCode(b);
        return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      }
      function decode(text) {
        const binary = atob(text.replace(/-/g, '+').replace(/_/g, '/'));
        const out = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
        return out.buffer;
      }
      function abortError(signal) {
        return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
      }
      function credential(reply) {
        const json = {
          id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: 'cross-platform',
          response: {
            clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData,
            signature: reply.signature, userHandle: reply.userHandle || null,
          },
          clientExtensionResults: {},
        };
        return {
          id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: 'cross-platform',
          response: {
            clientDataJSON: decode(reply.clientDataJSON), authenticatorData: decode(reply.authenticatorData),
            signature: decode(reply.signature), userHandle: reply.userHandle ? decode(reply.userHandle) : null,
          },
          getClientExtensionResults() { return {}; },
          toJSON() { return json; },
        };
      }

      function get(options) {
        if (!options || !options.publicKey) return nativeGet.apply(container, arguments);
        const signal = options.signal;
        if (signal && signal.aborted) return Promise.reject(abortError(signal));
        // Autofill, which a security key can't answer: wait, like a browser with no passkey to
        // offer, until the page gives up on it.
        if (options.mediation === 'conditional') {
          return new Promise((resolve, reject) => {
            if (signal) signal.addEventListener('abort', () => reject(abortError(signal)), { once: true });
          });
        }
        let request;
        try {
          const publicKey = options.publicKey;
          request = {
            challenge: encode(publicKey.challenge),
            rpId: publicKey.rpId ? String(publicKey.rpId) : null,
            allowCredentials: (publicKey.allowCredentials || []).map(c => encode(c.id)),
            userVerification: publicKey.userVerification || 'preferred',
            timeout: typeof publicKey.timeout === 'number' ? publicKey.timeout : null,
          };
        } catch (e) {
          return Promise.reject(e);
        }
        return new Promise((resolve, reject) => {
          function onAbort() {
            handler.postMessage({ action: 'cancel' }).catch(() => {});
            reject(abortError(signal));
          }
          // Once answered, an abort (the page tidying up later) must not cancel a newer request.
          function done() {
            if (signal) signal.removeEventListener('abort', onAbort);
          }
          if (signal) signal.addEventListener('abort', onAbort, { once: true });
          handler.postMessage({ action: 'get', request }).then(reply => {
            done();
            if (reply && reply.error) reject(new DOMException(reply.message || '', reply.error));
            else resolve(credential(reply));
          }, e => {
            done();
            reject(new DOMException(String((e && e.message) || e), 'NotAllowedError'));
          });
        });
      }
      Object.defineProperty(container, 'get', { value: get, configurable: true, writable: true });

      // No passkey on this Mac to offer, as far as the page is concerned.
      const PKC = window.PublicKeyCredential;
      for (const name of ['isUserVerifyingPlatformAuthenticatorAvailable', 'isConditionalMediationAvailable']) {
        try {
          if (PKC) Object.defineProperty(PKC, name, { value: () => Promise.resolve(false), configurable: true, writable: true });
        } catch (e) {}
      }
    })();
    """#

    /// Takes the WebAuthn API out of every other page and frame. There the web view has it but
    /// can't use it, and a sign-in page that looks for it before offering a security key or
    /// passkey (a federated one, like Okta or ADFS) then offers its other methods instead.
    static let hideWebAuthnScript = #"""
    (function () {
      const hosts = \#(signInHostsJSON);
      const host = location.hostname.toLowerCase();
      const signIn = location.protocol === 'https:' && hosts.some(h => host === h || host.endsWith('.' + h));
      if (signIn && window.top === window) return;
      try { delete window.PublicKeyCredential; } catch (e) {}
    })();
    """#

    private static var signInHostsJSON: String {
        "[" + signInHosts.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }
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

/// `WeakMessageHandler` for messages the page waits for an answer to.
private final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: OutlookWebSource?

    init(_ target: OutlookWebSource) { self.target = target }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let target else { return replyHandler(nil, "The Outlook window is closed.") }
            target.receiveSecurityKey(message, reply: replyHandler)
        }
    }
}
