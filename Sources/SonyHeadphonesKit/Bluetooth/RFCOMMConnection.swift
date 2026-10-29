import Foundation
import IOBluetooth

public enum RFCOMMConnectionEvent: Sendable {
    case opened
    case closed
    case dataReceived([UInt8])
    case failed(String)
}

/// Typed failure information for recovery decisions.  It is intentionally distinct
/// from the user-facing string so callers never need to parse Bluetooth errors.
public enum RFCOMMConnectionFailureKind: Equatable, Sendable {
    case controlRefused
    case other
}

/// A one-shot sample of the failure stage and ACL state at failure time.
public struct RFCOMMConnectionFailureContext: Equatable, Sendable {
    public let kind: RFCOMMConnectionFailureKind
    public let isConnected: Bool

    public init(kind: RFCOMMConnectionFailureKind, isConnected: Bool) {
        self.kind = kind
        self.isConnected = isConnected
    }
}

/// The transport surface used by `HeadphonesController`. Keeping this deliberately
/// small lets clients test protocol behaviour without an IOBluetooth device.
// public for KitTests (CLT has no XCTest)
public protocol RFCOMMConnectionProviding: AnyObject {
    var onEvent: ((RFCOMMConnectionEvent) -> Void)? { get set }
    func connect(toDeviceAddress address: String)
    func disconnect()
    func write(_ bytes: [UInt8])
    func consumeFailureContext() -> RFCOMMConnectionFailureContext?
    func bounceACL()
}

public extension RFCOMMConnectionProviding {
    func consumeFailureContext() -> RFCOMMConnectionFailureContext? { nil }
    func bounceACL() {}
}

/// A short description of a paired classic-Bluetooth device, for UI display / manual
/// device selection. Deliberately doesn't carry the `IOBluetoothDevice` itself so it can
/// cross to SwiftUI without any Objective-C bridging concerns.
public struct PairedDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: String // Bluetooth address string
    public let name: String
    /// Whether macOS currently holds a Bluetooth link to the device. Pairing alone says
    /// nothing about reachability: a headset that is off, out of range, or attached only
    /// to the user's phone stays paired and looks identical without this.
    public let isConnected: Bool
    public init(id: String, name: String, isConnected: Bool) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
    }
}

/// Opens and manages a classic-Bluetooth RFCOMM channel to a paired Sony headset,
/// using UUID-based SDP discovery:
/// look up the vendor service UUID on the already-paired device, read back the RFCOMM
/// channel ID from the SDP record, then open that channel directly. There is no fixed
/// channel number -- it's assigned by the headset and must be discovered per-connection.
///
/// - Important: An embedding executable must keep `RunLoop.main` running (for example,
///   with `RunLoop.main.run()`). IOBluetooth delivers RFCOMM data callbacks through the
///   CFRunLoop; `dispatchMain()` alone does not deliver inbound Bluetooth data.
public final class RFCOMMConnection: NSObject, RFCOMMConnectionProviding {
    public static let serviceUUIDv1 = "96CC203E-5068-46AD-B32D-E316F5E069BA"
    public static let serviceUUIDv2 = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

    public var onEvent: ((RFCOMMConnectionEvent) -> Void)?

    private var device: IOBluetoothDevice?
    /// All access to `channel`, including `writeSync`, close, delegate changes, and
    /// identity checks from IOBluetooth callbacks, is serialized on this queue. Public
    /// state/events are still delivered on the main queue; IOBluetooth's channel object
    /// must not be touched concurrently from either side.
    private let channelQueue = DispatchQueue(label: "SonyHeadphonesKit.RFCOMMConnection.channel")
    private var channel: IOBluetoothRFCOMMChannel?
    /// Identifies the current connection attempt. Delayed channel callbacks must use
    /// this rather than device identity because IOBluetooth can reuse one object for
    /// multiple attempts to the same address.
    private var connectionGeneration: UInt64 = 0
    /// A new ACL (including the normal post-wake reconnect path) needs a little
    /// time before the XM6 reliably accepts its first RFCOMM write. Reusing an
    /// existing ACL does not.
    private var needsPostOpenSettle = false
    /// Guards the one-shot retry when a channel open fails outright.
    private var didRetryChannelOpen = false
    /// Written and consumed on the main queue, alongside failure events.
    private var pendingFailureContext: RFCOMMConnectionFailureContext?

