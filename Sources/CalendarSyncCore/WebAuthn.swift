import Foundation

// What the Outlook window needs to sign in with a security key (a YubiKey, say) itself: WebKit
// gives the WebAuthn API only to browsers Apple has approved, so the app talks to the key over
// USB the way browsers do. Specs: WebAuthn Level 2 (the page side) and CTAP 2.1 (the key side).

/// The page side of WebAuthn: what a browser builds around the key's answer.
public enum WebAuthn {
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// The client data the key signs (by its hash), serialized the way browsers do it
    /// (WebAuthn Level 3, section 5.8.1.1), e.g.
    /// `{"type":"webauthn.get","challenge":"…","origin":"https://login.microsoft.com","crossOrigin":false}`.
    public static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        let json = #"{"type":\#(jsonString(type)),"challenge":\#(jsonString(base64URL(challenge))),"#
            + #""origin":\#(jsonString(origin)),"crossOrigin":false}"#
        return Data(json.utf8)
    }

    private static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Whether a page on `host` may ask for credentials of the relying party `rpID`: the host
    /// itself or a domain it is under. Without the public suffix list, a bare top-level domain
    /// is refused and nothing more; the caller only lets Microsoft's sign-in hosts through.
    public static func isRPID(_ rpID: String, validFor host: String) -> Bool {
        let rpID = rpID.lowercased(), host = host.lowercased()
        guard rpID.contains("."), !rpID.hasPrefix("."), !rpID.hasSuffix(".") else { return false }
        return host == rpID || host.hasSuffix("." + rpID)
    }
}

/// CTAPHID, how security key messages travel over USB HID (CTAP 2.1, section 11.2.4): in
/// 64-byte packets on a channel, one init packet and then continuation packets.
public enum CTAPHID {
    public static let packetSize = 64
    /// The channel for asking the key for a channel of one's own.
    public static let broadcastChannel: UInt32 = 0xFFFF_FFFF

    // Commands.
    public static let initialize: UInt8 = 0x06
    public static let cbor: UInt8 = 0x10
    public static let cancel: UInt8 = 0x11
    public static let keepalive: UInt8 = 0x3B
    public static let error: UInt8 = 0x3F

    static let initPayload = packetSize - 7
    static let continuationPayload = packetSize - 5
    public static let maxPayload = initPayload + 128 * continuationPayload

    public enum FramingError: Error, Equatable {
        case tooLong
        case outOfSequence
    }

    /// Splits a message into packets, zero-padded to `packetSize`.
    public static func packets(channel: UInt32, command: UInt8, payload: Data) throws -> [Data] {
        guard payload.count <= maxPayload else { throw FramingError.tooLong }
        let bytes = [UInt8](payload)
        let channelBytes = withUnsafeBytes(of: channel.bigEndian) { [UInt8]($0) }
        var packets = [channelBytes + [command | 0x80, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
            + bytes.prefix(initPayload)]
        var offset = initPayload
        var sequence: UInt8 = 0
        while offset < bytes.count {
            packets.append(channelBytes + [sequence] + bytes[offset..<min(offset + continuationPayload, bytes.count)])
            offset += continuationPayload
            sequence += 1
        }
        return packets.map { Data($0 + [UInt8](repeating: 0, count: packetSize - $0.count)) }
    }

    /// Joins the packets of the key's answer on one channel back into a message.
    public struct Assembler {
        public let channel: UInt32
        private var command: UInt8 = 0
        private var length = 0
        private var payload: [UInt8] = []
        private var sequence: UInt8 = 0
        private var started = false

        public init(channel: UInt32) { self.channel = channel }

        /// Adds a packet. Returns the command and payload once the message is complete.
        /// Packets on other channels (for other apps) are left out.
        public mutating func add(_ packet: Data) throws -> (command: UInt8, payload: Data)? {
            let bytes = [UInt8](packet)
            guard bytes.count >= 7,
                  bytes[0..<4].reduce(0, { $0 << 8 | UInt32($1) }) == channel else { return nil }
            if bytes[4] & 0x80 != 0 {
                command = bytes[4] & 0x7F
                length = Int(bytes[5]) << 8 | Int(bytes[6])
                guard length <= CTAPHID.maxPayload else { throw FramingError.tooLong }
                payload = Array(bytes[7...].prefix(length))
                sequence = 0
                started = true
            } else {
                guard started, bytes[4] == sequence else { throw FramingError.outOfSequence }
                payload += bytes[5...].prefix(length - payload.count)
                sequence += 1
            }
            guard payload.count == length else { return nil }
            started = false
            return (command, Data(payload))
        }
    }
}

/// CTAP2, the security key's own protocol: a command byte, then CBOR maps with integer keys.
public enum CTAP2 {
    public static let getAssertionCommand: UInt8 = 0x02
    public static let getInfoCommand: UInt8 = 0x04
    public static let clientPINCommand: UInt8 = 0x06

