import XCTest
@testable import CalendarSyncCore
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
#endif

final class WebAuthnTests: XCTestCase {
    func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - CBOR

    /// Examples from RFC 8949, Appendix A.
    func testCBORMatchesTheRFCExamples() throws {
        let examples: [(CBOR, String)] = [
            (.int(0), "00"),
            (.int(23), "17"),
            (.int(24), "1818"),
            (.int(1000), "1903e8"),
            (.int(1_000_000), "1a000f4240"),
            (.unsigned(1_000_000_000_000), "1b000000e8d4a51000"),
            (.int(-1), "20"),
            (.int(-100), "3863"),
            (.int(-1000), "3903e7"),
            (.bool(false), "f4"),
            (.bool(true), "f5"),
            (.null, "f6"),
            (.bytes(hex("01020304")), "4401020304"),
            (.text(""), "60"),
            (.text("IETF"), "6449455446"),
            (.text("\u{00fc}"), "62c3bc"),
            (.array([.int(1), .array([.int(2), .int(3)]), .array([.int(4), .int(5)])]), "8301820203820405"),
            (.map([.int(1): .int(2), .int(3): .int(4)]), "a201020304"),
            (.map([.text("a"): .int(1), .text("b"): .array([.int(2), .int(3)])]), "a26161016162820203"),
        ]
        for (item, encoded) in examples {
            XCTAssertEqual(item.encoded, hex(encoded), encoded)
            XCTAssertEqual(try CBOR.decode(hex(encoded)), item, encoded)
        }
    }

    /// CTAP2's canonical order: shorter keys first, so integers before text, and then by bytes.
    func testCBORMapsAreCanonicallyOrdered() {
        let map = CBOR.map([.text("type"): .int(0), .text("id"): .int(0), .int(-1): .int(0), .int(10): .int(0), .int(1): .int(0)])
        XCTAssertEqual(map.encoded, hex("a5" + "0100" + "0a00" + "2000" + "62696400" + "647479706500"))
        // Major type before length: 24 (two bytes, unsigned) comes before -1 (one byte, negative).
        // RFC 7049's length-first order would put -1 first.
        XCTAssertEqual(CBOR.map([.int(-1): .int(0), .int(24): .int(0)]).encoded, hex("a2" + "181800" + "2000"))
        XCTAssertEqual(CBOR.map([.text(""): .int(0), .int(1000): .int(0)]).encoded, hex("a2" + "1903e800" + "6000"))
    }

    func testCBORRefusesBrokenInput() {
        XCTAssertThrowsError(try CBOR.decode(hex("62c3"))) { XCTAssertEqual($0 as? CBOR.DecodingError, .truncated) }
        XCTAssertThrowsError(try CBOR.decode(hex("0000"))) { XCTAssertEqual($0 as? CBOR.DecodingError, .trailingBytes) }
        XCTAssertThrowsError(try CBOR.decode(hex("9f01ff"))) { XCTAssertEqual($0 as? CBOR.DecodingError, .unsupported(0x9F)) }
        XCTAssertThrowsError(try CBOR.decode(hex("62c328"))) { XCTAssertEqual($0 as? CBOR.DecodingError, .invalidText) }
        XCTAssertThrowsError(try CBOR.decode(hex("9bffffffffffffffff"))) { XCTAssertEqual($0 as? CBOR.DecodingError, .truncated) }
    }

    // MARK: - CTAPHID

