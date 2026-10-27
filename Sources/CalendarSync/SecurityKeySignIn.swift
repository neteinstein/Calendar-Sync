import AppKit
import CalendarSyncCore
import CryptoKit
import WebKit

/// Answers the security key requests of Microsoft's sign-in pages in the Outlook window.
///
/// WebKit gives the WebAuthn API only to browsers Apple has approved, so in the window
/// `navigator.credentials.get` fails at once, and an account that signs in with a security key
/// (a YubiKey, say) can't sign in. `OutlookWebSource.webAuthnScript` gives the sign-in pages
/// a `navigator.credentials.get` that asks this class instead, which does what a browser does:
/// asks for the key's PIN, has the user touch the key, and hands the page the key's signature.
///
/// Signing in only (`get`): registering a key is done in a browser. USB keys only, the first
/// one connected.
@MainActor
final class SecurityKeySignIn {
    /// The key and the window while a request is under way, for `cancel()`.
    private var key: SecurityKey?
    private weak var window: NSWindow?
    /// The request's PIN or touch sheet, shown or still queued behind another sheet.
    private weak var sheet: NSWindow?
    private var isRunning = false
    private var isCancelled = false

    /// Answers one message from `webAuthnScript`: the reply for the page.
    func handle(_ message: WKScriptMessage, window: NSWindow?) async -> [String: Any] {
        let body = message.body as? [String: Any] ?? [:]
        switch body["action"] as? String {
        case "get":
            return await get(body["request"] as? [String: Any] ?? [:], from: message.frameInfo, window: window)
        case "cancel":
            guard Self.isSignInPage(message.frameInfo) else {
                return Self.failure("SecurityError", "Security keys work on Microsoft's sign-in pages only.")
            }
            cancel()
            return [:]
        default:
            return Self.failure("NotSupportedError", "Unknown request.")
        }
    }

    /// Stops the request under way, if any, wherever it is: at the PIN, waiting for a touch, or
    /// in between.
    func cancel() {
        guard isRunning else { return }
        isCancelled = true
        key?.cancel()
        // This request's own sheet: the one attached can be another's, like an earlier error.
        if let window, let sheet, sheet.sheetParent != nil { window.endSheet(sheet, returnCode: .cancel) }
    }

    /// Whether a message comes from the main frame of a Microsoft sign-in page, as WebKit knows
    /// it, not as the page tells it.
    private static func isSignInPage(_ frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        guard frame.isMainFrame, origin.protocol == "https", let url = URL(string: "https://\(origin.host)") else {
            return false
        }
        return OutlookWebSource.isSignInHost(url)
    }

    private func get(_ request: [String: Any], from frame: WKFrameInfo, window: NSWindow?) async -> [String: Any] {
        guard Self.isSignInPage(frame) else {
            return Self.failure("SecurityError", "Security keys work on Microsoft's sign-in pages only.")
        }
        let origin = frame.securityOrigin
        let rpID = request["rpId"] as? String ?? origin.host
        guard WebAuthn.isRPID(rpID, validFor: origin.host) else {
            return Self.failure("SecurityError", "The relying party doesn't match this page.")
        }
        guard let challenge = (request["challenge"] as? String).flatMap(WebAuthn.data(base64URL:)) else {
            return Self.failure("NotAllowedError", "The request has no challenge.")
        }
        guard let window, window.isVisible else {
            return Self.failure("NotAllowedError", "The Outlook window isn't open.")
        }
        guard !isRunning else {
            return Self.failure("NotAllowedError", "Another security key request is under way.")
        }
        isRunning = true
        isCancelled = false
        self.window = window
        defer {
            isRunning = false
            self.window = nil
            sheet = nil
        }

        let allowList = (request["allowCredentials"] as? [String] ?? []).compactMap(WebAuthn.data(base64URL:))
        let userVerification = request["userVerification"] as? String ?? "preferred"
        // The page's timeout is in milliseconds. A touch needs some time whatever it asks.
        let timeout = min(max((request["timeout"] as? Double ?? 120_000) / 1000, 30), 600)
        let originText = origin.port == 0 || origin.port == 443 ? "https://\(origin.host)" : "https://\(origin.host):\(origin.port)"
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: originText)