    /// A status other than success, as the key answers it.
    public struct Status: Error, Equatable {
        public let code: UInt8
        public init(_ code: UInt8) { self.code = code }

        public static let operationDenied = Status(0x27)
        public static let keepaliveCancel = Status(0x2D)
        public static let noCredentials = Status(0x2E)
        public static let userActionTimeout = Status(0x2F)
        public static let pinInvalid = Status(0x31)
        public static let pinBlocked = Status(0x32)
        public static let pinAuthInvalid = Status(0x33)
        public static let pinAuthBlocked = Status(0x34)
        public static let pinNotSet = Status(0x35)
        public static let pinRequired = Status(0x36)
        public static let actionTimeout = Status(0x3A)
        public static let uvBlocked = Status(0x3C)
    }

    public enum ResponseError: Error, Equatable {
        case empty
        case missing(String)
    }

    /// The CBOR of a successful answer, or nil if it has none. Throws the status otherwise.
    public static func decodeResponse(_ response: Data) throws -> CBOR? {
        guard let status = response.first else { throw ResponseError.empty }
        guard status == 0 else { throw Status(status) }
        return response.count > 1 ? try CBOR.decode(response.dropFirst()) : nil
    }

    static func request(_ command: UInt8, _ parameters: [Int: CBOR]) -> Data {
        Data([command]) + CBOR.map(Dictionary(uniqueKeysWithValues: parameters.map { (.int($0.key), $0.value) })).encoded
    }

    // MARK: - authenticatorGetInfo

    public static func getInfo() -> Data { Data([getInfoCommand]) }

    /// What `getInfo` reports that matters here.
    public struct Info: Equatable {
        public var options: [String: Bool] = [:]
        public var pinUvAuthProtocols: [Int] = []

        public init(_ response: CBOR?) {
            if case .map(let map)? = response?[4] {
                for (key, value) in map {
                    if let key = key.stringValue, let value = value.boolValue { options[key] = value }
                }
            }
            // CTAP 2.0 keys may leave the list out: they have protocol one.
            pinUvAuthProtocols = response?[6]?.arrayValue?.compactMap(\.intValue) ?? [1]
        }
    }

    // MARK: - authenticatorGetAssertion

    /// - Parameters:
    ///   - options: e.g. `["uv": true]` for a key that checks the user itself (a fingerprint).
    ///   - pinUvAuth: proof of the PIN (see `PINProtocolOne.authenticate`) and its protocol.
    public static func getAssertion(
        rpID: String, clientDataHash: Data, allowList: [Data], options: [String: Bool] = [:],
        pinUvAuth: (param: Data, protocol: Int)? = nil
    ) -> Data {
        var parameters: [Int: CBOR] = [1: .text(rpID), 2: .bytes(clientDataHash)]
        if !allowList.isEmpty {
            parameters[3] = .array(allowList.map { .map([.text("id"): .bytes($0), .text("type"): .text("public-key")]) })
        }
        if !options.isEmpty {
            parameters[5] = .map(Dictionary(uniqueKeysWithValues: options.map { (.text($0.key), .bool($0.value)) }))
        }
        if let pinUvAuth {
            parameters[6] = .bytes(pinUvAuth.param)
            parameters[7] = .int(pinUvAuth.protocol)
        }
        return request(getAssertionCommand, parameters)
    }

    public struct Assertion: Equatable {
        public var credentialID: Data
        public var authenticatorData: Data
        public var signature: Data
        public var userHandle: Data?

        /// `allowList` as sent: the key can leave out the credential when it had one choice.
        public init(_ response: CBOR?, allowList: [Data]) throws {
            guard let response else { throw ResponseError.empty }
            guard let id = response[1]?["id"]?.dataValue ?? (allowList.count == 1 ? allowList[0] : nil) else {
                throw ResponseError.missing("credential")
            }
            guard let authenticatorData = response[2]?.dataValue else { throw ResponseError.missing("authData") }
            guard let signature = response[3]?.dataValue else { throw ResponseError.missing("signature") }
            credentialID = id
            self.authenticatorData = authenticatorData
            self.signature = signature
            userHandle = response[4]?["id"]?.dataValue
        }
    }

