import Foundation
import IOKit
import IOUSBHost
import os

/// Errors at the MTP boundary. Surfaced to the user through
/// `BookDeviceError`, so messages say what to do, not what broke.
nonisolated enum MTPError: LocalizedError {
    case deviceNotFound
    /// Another process holds the USB interface — Calibre, Android File
    /// Transfer, OpenMTP. macOS gives the interface to one owner at a time.
    case deviceBusy
    case transport(String)
    case response(operation: UInt16, code: UInt16)
    case malformed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "The Kindle is no longer connected."
        case .deviceBusy:
            "Another app is using the Kindle. Quit Calibre, Android File Transfer, or OpenMTP and try again."
        case .transport(let detail):
            "USB transfer failed (\(detail)). Unplug the Kindle, plug it back in, and try again."
        case .response(let op, let code):
            String(format: "The Kindle refused the request (operation 0x%04X, response 0x%04X).", op, code)
        case .malformed(let detail):
            "The Kindle sent an unexpected reply (\(detail))."
        case .notFound(let path):
            "Couldn't find \(path) on the Kindle."
        }
    }
}

/// A connected MTP device as seen in the IORegistry — found without opening
/// it, so detection never contends with an in-flight transfer.
nonisolated struct MTPDeviceDescriptor: Sendable, Equatable {
    let serial: String
}

