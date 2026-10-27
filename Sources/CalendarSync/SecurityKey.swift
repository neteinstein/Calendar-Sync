import CalendarSyncCore
import Foundation
import IOKit.hid

/// A FIDO security key (a YubiKey, say) on USB, spoken to directly over CTAPHID the way
/// browsers do it. macOS lets any app open one without asking.
///
/// Its calls block until the key answers (a touch can take a while), so make them off the main
/// thread. `cancel()` is the exception: call it from anywhere to stop the request under way.
final class SecurityKey: @unchecked Sendable {
    enum Failure: Error {
        case notFound
        case cannotOpen
        case noCTAP2
        case timeout
        case io(IOReturn)
        case hidError(UInt8)
    }

    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "Calendar Sync security key")
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CTAPHID.packetSize)
    private let lock = NSLock()
    /// Packets from the key, waiting to be read. Under `lock`.
    private var packets: [Data] = []
    /// Set once by `cancel()`, for good: every request after it fails. Under `lock`.
    private var cancelRequested = false
    private let arrived = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)
    private var channel = CTAPHID.broadcastChannel
    private var isOpen = false

    private init(device: IOHIDDevice) { self.device = device }

    deinit { buffer.deallocate() }

    /// The first security key connected, if any.
    static func first() -> SecurityKey? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // FIDO's own usage page; other HID devices on the same key (the OTP keyboard) don't match.
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDPrimaryUsagePageKey: 0xF1D0, kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            return nil
        }
        return SecurityKey(device: device)
    }

    /// Opens the key and gets a channel on it.
    func open() throws {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw Failure.cannotOpen
        }
        isOpen = true
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, CTAPHID.packetSize,
            { context, _, _, _, _, report, length in
                guard let context else { return }
                let key = Unmanaged<SecurityKey>.fromOpaque(context).takeUnretainedValue()
                key.received(Data(bytes: report, count: length))
            },
            Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceSetCancelHandler(device) { [cancelled] in cancelled.signal() }
        IOHIDDeviceActivate(device)

        var nonce = Data(count: 8)
        for i in nonce.indices { nonce[i] = .random(in: 0...255) }
        // Another app asking for a channel at the same time gets its answer on the same channel.
        let reply = try transact(CTAPHID.initialize, nonce, timeout: 3) { $0.prefix(8) == nonce }
        guard reply.count >= 17 else { throw Failure.noCTAP2 }
        channel = reply[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
        // Capability flag 0x04: the key speaks CTAP2 (a U2F-only key doesn't).
        guard reply[reply.startIndex + 16] & 0x04 != 0 else { throw Failure.noCTAP2 }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceCancel(device)
        // The callback must not run once the buffer and self are gone.
        _ = cancelled.wait(timeout: .now() + 2)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Sends a CTAP2 request (see `CTAP2`) and returns the answer's CBOR. Throws the key's
    /// status if it isn't success.
    func send(_ request: Data, timeout: TimeInterval = 10) throws -> CBOR? {
        try CTAP2.decodeResponse(transact(CTAPHID.cbor, request, timeout: timeout))
    }

    /// Stops the request under way, and any request made later: the key answers with
    /// `CTAP2.Status.keepaliveCancel`, or `send` throws it without asking the key.
    func cancel() {
        lock.withLock { cancelRequested = true }
    }

    // MARK: - CTAPHID

    private func received(_ packet: Data) {
        lock.withLock { packets.append(packet) }
        arrived.signal()
    }

    private func write(_ packet: Data) throws {
        let result = packet.withUnsafeBytes {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw Failure.io(result) }
    }

    /// - Parameter accept: whether an answer is the one to this request; others are skipped.
    private func transact(
        _ command: UInt8, _ payload: Data, timeout: TimeInterval, accept: (Data) -> Bool = { _ in true }
    ) throws -> Data {
        if lock.withLock({ cancelRequested }) { throw CTAP2.Status.keepaliveCancel }
        // Anything left over belongs to an earlier request.
        lock.withLock { packets.removeAll() }
        for packet in try CTAPHID.packets(channel: channel, command: command, payload: payload) {
            try write(packet)
        }
        var assembler = CTAPHID.Assembler(channel: channel)
        let deadline = Date().addingTimeInterval(timeout)
        var sentCancel = false
        func sendCancel() throws {
            guard !sentCancel else { return }
            sentCancel = true
            for packet in try CTAPHID.packets(channel: channel, command: CTAPHID.cancel, payload: Data()) {
                try write(packet)
            }
        }
        while true {
            // Checked on every packet too: while it waits for a touch, the key sends keepalives.
            if Date() > deadline {
                // Stops the key blinking for a touch nobody waits for any more.
                try? sendCancel()
                throw Failure.timeout
            }
            if lock.withLock({ cancelRequested }) { try sendCancel() }
            // The semaphore can count a packet that was dropped above, so the queue decides.
            guard arrived.wait(timeout: .now() + 0.1) == .success,
                  let packet = lock.withLock({ packets.isEmpty ? nil : packets.removeFirst() }),
                  let message = try assembler.add(packet)
            else { continue }
            switch message.command {
            // Still working, or waiting for a touch.
            case CTAPHID.keepalive: continue
            case CTAPHID.error: throw Failure.hidError(message.payload.first ?? 0)
            case command:
                if accept(message.payload) { return message.payload }
            default: throw Failure.hidError(0x7F)
            }
        }
    }
}