    // MARK: - authenticatorClientPIN

    public enum ClientPIN {
        public static func getRetries(protocol version: Int) -> Data {
            request(clientPINCommand, [1: .int(version), 2: .int(1)])
        }

        public static func getKeyAgreement(protocol version: Int) -> Data {
            request(clientPINCommand, [1: .int(version), 2: .int(2)])
        }

        /// For keys before CTAP 2.1: a token for any request.
        public static func getPinToken(protocol version: Int, keyAgreement: CBOR, pinHashEnc: Data) -> Data {
            request(clientPINCommand, [1: .int(version), 2: .int(5), 3: keyAgreement, 6: .bytes(pinHashEnc)])
        }

        /// The `permissions` bit for getAssertion.
        public static let getAssertionPermission = 0x02

        /// For CTAP 2.1 keys (getInfo option `pinUvAuthToken`): a token for `permissions` on
        /// `rpID` only.
        public static func getPinUvAuthTokenUsingPin(
            protocol version: Int, keyAgreement: CBOR, pinHashEnc: Data, permissions: Int, rpID: String
        ) -> Data {
            request(clientPINCommand, [
                1: .int(version), 2: .int(9), 3: keyAgreement, 6: .bytes(pinHashEnc),
                9: .int(permissions), 10: .text(rpID),
            ])
        }
    }

    /// A P-256 key agreement key as COSE (RFC 9053), the way CTAP2 sends it.
    public static func coseKey(x: Data, y: Data) -> CBOR {
        .map([.int(1): .int(2), .int(3): .int(-25), .int(-1): .int(1), .int(-2): .bytes(x), .int(-3): .bytes(y)])
    }

    public static func coseKeyCoordinates(_ key: CBOR) -> (x: Data, y: Data)? {
        guard let x = key[-2]?.dataValue, let y = key[-3]?.dataValue, x.count == 32, y.count == 32 else { return nil }
        return (x, y)
    }
}

#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit

/// PIN/UV auth protocol one (CTAP 2.1, section 6.5.6): how the PIN reaches the key encrypted
/// and how a request proves it. Every security key with a PIN supports it.
public struct PINProtocolOne {
    public static let version = 1

    public enum Failure: Error, Equatable {
        case badKey
        case badLength
        case cryptor(Int32)
    }

    /// Our half of the key agreement, to send to the key with the request.
    public let platformKey: CBOR
    private let sharedSecret: Data

    /// - Parameter authenticatorKey: the key's half, as `getKeyAgreement` returns it.
    public init(authenticatorKey: CBOR, privateKey: P256.KeyAgreement.PrivateKey = .init()) throws {
        guard let peer = CTAP2.coseKeyCoordinates(authenticatorKey),
              let peerKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: peer.x + peer.y),
              let z = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else { throw Failure.badKey }
        // The secret is SHA-256 of the shared point's x coordinate, which is what CryptoKit gives.
        sharedSecret = z.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
        let own = privateKey.publicKey.rawRepresentation
        platformKey = CTAP2.coseKey(x: Data(own.prefix(32)), y: Data(own.suffix(32)))
    }

    /// The PIN as the key checks it: the first 16 bytes of its SHA-256, encrypted.
    public func pinHashEnc(pin: String) throws -> Data {
        try encrypt(Data(SHA256.hash(data: Data(pin.utf8)).prefix(16)))
    }

    public func encrypt(_ data: Data) throws -> Data { try Self.aesCBC(CCOperation(kCCEncrypt), key: sharedSecret, data: data) }
    public func decrypt(_ data: Data) throws -> Data { try Self.aesCBC(CCOperation(kCCDecrypt), key: sharedSecret, data: data) }

    /// Proves the PIN for one request: the first 16 bytes of HMAC-SHA-256 with the PIN token.
    public static func authenticate(token: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: token)).prefix(16))
    }

    /// AES-256-CBC with a zero IV and no padding, as protocol one prescribes.
    static func aesCBC(_ operation: CCOperation, key: Data, data: Data) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0 else { throw Failure.badLength }
        var out = Data(count: data.count)
        var moved = 0
        let iv = Data(count: kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { data in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, key.baseAddress, key.count,
                                iv.baseAddress, data.baseAddress, data.count, out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.cryptor(status) }
        return out.prefix(moved)
    }
}
#endif