/// One MTP session over raw USB (`IOUSBHost`). Apple's ImageCaptureCore
/// only claims class-6 "Still Image" interfaces; the Kindle 11th generation
/// (2024 release) exposes a vendor-specific (class 255) interface named
/// "MTP", so we speak the protocol ourselves.
///
/// Usage is always `MTPConnection.withSession(serial:) { conn in … }`: open,
/// do the work, close. Sessions are short-lived on purpose — no lifecycle to
/// manage across plug/unplug, and nothing is held open when the user pulls
/// the cable. Sessions run one at a time on a dedicated thread
/// (`MTPSessionQueue`) because the USB interface is exclusive and its I/O
/// blocks; `withSession` is the async way in.
nonisolated final class MTPConnection {
    static let amazonVendorID = 0x1949

    /// Process-wide state carried between sessions, owned by the queue that
    /// serialises them.
    fileprivate struct SessionState {
        /// IORegistry entry ID of the USB interface whose last session ended
        /// mid-transaction; recover before the next OpenSession on it so it
        /// doesn't read a stale reply. A replugged Kindle gets a new entry
        /// and starts clean, so it's skipped.
        var needsRecovery: UInt64?
        /// Serials whose firmware refused or garbled GetObjectPropList, so
        /// listings go one GetObjectInfo per object.
        var propListUnsupported: Set<String> = []
    }

    private let service: io_service_t
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let maxPacketSize: Int
    private var transactionID: UInt32 = 0
    /// The transaction whose command went out but whose response hasn't come
    /// back. Non-nil after a throw means the device and host disagree about
    /// where the conversation is — no further commands until `recover()`.
    private var inFlight: UInt32?
    /// Whether `children` may fetch a whole folder's metadata in one
    /// GetObjectPropList round trip.
    private var canUsePropList = true
    /// An I/O error said the device is gone (unplugged). Recovery is
    /// pointless then — there's nothing to talk to.
    private var sawDeviceGone = false
    /// Bytes read past the end of the previous container. Devices end each
    /// container with a short packet, so this is normally empty.
    private var pending = Data()

    private static let commandTimeout: TimeInterval = 10
    /// Generous: after a large SendObject the Kindle can take a while to
    /// flush before it sends the response.
    private static let responseTimeout: TimeInterval = 120
    /// How long `recover()` waits for each stale read before deciding the
    /// device has nothing more queued.
    private static let drainTimeout: TimeInterval = 0.5
    private static let readChunk = 256 * 1024
    private static let writeChunk = 1024 * 1024

    // MARK: - Discovery

    /// Amazon devices exposing an MTP interface whose product string says
    /// "Kindle" (Fire tablets share the vendor ID but aren't e-readers).
    static func connectedKindles() -> [MTPDeviceDescriptor] {
        var results: [MTPDeviceDescriptor] = []
        forEachMTPInterface { service in
            guard
                let product = parentProperty(service, "kUSBProductString") as? String,
                product.localizedCaseInsensitiveContains("kindle"),
                let serial = parentProperty(service, "kUSBSerialNumberString") as? String
            else { return false }
            results.append(MTPDeviceDescriptor(serial: serial))
            return false
        }
        return results
    }

    /// Opens a session on the Kindle with this USB serial, runs `body`, and
    /// closes it again — on success and on throw. If `body` fails mid-
    /// transaction the session isn't closed (the device would read the
    /// CloseSession as payload); it's recovered instead, now and again before
    /// the next session.
    ///
    /// Sessions run one at a time on `MTPSessionQueue`'s own thread: callers
    /// suspend while they wait their turn and while the USB I/O blocks, so a
    /// minutes-long upload never ties up Swift's cooperative pool.
    static func withSession<T: Sendable>(
        serial: String, _ body: @Sendable (MTPConnection) throws(MTPError) -> T
    ) async throws(MTPError) -> T {
        try await MTPSessionQueue.shared.withSession(serial: serial, body)
    }

    fileprivate static func runSession<T>(
        serial: String, state: inout SessionState,
        _ body: (MTPConnection) throws(MTPError) -> T
    ) throws(MTPError) -> T {
        var found: io_service_t = 0
        forEachMTPInterface { service in
            guard parentProperty(service, "kUSBSerialNumberString") as? String == serial
            else { return false }
            IOObjectRetain(service)
            found = service
            return true
        }
        guard found != 0 else { throw .deviceNotFound }
        defer { IOObjectRelease(found) }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(found, &entryID)

        let connection = try MTPConnection(service: found)
        defer { connection.interface.destroy() }
        if state.needsRecovery == entryID { connection.recover() }
        state.needsRecovery = nil
        connection.canUsePropList = !state.propListUnsupported.contains(serial)
        defer { if !connection.canUsePropList { state.propListUnsupported.insert(serial) } }

        do throws(MTPError) {
            try connection.openSession()
            let result = try body(connection)
            if !connection.endSession() { state.needsRecovery = entryID }
            return result
        } catch {
            if !connection.endSession() { state.needsRecovery = entryID }
            // Say "disconnected", not "USB transfer failed", when the
            // cable was pulled.
            if case .transport(let detail) = error, connection.isDeviceGone {
                deliveryLogger.notice(
                    "mtp transfer cut off by disconnect: \(detail, privacy: .public)")
                throw .deviceNotFound
            }
            throw error
        }
    }

    /// "Eject" for MTP: sends SET_CONFIGURATION 0, which unconfigures the
    /// device. The Kindle treats that as the host letting go — it leaves the
    /// "connected to computer" screen and stays usable on the cable — and
    /// macOS doesn't reconfigure it until it's unplugged and replugged.
    /// Queued behind sessions so it can't cut an in-flight transfer short.
    static func unconfigure(serial: String) async throws(MTPError) {
        try await MTPSessionQueue.shared.unconfigure(serial: serial)
    }

    fileprivate static func unconfigureNow(serial: String) throws(MTPError) {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = [
            "idVendor": amazonVendorID, "kUSBSerialNumberString": serial,
        ]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw .deviceNotFound }
        defer { IOObjectRelease(service) }
        do {
            let device = try IOUSBHostDevice(
                __ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            try device.__configure(withValue: 0, matchInterfaces: false)
        } catch {
            if (error as NSError).code == Int(Int32(bitPattern: 0xE000_02C5)) { throw .deviceBusy }
            throw .transport(describe(error))
        }
    }

    /// Calls `visit` for each vendor-specific USB interface named "MTP" on an
    /// Amazon device until it returns true.
    private static func forEachMTPInterface(_ visit: (io_service_t) -> Bool) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = property(service, "kUSBString") as? String
            let interfaceClass = property(service, "bInterfaceClass") as? Int
            let vendor = parentProperty(service, "idVendor") as? Int
            guard vendor == amazonVendorID, interfaceClass == 255, name == "MTP" else { continue }
            if visit(service) { return }
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func parentProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    // MARK: - Transport

    private init(service: io_service_t) throws(MTPError) {
        self.service = service
        do {
            interface = try IOUSBHostInterface(
                __ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            // kIOReturnExclusiveAccess: someone else has the interface open.
            if (error as NSError).code == Int(Int32(bitPattern: 0xE000_02C5)) { throw .deviceBusy }
            throw .transport(Self.describe(error))
        }

        var inPipe: IOUSBHostPipe?
        var outPipe: IOUSBHostPipe?
        var packetSize = 512
        var cursor = UnsafeRawPointer(interface.interfaceDescriptor)
            .assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(
            interface.configurationDescriptor, interface.interfaceDescriptor, cursor)
        {
            cursor = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            guard IOUSBGetEndpointType(endpoint) == 2 else { continue }  // bulk only
            let address = Int(IOUSBGetEndpointAddress(endpoint))
            guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
            if IOUSBGetEndpointDirection(endpoint) == 1 {
                inPipe = pipe
            } else {
                outPipe = pipe
                packetSize = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x7FF)
            }
        }
        guard let inPipe, let outPipe else {
            interface.destroy()
            throw .transport("no bulk endpoints")
        }
        bulkIn = inPipe
        bulkOut = outPipe
        maxPacketSize = max(packetSize, 1)
    }

    private func write(_ data: Data, timeout: TimeInterval = commandTimeout) throws(MTPError) {
        var sent = 0
        do {
            try bulkOut.__sendIORequest(
                with: NSMutableData(data: data), bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            throw ioFailure(error)
        }
    }

    /// Reads one whole container (header + body) from the bulk-in pipe.
    private func readContainer(timeout: TimeInterval) throws(MTPError) -> Data {
        var buffer = pending
        pending = Data()
        var expected: Int?
        while expected.map({ buffer.count < $0 }) ?? true {
            if expected == nil, buffer.count >= 4 {
                let length = Int(try PTP.parseHeader(buffer.prefix(PTP.headerSize).padded(to: 12)).length)
                guard length >= PTP.headerSize else { throw .malformed("container length \(length)") }
                expected = length
                continue
            }
            let chunk = NSMutableData(length: Self.readChunk)!
            var got = 0
            do {
                try bulkIn.__sendIORequest(
                    with: chunk, bytesTransferred: &got, completionTimeout: timeout)
            } catch {
                throw ioFailure(error)
            }
            // A zero-length packet terminating the previous transfer — skip.
            buffer.append(Data(bytes: chunk.bytes, count: got))
        }
        let length = expected!
        if buffer.count > length { pending = buffer.suffix(from: buffer.startIndex + length) }
        return Data(buffer.prefix(length))
    }

    private func nextTransactionID() -> UInt32 {
        transactionID &+= 1
        return transactionID
    }

    /// Sends a command and marks its transaction in flight until the
    /// matching response is read.
    private func begin(_ op: PTP.Operation, _ params: [UInt32] = [], transactionID tid: UInt32)
        throws(MTPError)
    {
        inFlight = tid
        try write(PTP.command(op, transactionID: tid, params: params))
    }

    /// If the first attempt gets no sane reply — the device is still stuck
    /// in a transaction from before, e.g. Tomo quit mid-send — recover and
    /// try once more.
    private func openSession() throws(MTPError) {
        do throws(MTPError) {
            try attemptOpenSession()
        } catch {
            guard inFlight != nil else { throw error }  // a clean refusal
            recover()
            try attemptOpenSession()
        }
    }

    private func attemptOpenSession() throws(MTPError) {
        // Session-less operations use transaction ID 0.
        try begin(.openSession, [1], transactionID: 0)
        do throws(MTPError) {
            try readResponse(.openSession, tid: 0)
        } catch .response(_, let code) where code == PTP.Response.sessionAlreadyOpen {
            // A previous session left open by an aborted transfer is fine to reuse.
        }
    }

    /// Closes the session if the conversation is still in step; otherwise
    /// recovers. Returns false when the device may still have stale data
    /// queued, so the next session should recover again before opening.
    private func endSession() -> Bool {
        if inFlight == nil { _ = try? transact(.closeSession) }
        guard inFlight != nil else { return true }
        if isDeviceGone {
            deliveryLogger.notice("mtp device disconnected mid-transaction; nothing to recover")
            inFlight = nil
            return true
        }
        recover()
        return false
    }

    /// The Kindle has left the bus: an I/O error said so, or the interface
    /// is no longer in the IORegistry.
    private var isDeviceGone: Bool {
        sawDeviceGone || IORegistryEntryInPlane(service, kIOServicePlane) == 0
    }

    /// IOReturn codes that mean the device is gone rather than misbehaving.
    private static let deviceGoneCodes: Set<UInt32> = [
        0xE000_02C0,  // kIOReturnNoDevice
        0xE000_02D7,  // kIOReturnOffline
        0xE000_02D9,  // kIOReturnNotAttached
    ]

    /// Error text with the raw IOReturn code, so logs can tell an unplug
    /// from a timeout from a stall ("Unable to send IO." alone can't).
    nonisolated static func describe(_ error: any Error) -> String {
        let code = UInt32(truncatingIfNeeded: (error as NSError).code)
        return "\(error.localizedDescription) [0x\(String(code, radix: 16))]"
    }

    /// Records whether a USB error means the device is gone, and wraps it.
    private func ioFailure(_ error: any Error) -> MTPError {
        let code = UInt32(truncatingIfNeeded: (error as NSError).code)
        if Self.deviceGoneCodes.contains(code) { sawDeviceGone = true }
        return .transport(Self.describe(error))
    }

    /// Best-effort resync after a transaction died part-way, following the
    /// Still Image class recovery sequence: Cancel Request for a known
    /// transaction (Device Reset Request when it's unknown — a fresh process,
    /// a failed OpenSession), wait for the device to report OK, abort and
    /// un-stall both bulk pipes, then discard whatever the device still has
    /// queued for us (a late response, the rest of a data phase).
    private func recover() {
        defer { inFlight = nil }
        let reachable =
            if let tid = inFlight, tid != 0 {
                classRequest(
                    PTP.cancelRequest, "cancel",
                    data: NSMutableData(data: PTP.cancelRequestData(transactionID: tid)))
            } else {
                classRequest(PTP.deviceResetRequest, "device reset")
            }
        guard reachable, !isDeviceGone else {
            // Can't even take a control request: treat as unplugged, so the
            // caller reports "disconnected" rather than "USB transfer failed".
            sawDeviceGone = true
            deliveryLogger.notice("mtp device unreachable; skipping recovery")
            return
        }
        waitForDeviceReady()
        for pipe in [bulkOut, bulkIn] {
            try? pipe.__abort(with: .synchronous)
            try? pipe.clearStall()
        }
        pending = Data()
        var drained = 0
        drain: for _ in 0..<64 {
            let buffer = NSMutableData(length: Self.readChunk)!
            var got = 0
            do {
                try bulkIn.__sendIORequest(
                    with: buffer, bytesTransferred: &got, completionTimeout: Self.drainTimeout)
            } catch {
                if (error as NSError).code != Int(Int32(bitPattern: 0xE000_02D6)) {  // kIOReturnTimeout
                    deliveryLogger.warning(
                        "mtp drain failed: \(Self.describe(error), privacy: .public)")
                }
                break drain
            }
            drained += got
        }
        deliveryLogger.notice(
            "mtp recovered from interrupted transaction; discarded \(drained) stale bytes")
    }

    /// Host→device class request on the MTP interface. Best-effort: logged,
    /// never thrown. Returns whether the device is still there to talk to:
    /// a STALL means it answered "not supported" (fine — carry on with the
    /// rest of recovery); any other failure means it's unplugged or wedged
    /// past what the bulk-pipe steps can fix.
    @discardableResult
    private func classRequest(_ request: UInt8, _ label: String, data: NSMutableData? = nil) -> Bool {
        let setup = IOUSBDeviceRequest(
            bmRequestType: 0x21,  // host→device, class, interface
            bRequest: request, wValue: 0, wIndex: interfaceNumber,
            wLength: UInt16(data?.length ?? 0))
        var sent = 0
        do {
            try interface.__send(
                setup, data: data, bytesTransferred: &sent, completionTimeout: Self.commandTimeout)
            return true
        } catch {
            _ = ioFailure(error)
            deliveryLogger.warning(
                "mtp \(label, privacy: .public) request failed: \(Self.describe(error), privacy: .public)")
            return (error as NSError).code == Int(Int32(bitPattern: 0xE000_5000))  // kUSBHostReturnPipeStalled
        }
    }

    /// Polls Get Device Status until the device reports OK (it answers
    /// Device Busy while it's still unwinding a cancel or reset). Bounded —
    /// a device that doesn't implement it just gets logged.
    private func waitForDeviceReady() {
        var lastCode: UInt16?
        for _ in 0..<20 {
            let setup = IOUSBDeviceRequest(
                bmRequestType: 0xA1,  // device→host, class, interface
                bRequest: PTP.getDeviceStatusRequest, wValue: 0, wIndex: interfaceNumber,
                wLength: 20)
            let buffer = NSMutableData(length: 20)!
            var got = 0
            do {
                try interface.__send(
                    setup, data: buffer, bytesTransferred: &got, completionTimeout: Self.commandTimeout)
            } catch {
                deliveryLogger.warning(
                    "mtp get device status failed: \(Self.describe(error), privacy: .public)")
                return
            }
            var reader = PTPReader(Data(bytes: buffer.bytes, count: got))
            _ = try? reader.u16()  // length
            lastCode = try? reader.u16()
            if lastCode == PTP.Response.ok { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        deliveryLogger.warning(
            "mtp device not ready after recovery (status \(String(lastCode ?? 0, radix: 16), privacy: .public))")
    }

    private var interfaceNumber: UInt16 {
        UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)
    }

    /// One command → optional data-in → response round trip. Returns the
    /// incoming data payload (empty if none) and the response params.
    @discardableResult
    private func transact(
        _ op: PTP.Operation, _ params: [UInt32] = [], send payload: Data? = nil
    ) throws(MTPError) -> (data: Data, params: [UInt32]) {
        let tid = nextTransactionID()
        try begin(op, params, transactionID: tid)
        if let payload {
            return try sendData(op, tid: tid, length: payload.count, timeout: Self.commandTimeout) {
                offset, count in payload.subdata(in: offset..<offset + count)
            }
        }
        return try readResponse(op, tid: tid)
    }

    /// Reads containers up to the response for `tid`. A container from any
    /// other transaction means host and device are out of step — throw and
    /// leave the transaction in flight so the session gets recovered.
    @discardableResult
    private func readResponse(
        _ op: PTP.Operation, tid: UInt32, timeout: TimeInterval = commandTimeout
    ) throws(MTPError) -> (data: Data, params: [UInt32]) {
        var incoming = Data()
        while true {
            let container = try readContainer(timeout: timeout)
            let header = try PTP.parseHeader(container)
            guard header.transactionID == tid else {
                throw .malformed("reply for transaction \(header.transactionID), expected \(tid)")
            }
            switch PTP.ContainerType(rawValue: header.type) {
            case .data:
                incoming = container.dropFirst(PTP.headerSize)
            case .response:
                inFlight = nil
                guard header.code == PTP.Response.ok else {
                    throw .response(operation: op.rawValue, code: header.code)
                }
                return (Data(incoming), PTP.responseParams(container))
            default:
                throw .malformed("container type \(header.type)")
            }
        }
    }

    /// Streams a data container of `length` bytes, pulling the payload in
    /// chunks from `chunk(offset, count)`, then reads the response.
    ///
    /// If `chunk` fails (a short read of the source file — the USB side is
    /// fine), the rest of the declared length is sent as zeros so the
    /// transaction completes in step, and the chunk error is rethrown after
    /// the response. The caller deletes the junk object.
    @discardableResult
    private func sendData(
        _ op: PTP.Operation, tid: UInt32, length: Int, timeout: TimeInterval,
        chunk: (_ offset: Int, _ count: Int) throws(MTPError) -> Data
    ) throws(MTPError) -> (data: Data, params: [UInt32]) {
        var outgoing = PTP.dataHeader(op, transactionID: tid, payloadLength: length)
        var offset = 0
        var chunkError: MTPError?
        repeat {
            let count = min(Self.writeChunk - outgoing.count, length - offset)
            if chunkError == nil {
                do throws(MTPError) {
                    outgoing.append(try chunk(offset, count))
                } catch {
                    chunkError = error
                }
            }
            if chunkError != nil { outgoing.append(Data(count: count)) }
            offset += count
            try write(outgoing, timeout: Self.responseTimeout)
            outgoing = Data()
        } while offset < length
        // A transfer that ends exactly on a packet boundary needs a
        // zero-length packet so the device knows it's complete.
        if (PTP.headerSize + length) % maxPacketSize == 0 {
            var sent = 0
            do {
                try bulkOut.__sendIORequest(
                    with: nil, bytesTransferred: &sent, completionTimeout: Self.commandTimeout)
            } catch {
                throw ioFailure(error)
            }
        }
        let response = try readResponse(op, tid: tid, timeout: timeout)
        if let chunkError { throw chunkError }
        return response
    }

    // MARK: - Operations

    func storageIDs() throws(MTPError) -> [UInt32] {
        try PTP.parseUInt32Array(transact(.getStorageIDs).data)
    }

    struct Object {
        let handle: UInt32
        let info: PTP.ObjectInfo
    }

    /// The objects directly inside `parent`. GetObjectHandles says which
    /// they are; their metadata comes from one GetObjectPropList for the
    /// whole folder where the device allows it, otherwise (and for any
    /// object that reply leaves out) from a GetObjectInfo each — a send to
    /// a Kindle holding 500 books is then 2 round trips, not 501.
    func children(storage: UInt32, parent: UInt32) throws(MTPError) -> [Object] {
        let handles = try PTP.parseUInt32Array(
            transact(.getObjectHandles, [storage, 0, parent]).data)
        // The root is small, and devices disagree on how to name it here.
        let known =
            canUsePropList && parent != PTP.rootParent && handles.count > 1
            ? try bulkInfo(inside: parent, expecting: handles) : [:]
        return try handles.map { handle throws(MTPError) in
            if let info = known[handle] { return Object(handle: handle, info: info) }
            return Object(
                handle: handle,
                info: try PTP.decodeObjectInfo(transact(.getObjectInfo, [handle]).data))
        }
    }

    /// All properties of everything one level below `parent`, keyed by
    /// handle. Any failure turns the fast path off for this device for the
    /// rest of the run; it only throws if the session is left out of step.
    private func bulkInfo(inside parent: UInt32, expecting handles: [UInt32])
        throws(MTPError) -> [UInt32: PTP.ObjectInfo]
    {
        do throws(MTPError) {
            // Params: object, format (any), property (all), group, depth.
            let data = try transact(.getObjectPropList, [parent, 0, 0xFFFF_FFFF, 0, 1]).data
            let infos = try PTP.decodeObjectPropList(data)
            let covered = handles.count { infos[$0] != nil }
            deliveryLogger.debug("mtp bulk listing covered \(covered) of \(handles.count) objects")
            if covered == 0 {
                deliveryLogger.notice("mtp bulk listing covered none of the folder; using per-object listing")
                canUsePropList = false
            }
            return infos
        } catch {
            canUsePropList = false
            deliveryLogger.notice(
                "mtp bulk listing unavailable (\(error.localizedDescription, privacy: .public)); using per-object listing")
            guard inFlight == nil else { throw error }
            return [:]
        }
    }

    func child(named name: String, storage: UInt32, parent: UInt32) throws(MTPError) -> Object? {
        try children(storage: storage, parent: parent).first { $0.info.filename == name }
    }

    /// Resolves a `/`-separated path of folder names from `parent`,
    /// creating missing folders when `create` is set.
    func folder(
        at path: String, storage: UInt32, from parent: UInt32 = PTP.rootParent,
        create: Bool = false
    ) throws(MTPError) -> UInt32 {
        var current = parent
        for name in path.split(separator: "/").map(String.init) {
            if let next = try child(named: name, storage: storage, parent: current) {
                guard next.info.isFolder else { throw .notFound(path) }
                current = next.handle
            } else if create {
                // A folder is an association object: SendObjectInfo alone
                // creates it, with no SendObject data phase.
                current = try sendObjectInfo(
                    named: name, format: PTP.ObjectFormat.association, size: 0,
                    storage: storage, parent: current)
            } else {
                throw .notFound(path)
            }
        }
        return current
    }

    func delete(_ handle: UInt32) throws(MTPError) {
        try transact(.deleteObject, [handle])
    }

    /// Uploads `fileURL` into `parent` as `name`, replacing any existing
    /// object of that name — MTP has no overwrite, so a re-send would
    /// otherwise leave two files with the same name.
    func upload(_ fileURL: URL, as name: String, storage: UInt32, parent: UInt32) throws(MTPError) {
        let handle: FileHandle
        let size: Int
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw .transport("couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        guard size <= Int(UInt32.max) else { throw .transport("file larger than 4 GB") }

        try upload(name: name, size: size, storage: storage, parent: parent) { _, count throws(MTPError) in
            do {
                guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                    throw MTPError.transport("short read from \(fileURL.lastPathComponent)")
                }
                return bytes
            } catch let error as MTPError {
                throw error
            } catch {
                throw .transport(error.localizedDescription)
            }
        }
    }

    func upload(_ data: Data, as name: String, storage: UInt32, parent: UInt32) throws(MTPError) {
        try upload(name: name, size: data.count, storage: storage, parent: parent) { offset, count in
            data.subdata(in: offset..<offset + count)
        }
    }

    /// Replaces `name` in `parent`. MTP has no overwrite, so any existing
    /// object of that name is deleted first.
    ///
    /// That means a re-send that fails part-way loses the old copy. Staging
    /// the new copy and swapping it in afterwards would avoid that, but the
    /// Kindle 11th gen (2024 release, FW 5.20.2.0.1) refuses both ways of
    /// doing it, although its DeviceInfo lists both operations:
    /// - SetObjectPropValue(ObjectFileName), renaming a temporary object:
    ///   0x201C (Invalid DeviceProp Value), even for fresh names after a
    ///   restart
    /// - MoveObject from a staging folder at the storage root (hidden or
    ///   not) into `documents/`: 0x2002 (General Error)
    /// With either, every send would cost two transfers. A failed upload
    /// does delete its own half-written object when the session is still
    /// in step, so the Kindle doesn't index a truncated book.
    private func upload(
        name: String, size: Int, storage: UInt32, parent: UInt32,
        chunk: (_ offset: Int, _ count: Int) throws(MTPError) -> Data
    ) throws(MTPError) {
        if let existing = try child(named: name, storage: storage, parent: parent) {
            try delete(existing.handle)
        }
        let handle = try sendObjectInfo(named: name, size: size, storage: storage, parent: parent)
        try sendObjectData(handle, size: size, chunk: chunk)
    }

    /// SendObjectInfo: declares the object and returns its new handle.
    private func sendObjectInfo(
        named name: String, format: UInt16 = PTP.ObjectFormat.undefined, size: Int,
        storage: UInt32, parent: UInt32
    ) throws(MTPError) -> UInt32 {
        let info = PTP.ObjectInfo(
            storageID: storage, format: format, size: UInt32(size),
            parent: parent, filename: name, modified: nil)
        let params = try transact(.sendObjectInfo, [storage, parent], send: PTP.encodeObjectInfo(info))
            .params
        // Response params: storage, parent, new object handle.
        guard params.count >= 3 else { throw .malformed("SendObjectInfo returned no handle") }
        return params[2]
    }

    /// SendObject: streams the bytes for the object `SendObjectInfo` just
    /// declared. On failure deletes the half-written object — unless the
    /// session is out of step, in which case no command can be sent and the
    /// leftover is replaced by the next send of the same book.
    private func sendObjectData(
        _ handle: UInt32, size: Int,
        chunk: (_ offset: Int, _ count: Int) throws(MTPError) -> Data
    ) throws(MTPError) {
        do throws(MTPError) {
            let tid = nextTransactionID()
            try begin(.sendObject, transactionID: tid)
            try sendData(.sendObject, tid: tid, length: size, timeout: Self.responseTimeout, chunk: chunk)
        } catch {
            if inFlight == nil { try? delete(handle) }
            throw error
        }
    }
}

extension Data {
    /// Zero-pads to `length` so a partial header can be parsed for its
    /// length field before the rest arrives.
    fileprivate nonisolated func padded(to length: Int) -> Data {
        count >= length ? self : self + Data(count: length - count)
    }
}

/// Runs every MTP session, one at a time, on its own dispatch queue instead
/// of Swift's cooperative pool: the USB calls block (an upload for minutes),
/// and callers queued behind one should suspend, not hold a pool thread.
private actor MTPSessionQueue {
    static let shared = MTPSessionQueue()

    private let queue = DispatchSerialQueue(label: "com.pdrbrnd.tomo.mtp")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var state = MTPConnection.SessionState()

    func withSession<T: Sendable>(
        serial: String, _ body: @Sendable (MTPConnection) throws(MTPError) -> T
    ) throws(MTPError) -> T {
        try MTPConnection.runSession(serial: serial, state: &state, body)
    }

    func unconfigure(serial: String) throws(MTPError) {
        try MTPConnection.unconfigureNow(serial: serial)
    }
}