    func testCTAPHIDSplitsAndJoinsMessages() throws {
        for size in [0, 1, 57, 58, 57 + 59, 57 + 59 + 1, 1000] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            let packets = try CTAPHID.packets(channel: 0x0102_0304, command: CTAPHID.cbor, payload: payload)
            XCTAssertTrue(packets.allSatisfy { $0.count == 64 })
            XCTAssertEqual(packets.count, 1 + max(0, (size - 57 + 58) / 59), "\(size) bytes")
            XCTAssertEqual([UInt8](packets[0].prefix(7)), [1, 2, 3, 4, 0x90, UInt8(size >> 8), UInt8(size & 0xFF)])

            var assembler = CTAPHID.Assembler(channel: 0x0102_0304)
            var message: (command: UInt8, payload: Data)?
            for packet in packets { message = try assembler.add(packet) }
            XCTAssertEqual(message?.command, CTAPHID.cbor)
            XCTAssertEqual(message?.payload, payload)
        }
    }

    func testCTAPHIDAssemblerIgnoresOtherChannelsAndChecksTheSequence() throws {
        let packets = try CTAPHID.packets(channel: 7, command: CTAPHID.cbor, payload: Data(count: 100))
        var assembler = CTAPHID.Assembler(channel: 7)
        let other = try CTAPHID.packets(channel: 8, command: CTAPHID.cbor, payload: Data([1]))[0]
        XCTAssertNil(try assembler.add(other))
        XCTAssertNil(try assembler.add(packets[0]))
        var skipped = packets[1]
        skipped[4] = 1
        XCTAssertThrowsError(try assembler.add(skipped)) { XCTAssertEqual($0 as? CTAPHID.FramingError, .outOfSequence) }
        XCTAssertThrowsError(try CTAPHID.packets(channel: 7, command: CTAPHID.cbor, payload: Data(count: 7610)))
    }

    // MARK: - CTAP2

    func testGetAssertionRequest() throws {
        let request = CTAP2.getAssertion(
            rpID: "login.microsoft.com", clientDataHash: Data(repeating: 0xAA, count: 32),
            allowList: [Data([1, 2])], pinUvAuth: (Data(repeating: 0xBB, count: 16), 1))
        XCTAssertEqual(request.first, 0x02)
        let decoded = try CBOR.decode(request.dropFirst())
        XCTAssertEqual(decoded[1], .text("login.microsoft.com"))
        XCTAssertEqual(decoded[2], .bytes(Data(repeating: 0xAA, count: 32)))
        XCTAssertEqual(decoded[3], .array([.map([.text("id"): .bytes(Data([1, 2])), .text("type"): .text("public-key")])]))
        XCTAssertNil(decoded[5])
        XCTAssertEqual(decoded[6], .bytes(Data(repeating: 0xBB, count: 16)))
        XCTAssertEqual(decoded[7], .int(1))
        // Keys in canonical order, as the key expects: 1, 2, 3, 6, 7.
        XCTAssertEqual([UInt8](request.prefix(4)), [0x02, 0xA5, 0x01, 0x73])
    }

    func testAssertionResponse() throws {
        let response = Data([0]) + CBOR.map([
            .int(1): .map([.text("id"): .bytes(Data([9, 9])), .text("type"): .text("public-key")]),
            .int(2): .bytes(Data([1])),
            .int(3): .bytes(Data([2])),
            .int(4): .map([.text("id"): .bytes(Data([3]))]),
        ]).encoded
        let assertion = try CTAP2.Assertion(CTAP2.decodeResponse(response), allowList: [])
        XCTAssertEqual(assertion.credentialID, Data([9, 9]))
        XCTAssertEqual(assertion.authenticatorData, Data([1]))
        XCTAssertEqual(assertion.signature, Data([2]))
        XCTAssertEqual(assertion.userHandle, Data([3]))

        // With one credential allowed, the key can leave it out.
        let short = CBOR.map([.int(2): .bytes(Data([1])), .int(3): .bytes(Data([2]))])
        XCTAssertEqual(try CTAP2.Assertion(short, allowList: [Data([5])]).credentialID, Data([5]))
        XCTAssertNil(try CTAP2.Assertion(short, allowList: [Data([5])]).userHandle)
        XCTAssertThrowsError(try CTAP2.Assertion(short, allowList: []))
    }

    func testResponseStatus() {
        XCTAssertThrowsError(try CTAP2.decodeResponse(Data([0x31]))) { XCTAssertEqual($0 as? CTAP2.Status, .pinInvalid) }
        XCTAssertThrowsError(try CTAP2.decodeResponse(Data()))
        XCTAssertNil(try CTAP2.decodeResponse(Data([0])))
    }

    func testInfo() throws {
        let info = CTAP2.Info(.map([
            .int(1): .array([.text("FIDO_2_0")]),
            .int(4): .map([.text("rk"): .bool(true), .text("clientPin"): .bool(true), .text("up"): .bool(true)]),
            .int(6): .array([.int(2), .int(1)]),
        ]))
        XCTAssertEqual(info.options["clientPin"], true)
        XCTAssertNil(info.options["uv"])
        XCTAssertEqual(info.pinUvAuthProtocols, [2, 1])
        // A CTAP 2.0 key can leave the list out.
        XCTAssertEqual(CTAP2.Info(.map([.int(4): .map([.text("clientPin"): .bool(true)])])).pinUvAuthProtocols, [1])
    }

    func testClientPINRequests() throws {
        XCTAssertEqual(CTAP2.ClientPIN.getRetries(protocol: 1), hex("06a201010201"))
        XCTAssertEqual(CTAP2.ClientPIN.getKeyAgreement(protocol: 1), hex("06a201010202"))
        let key = CTAP2.coseKey(x: Data(count: 32), y: Data(count: 32))
        let request = try CBOR.decode(CTAP2.ClientPIN.getPinToken(protocol: 1, keyAgreement: key, pinHashEnc: Data(count: 16)).dropFirst())
        XCTAssertEqual(request[2], .int(5))
        XCTAssertEqual(request[3], key)
        XCTAssertEqual(request[6], .bytes(Data(count: 16)))

        let scoped = try CBOR.decode(CTAP2.ClientPIN.getPinUvAuthTokenUsingPin(
            protocol: 1, keyAgreement: key, pinHashEnc: Data(count: 16),
            permissions: CTAP2.ClientPIN.getAssertionPermission, rpID: "login.microsoft.com").dropFirst())
        XCTAssertEqual(scoped[1], .int(1))
        XCTAssertEqual(scoped[2], .int(9))
        XCTAssertEqual(scoped[3], key)
        XCTAssertEqual(scoped[6], .bytes(Data(count: 16)))
        XCTAssertEqual(scoped[9], .int(2))
        XCTAssertEqual(scoped[10], .text("login.microsoft.com"))
    }

    // MARK: - WebAuthn

    func testBase64URL() {
        XCTAssertEqual(WebAuthn.base64URL(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(WebAuthn.base64URL(Data([1])), "AQ")
        XCTAssertEqual(WebAuthn.data(base64URL: "AQ"), Data([1]))
        XCTAssertEqual(WebAuthn.data(base64URL: "-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertNil(WebAuthn.data(base64URL: "*"))
    }

    func testClientDataJSON() {
        let json = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: Data([1, 2, 3]), origin: "https://login.microsoft.com")
        XCTAssertEqual(
            String(decoding: json, as: UTF8.self),
            #"{"type":"webauthn.get","challenge":"AQID","origin":"https://login.microsoft.com","crossOrigin":false}"#)
        let odd = WebAuthn.clientDataJSON(type: "a\"b\\c\n", challenge: Data(), origin: "")
        XCTAssertEqual(String(decoding: odd, as: UTF8.self), #"{"type":"a\"b\\c\u000a","challenge":"","origin":"","crossOrigin":false}"#)
    }

    func testRPID() {
        XCTAssertTrue(WebAuthn.isRPID("login.microsoft.com", validFor: "login.microsoft.com"))
        XCTAssertTrue(WebAuthn.isRPID("microsoft.com", validFor: "login.microsoft.com"))
        XCTAssertTrue(WebAuthn.isRPID("Login.Microsoft.com", validFor: "login.microsoft.com"))
        XCTAssertFalse(WebAuthn.isRPID("evil.com", validFor: "login.microsoft.com"))
        XCTAssertFalse(WebAuthn.isRPID("soft.com", validFor: "login.microsoft.com"))
        XCTAssertFalse(WebAuthn.isRPID("com", validFor: "login.microsoft.com"))
        XCTAssertFalse(WebAuthn.isRPID(".microsoft.com", validFor: "login.microsoft.com"))
        XCTAssertFalse(WebAuthn.isRPID("login.microsoft.com", validFor: "microsoft.com"))
    }

    #if canImport(CryptoKit) && canImport(CommonCrypto)
    /// Plays the key's side of the PIN exchange.
    func testPINProtocolOneAgreesWithTheKey() throws {
        let keySide = P256.KeyAgreement.PrivateKey()
        let keyRaw = keySide.publicKey.rawRepresentation
        let platform = try PINProtocolOne(
            authenticatorKey: CTAP2.coseKey(x: Data(keyRaw.prefix(32)), y: Data(keyRaw.suffix(32))))

        let platformPoint = try XCTUnwrap(CTAP2.coseKeyCoordinates(platform.platformKey))
        let shared = try keySide.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(rawRepresentation: platformPoint.x + platformPoint.y))
        let secret = shared.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }

        // The key decrypts the PIN hash...
        let pinHash = try PINProtocolOne.aesCBC(CCOperation(kCCDecrypt), key: secret, data: platform.pinHashEnc(pin: "123456"))
        XCTAssertEqual(pinHash, Data(SHA256.hash(data: Data("123456".utf8)).prefix(16)))
        // ...and sends a token back encrypted, which we read.
        let token = Data((0..<32).map { UInt8($0) })
        let sent = try PINProtocolOne.aesCBC(CCOperation(kCCEncrypt), key: secret, data: token)
        XCTAssertNotEqual(sent, token)
        XCTAssertEqual(try platform.decrypt(sent), token)
    }

    /// HMAC-SHA-256 test case 2 from RFC 4231, cut to 16 bytes.
    func testPINAuthentication() {
        XCTAssertEqual(
            PINProtocolOne.authenticate(token: Data("Jefe".utf8), message: Data("what do ya want for nothing?".utf8)),
            hex("5bdcc146bf60754e6a042426089575c7"))
    }

    func testPINProtocolOneRefusesBadInput() {
        XCTAssertThrowsError(try PINProtocolOne(authenticatorKey: .null))
        XCTAssertThrowsError(try PINProtocolOne(authenticatorKey: CTAP2.coseKey(x: Data(count: 32), y: Data(count: 32))))
        XCTAssertThrowsError(try PINProtocolOne.aesCBC(CCOperation(kCCEncrypt), key: Data(count: 32), data: Data(count: 15)))
    }
    #endif
}