    public override init() {
        super.init()
    }

    /// Internal visibility lets the package tests assert that a distinct transport
    /// queue continues to exist without needing Bluetooth hardware.
    /// Test-only visibility for proving that teardown invalidates delayed callbacks.
    // public for KitTests (CLT has no XCTest)
    public var connectionGenerationForTesting: UInt64 { channelQueue.sync { connectionGeneration } }
    public static func acceptsWriteLength(_ count: Int) -> Bool { count <= Int(UInt16.max) }
    // public for KitTests (CLT has no XCTest)
    public static func openSettleDelay(linkWasAlreadyEstablished: Bool) -> TimeInterval {
        linkWasAlreadyEstablished ? 0 : 0.15
    }

    /// Kept separate so the delayed-open race has a deterministic unit-test seam.
    /// A reconnect may reuse an object identity, so delayed callbacks use generation
    /// rather than channel identity as their authority.
    // public for KitTests (CLT has no XCTest)
    public static func isCurrentAttempt(delayedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        delayedGeneration == currentGeneration
    }

    /// Applies the delayed-open identity check immediately before emitting an open
    /// event. Keeping the decision and the emission together prevents a caller from
    /// accidentally scheduling an unconditional delayed open.
    // public for KitTests (CLT has no XCTest)
    public static func emitDelayedOpenIfCurrent(
        delayedGeneration: UInt64,
        currentGeneration: UInt64,
        emit: () -> Void
    ) {
        guard isCurrentAttempt(delayedGeneration: delayedGeneration, currentGeneration: currentGeneration) else { return }
        emit()
    }

    // MARK: - Discovery

    public static func pairedDevices() -> [PairedDeviceInfo] {
        guard let raw = IOBluetoothDevice.pairedDevices() else { return [] }
        return raw.compactMap { obj in
            guard let device = obj as? IOBluetoothDevice, let address = device.addressString else { return nil }
            let name = device.name ?? device.nameOrAddress ?? address
            return PairedDeviceInfo(id: address, name: name, isConnected: device.isConnected())
        }
    }

    private static func device(forAddress address: String) -> IOBluetoothDevice? {
        // Prefer the registry's own object for this address: it carries the paired-device
        // state, where a freshly constructed one starts blank.
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
           let match = paired.first(where: { $0.addressString?.caseInsensitiveCompare(address) == .orderedSame }) {
            return match
        }
        return IOBluetoothDevice(addressString: address)
    }

    // MARK: - Connect

    public func connect(toDeviceAddress address: String) {
        DispatchQueue.main.async { [self] in
            self.channelQueue.sync { self.connectionGeneration &+= 1 }
            guard let device = Self.device(forAddress: address) else {
                emitFailure("Could not resolve Bluetooth address \(address)")
                return
            }
            self.device = device
            self.didRetryChannelOpen = false
            self.needsPostOpenSettle = !device.isConnected()

            if device.isConnected() {
                beginServiceDiscovery(on: device)
            } else {
                let result = device.openConnection(self)
                if result != kIOReturnSuccess {
                    emitFailure("Failed to open Bluetooth connection (code \(result))", device: device)
                }
                // else: wait for connectionComplete(_:status:) delegate callback
            }
        }
    }

    public func consumeFailureContext() -> RFCOMMConnectionFailureContext? {
        let context = pendingFailureContext
        pendingFailureContext = nil
        return context
    }