        do {
            let assertion = try await assert(
                rpID: rpID, clientDataHash: Data(SHA256.hash(data: clientData)), allowList: allowList,
                userVerification: userVerification, timeout: timeout, window: window)
            return [
                "id": WebAuthn.base64URL(assertion.credentialID),
                "clientDataJSON": WebAuthn.base64URL(clientData),
                "authenticatorData": WebAuthn.base64URL(assertion.authenticatorData),
                "signature": WebAuthn.base64URL(assertion.signature),
                "userHandle": assertion.userHandle.map(WebAuthn.base64URL) ?? NSNull(),
            ]
        } catch {
            // Cancelled: whatever the key said after that, nobody waits for it, and the window may
            // be closed for good.
            guard !isCancelled, let text = Self.message(for: error) else {
                return Self.failure("NotAllowedError", "Cancelled.")
            }
            NSLog("Calendar Sync: security key sign-in failed: \(error)")
            // The page gets its answer now, not once the alert is closed.
            Self.show(text, on: window)
            return Self.failure("NotAllowedError", text)
        }
    }

    private func assert(
        rpID: String, clientDataHash: Data, allowList: [Data], userVerification: String,
        timeout: TimeInterval, window: NSWindow
    ) async throws -> CTAP2.Assertion {
        guard let key = SecurityKey.first() else { throw SecurityKey.Failure.notFound }
        self.key = key
        // Cancelled before there was a key to tell: every request to it now fails.
        if isCancelled { key.cancel() }
        defer {
            self.key = nil
            key.close()
        }
        let info = try await Self.background {
            try key.open()
            return CTAP2.Info(try key.send(CTAP2.getInfo()))
        }

        var options: [String: Bool] = [:]
        var pinUvAuth: (param: Data, protocol: Int)?
        if userVerification != "discouraged", info.options["clientPin"] == true {
            guard info.pinUvAuthProtocols.contains(PINProtocolOne.version) else { throw Problem.unsupportedPIN }
            let token = try await pinToken(key, info: info, rpID: rpID, window: window)
            pinUvAuth = (PINProtocolOne.authenticate(token: token, message: clientDataHash), PINProtocolOne.version)
        } else if userVerification != "discouraged", info.options["uv"] == true {
            // The key checks the user itself (a fingerprint).
            options["uv"] = true
        } else if userVerification == "required" {
            throw CTAP2.Status.pinNotSet
        }

        try checkCancelled()
        let touch = NSAlert()
        touch.messageText = "Touch your security key"
        touch.informativeText = "Touch the key when it blinks to sign in to Microsoft."
        touch.addButton(withTitle: "Cancel")
        sheet = touch.window
        touch.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { key.cancel() }
        }
        defer {
            // Unless Cancel already closed it.
            if touch.window.sheetParent != nil { window.endSheet(touch.window, returnCode: .abort) }
        }
        let request = CTAP2.getAssertion(
            rpID: rpID, clientDataHash: clientDataHash, allowList: allowList, options: options, pinUvAuth: pinUvAuth)
        let response = try await Self.background { try key.send(request, timeout: timeout) }
        return try CTAP2.Assertion(response, allowList: allowList)
    }

    private func checkCancelled() throws {
        if isCancelled { throw CTAP2.Status.keepaliveCancel }
    }

    /// Asks for the PIN until the key takes it, and returns the key's PIN token for signing in
    /// to `rpID`.
    private func pinToken(_ key: SecurityKey, info: CTAP2.Info, rpID: String, window: NSWindow) async throws -> Data {
        // A CTAP 2.1 key gives tokens for one purpose and one site; older keys give one for all.
        let scoped = info.options["pinUvAuthToken"] == true
        var note: String?
        while true {
            try checkCancelled()
            guard let pin = await askPIN(note: note, on: window) else { throw CTAP2.Status.keepaliveCancel }
            guard pin.count >= 4 else {
                note = "The PIN has at least 4 characters."
                continue
            }
            do {
                return try await Self.background {
                    // A fresh key agreement each time: the key changes its own after a wrong PIN.
                    guard let agreement = try key.send(CTAP2.ClientPIN.getKeyAgreement(protocol: PINProtocolOne.version))?[1] else {
                        throw CTAP2.ResponseError.missing("keyAgreement")
                    }
                    let pinProtocol = try PINProtocolOne(authenticatorKey: agreement)
                    let pinHashEnc = try pinProtocol.pinHashEnc(pin: pin)
                    let response = try key.send(scoped
                        ? CTAP2.ClientPIN.getPinUvAuthTokenUsingPin(
                            protocol: PINProtocolOne.version, keyAgreement: pinProtocol.platformKey,
                            pinHashEnc: pinHashEnc, permissions: CTAP2.ClientPIN.getAssertionPermission, rpID: rpID)
                        : CTAP2.ClientPIN.getPinToken(
                            protocol: PINProtocolOne.version, keyAgreement: pinProtocol.platformKey,
                            pinHashEnc: pinHashEnc))
                    guard let token = response?[2]?.dataValue else { throw CTAP2.ResponseError.missing("pinToken") }
                    return try pinProtocol.decrypt(token)
                }
            } catch let status as CTAP2.Status where status == .pinInvalid {
                let retries = try? await Self.background {
                    try key.send(CTAP2.ClientPIN.getRetries(protocol: PINProtocolOne.version))?[3]?.intValue
                }
                note = "Wrong PIN." + (retries.map { " \($0) tries left." } ?? "")
            }
        }
    }

    // MARK: - Messages

    private enum Problem: Error {
        case unsupportedPIN
    }

    /// What to tell the user, or nil if they cancelled.
    static func message(for error: Error) -> String? {
        if let status = error as? CTAP2.Status {
            switch status {
            case .keepaliveCancel, .operationDenied:
                return nil
            case .userActionTimeout, .actionTimeout:
                return "The security key wasn't touched in time. Try again."
            case .noCredentials:
                return "This security key isn't registered for this account."
            case .pinBlocked:
                return "The security key is locked after too many wrong PINs. Reset the key to use it again."
            case .pinAuthBlocked:
                return "Too many wrong PINs. Disconnect the security key, connect it again, then try again."
            case .pinNotSet, .pinRequired:
                return "Microsoft needs your security key's PIN, and the key has none. Set a PIN for the key, then try again."
            case .pinAuthInvalid:
                return "The security key didn't accept the PIN check. Disconnect the key, connect it again, then try again."
            case .uvBlocked:
                return "The security key can't check your fingerprint any more. Use its PIN instead."
            default:
                return String(format: "The security key refused the request (error 0x%02X).", status.code)
            }
        }
        switch error {
        case SecurityKey.Failure.notFound:
            return "No security key found. Connect your security key, then try again."
        case SecurityKey.Failure.cannotOpen:
            return "Couldn't open the security key. Quit other apps that use it, then try again."
        case SecurityKey.Failure.noCTAP2:
            return "This security key doesn't support signing in to Microsoft (it needs FIDO2)."
        case SecurityKey.Failure.timeout:
            return "The security key wasn't touched in time. Try again."
        case Problem.unsupportedPIN:
            return "This security key's PIN works in a way that Calendar Sync doesn't support yet."
        default:
            return "Couldn't use the security key (\(error))."
        }
    }

    private static func failure(_ name: String, _ message: String) -> [String: Any] {
        ["error": name, "message": message]
    }

    private func askPIN(note: String?, on window: NSWindow) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter your security key's PIN"
        alert.informativeText = note ?? "Microsoft asks for your security key to sign in."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        sheet = alert.window
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private static func show(_ message: String, on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Couldn't sign in with the security key"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Runs blocking key I/O off the main thread.
    private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