    /// Closes the RFCOMM channel and ACL for a recovery bounce. Every caller must
    /// explicitly reacquire after the close; this transport does not reopen on its own.
    public func bounceACL() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let device = self.device else { return }
            self.channelQueue.sync {
                self.connectionGeneration &+= 1
                self.detachChannel()
            }
            _ = device.closeConnection()
            self.didRetryChannelOpen = false
            self.needsPostOpenSettle = true
        }
    }

    public func disconnect() {
        DispatchQueue.main.async { [self] in
            // Detach before closing: `close()` is asynchronous, and a channel still tearing
            // down would otherwise fire `rfcommChannelClosed` after the next connect has
            // begun, knocking the fresh session straight back to "disconnected".
            channelQueue.sync { self.connectionGeneration &+= 1 }
            channelQueue.async { [weak self] in
                guard let self else { return }
                self.detachChannel()
            }
            device = nil
        }
    }

    private func detachChannel() {
        // Detach before closing: `close()` is asynchronous.
        channel?.setDelegate(nil)
        _ = channel?.close()
        channel = nil
    }

    private func post(_ event: RFCOMMConnectionEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    public func write(_ bytes: [UInt8]) {
        channelQueue.async { [weak self] in
            guard let self else { return }
            guard Self.acceptsWriteLength(bytes.count) else {
                self.post(.failed("Write exceeds RFCOMM maximum frame length"))
                return
            }
            guard let channel = self.channel else {
                self.post(.failed("Tried to write with no open channel"))
                return
            }
            var mutableBytes = bytes
            let result = mutableBytes.withUnsafeMutableBytes { rawBuffer -> IOReturn in
                guard let base = rawBuffer.baseAddress else { return kIOReturnBadArgument }
                return channel.writeSync(base, length: UInt16(rawBuffer.count))
            }
            if result != kIOReturnSuccess {
                self.post(.failed("Write failed (code \(result))"))
            }
        }
    }

    // MARK: - Service discovery

    private func beginServiceDiscovery(on device: IOBluetoothDevice) {
        // Prefer a cached SDP record from prior pairing (fast path); fall back to a
        // live SDP query if the vendor service hasn't been cached yet.
        if let record = vendorServiceRecord(on: device) {
            openChannel(device: device, record: record)
            return
        }

        // Deliberately the unfiltered query: the `uuids:` overload reports success and
        // then never calls `sdpQueryComplete`, so a connection that has to fall back to
        // live discovery hangs forever instead of failing.
        let result = device.performSDPQuery(self)
        if result != kIOReturnSuccess {
            emitFailure("SDP query failed to start (code \(result))", device: device)
        }
    }

    private func serviceRecord(on device: IOBluetoothDevice, uuidString: String) -> IOBluetoothSDPServiceRecord? {
        guard let uuid = Self.sdpUUID(uuidString) else { return nil }
        return device.getServiceRecord(for: uuid)
    }

    private func vendorServiceRecord(on device: IOBluetoothDevice) -> IOBluetoothSDPServiceRecord? {
        serviceRecord(on: device, uuidString: Self.serviceUUIDv2)
            ?? serviceRecord(on: device, uuidString: Self.serviceUUIDv1)
    }

    private func openChannel(device: IOBluetoothDevice, record: IOBluetoothSDPServiceRecord) {
        var channelID: BluetoothRFCOMMChannelID = 0
        let status = record.getRFCOMMChannelID(&channelID)
        guard status == kIOReturnSuccess else {
            emitFailure("Sony control service not found. Make sure the headphones are connected as an audio device first, then try again.", device: device)
            return
        }

        var newChannel: IOBluetoothRFCOMMChannel?
        let openStatus = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        if openStatus != kIOReturnSuccess {
            // The headset serves one control channel at a time; just after a reconnect the
            // previous one can still be tearing down. Worth one more try before giving up.
            guard !didRetryChannelOpen else {
                emitFailure(
                    "Failed to open RFCOMM channel (code \(openStatus))",
                    kind: .controlRefused,
                    device: device
                )
                return
            }
            didRetryChannelOpen = true
            let generation = channelQueue.sync { connectionGeneration }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let currentGeneration = self.channelQueue.sync { self.connectionGeneration }
                guard Self.isCurrentAttempt(
                    delayedGeneration: generation,
                    currentGeneration: currentGeneration
                ) else { return }
                self.openChannel(device: device, record: record)
            }
            return
        }
        // IOBluetooth delivers open-complete through the main run loop after
        // `openRFCOMMChannelAsync` returns, so this store precedes it.
        channelQueue.sync { [weak self] in
            guard let self else { return }
            self.channel = newChannel
        }
    }

    private static func sdpUUID(_ uuidString: String) -> IOBluetoothSDPUUID? {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { raw in
            IOBluetoothSDPUUID(bytes: raw.baseAddress, length: raw.count)
        }
    }

    private func emitFailure(
        _ message: String,
        kind: RFCOMMConnectionFailureKind = .other,
        device: IOBluetoothDevice? = nil
    ) {
        pendingFailureContext = RFCOMMConnectionFailureContext(
            kind: kind,
            isConnected: device?.isConnected() ?? false
        )
        // emitFailure runs on main; deliver synchronously so the controller tags the failure
        // with the attempt that failed, before a queued block can start a newer attempt.
        onEvent?(.failed(message))
    }
}

// MARK: - IOBluetoothDevice async callbacks (informal delegate, matched by selector)

extension RFCOMMConnection {
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        // Callbacks for a device we've moved on from belong to an abandoned attempt.
        guard let device, device === self.device else { return }
        guard status == kIOReturnSuccess else {
            emitFailure("Failed to connect to headphones (code \(status))", device: device)
            return
        }
        beginServiceDiscovery(on: device)
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device, device === self.device else { return }
        guard status == kIOReturnSuccess else {
            emitFailure("Service discovery failed (code \(status)). Make sure the headphones are connected as an audio device first.", device: device)
            return
        }
        if let record = vendorServiceRecord(on: device) {
            openChannel(device: device, record: record)
        } else if (device.services as? [IOBluetoothSDPServiceRecord])?.isEmpty ?? true {
            // Discovery "succeeded" but returned no services at all -- not even the audio
            // profiles the headset is demonstrably using. That is what a missing Bluetooth
            // privilege looks like from in here: the calls are accepted and quietly dropped.
            emitFailure("macOS reported no Bluetooth services for these headphones. Check that XM6ConnectAgent is enabled under System Settings \u{2192} Privacy & Security \u{2192} Bluetooth.", device: device)
        } else {
            emitFailure("Couldn't find the Sony control service on this device.", device: device)
        }
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension RFCOMMConnection: IOBluetoothRFCOMMChannelDelegate {
    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        channelQueue.async { [weak self] in
            guard let self, rfcommChannel === self.channel else { return } // stale channel from an old attempt
            let generation = self.connectionGeneration
            guard error == kIOReturnSuccess else {
                DispatchQueue.main.async {
                    self.emitFailure(
                        "RFCOMM channel failed to open (code \(error))",
                        kind: .controlRefused,
                        device: self.device
                    )
                }
                return
            }
            // A freshly established ACL can drop the first write after pairing/wake;
            // an already-established ACL must not pay that tax. INIT retains its
            // protocol-level retry as the final safety net.
            let delay = Self.openSettleDelay(linkWasAlreadyEstablished: !self.needsPostOpenSettle)
            self.channelQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                Self.emitDelayedOpenIfCurrent(
                    delayedGeneration: generation,
                    currentGeneration: self.connectionGeneration
                ) {
                    self.post(.opened)
                }
            }
        }
    }

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        channelQueue.async { [weak self] in
            guard let self, rfcommChannel === self.channel else { return }
            self.post(.dataReceived(bytes))
        }
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        channelQueue.async { [weak self] in
            guard let self, rfcommChannel === self.channel else { return } // stale channel from an old attempt
            self.connectionGeneration &+= 1
            self.channel = nil
            self.post(.closed)
        }
    }
}
