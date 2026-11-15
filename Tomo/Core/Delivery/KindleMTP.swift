import Foundation
import os

/// MTP Kindle driver — for Kindles that connect over MTP only and never
/// mount a volume. Tested on one model: the Kindle 11th generation (2024
/// release), FW 5.20.2.0.1. Same delivery behaviour as the volume `Kindle` driver (formats,
/// EPUB→AZW3 conversion, system-file hiding, home-screen thumbnail) via
/// `KindleDelivery`; only the transport differs.
///
/// Every operation opens its own short MTP session (`MTPConnection`), so
/// nothing is held open between calls and the device is always safe to
/// unplug. `eject()` unconfigures the USB device so the Kindle leaves its
/// "connected to computer" screen.
nonisolated struct KindleMTP: BookDevice {
    /// USB serial number — stable across reconnects.
    let serial: String

    var id: String { "mtp:\(serial)" }
    var displayName: String { "Kindle" }
    var supportedFormats: Set<String> { KindleDelivery.supportedFormats }

    /// IORegistry lookup only — doesn't open the device.
    static func detect() -> KindleMTP? {
        MTPConnection.connectedKindles().first.map { KindleMTP(serial: $0.serial) }
    }

    func filenames() async -> Set<String> {
        Set(await files().map(\.name))
    }

    /// Retries once: the first listing after USB attach can land before the
    /// Kindle is ready for sessions, and an empty result would show every
    /// book as "not on device" (inviting duplicate re-sends) until the next
    /// refresh.
    func files() async -> [DeviceFile] {
        for attempt in 1...2 {
            do {
                return try await MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                    try listDocuments(conn)
                }
            } catch {
                // The protocol has no error channel here; an unreadable device
                // shows as empty, so make sure the reason is in the logs.
                deliveryLogger.error(
                    "kindle mtp listing failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                if case .deviceNotFound = error { break }
                if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        return []
    }

    func isSystemFile(relativePath: String) -> Bool {
        KindleDelivery.isSystemFile(relativePath: relativePath)
    }

    /// The book and its home-screen thumbnail go in one session, so the
    /// device's folders are only looked up once per send.
    func copy(_ book: Book) async throws {
        let name = deviceFilename(for: book)
        let serial = serial
        let route = deliveryRoute(for: book)
        // Same condition `withDeliverableFile` reports back: an EPUB that
        // gets converted needs the thumbnail written alongside it.
        var convertsEPUB = false
        if case .convert = route { convertsEPUB = book.fileURL.pathExtension.lowercased() == "epub" }
        let thumbnail =
            convertsEPUB
            ? await Self.coverThumbnail(epubURL: book.fileURL, coverOverride: book.coverURL) : nil

        _ = try await KindleDelivery.withDeliverableFile(for: book, route: route) { file in
            do {
                try await MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                    let (storage, documents) = try Self.documentsFolder(conn)
                    try conn.upload(file, as: name, storage: storage, parent: documents)
                    guard let thumbnail else { return }
                    // Best-effort, like the volume driver: the book is usable
                    // without it. No `.tomo/cover-thumbnails` mirror and no
                    // restore-on-reconnect yet (`KindleSync` is volume-only),
                    // so a cover Amazon overwrites while the Kindle is online
                    // stays overwritten until the book is re-sent.
                    do throws(MTPError) {
                        // Created if missing, like the volume driver does.
                        let thumbnails = try conn.folder(
                            at: KindleCoverThumbnail.thumbnailsSubpath, storage: storage, create: true)
                        try conn.upload(
                            thumbnail.bytes, as: thumbnail.filename, storage: storage, parent: thumbnails)
                        deliveryLogger.info(
                            "kindle mtp thumbnail wrote \(thumbnail.bytes.count) bytes to \(thumbnail.filename, privacy: .public)")
                    } catch {
                        deliveryLogger.warning(
                            "kindle mtp thumbnail write failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                throw BookDeviceError.copyFailed(underlying: error)
            }
        }
    }

    func removeFile(at relativePath: String) async throws {
        do {
            try await MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                let (storage, documents) = try Self.documentsFolder(conn)
                let folderPath = (relativePath as NSString).deletingLastPathComponent
                let name = (relativePath as NSString).lastPathComponent
                let parent = try conn.folder(at: folderPath, storage: storage, from: documents)
                guard let file = try conn.child(named: name, storage: storage, parent: parent)
                else { throw .notFound(relativePath) }
                try conn.delete(file.handle)
            }
        } catch {
            throw BookDeviceError.removeFailed(underlying: error)
        }
    }

    /// Nothing to unmount, so unconfigure the USB device instead: the Kindle
    /// leaves its "connected to computer" screen, the MTP interface goes
    /// away, and it isn't detected again until it's replugged.
    func eject() async throws {
        do {
            try await MTPConnection.unconfigure(serial: serial)
        } catch {
            throw BookDeviceError.ejectFailed(underlying: error)
        }
    }

    // MARK: - Private

    /// The storage holding `documents/` and the folder's handle. Resolved by
    /// name every time — object handles aren't stable across sessions.
    private static func documentsFolder(_ conn: MTPConnection) throws(MTPError) -> (
        storage: UInt32, handle: UInt32
    ) {
        for storage in try conn.storageIDs() {
            if let documents = try conn.child(
                named: "documents", storage: storage, parent: PTP.rootParent),
                documents.info.isFolder
            {
                return (storage, documents.handle)
            }
        }
        throw .notFound("documents")
    }

    /// Mirrors the volume driver's walk: recurse into on-device collection
    /// folders, skip hidden entries and `.sdr` annotation sidecars, keep only
    /// formats the scanner indexes, hide Amazon's own content.
    private func listDocuments(_ conn: MTPConnection) throws(MTPError) -> [DeviceFile] {
        let (storage, documents) = try Self.documentsFolder(conn)
        var results: [DeviceFile] = []

        func walk(_ parent: UInt32, prefix: String) throws(MTPError) {
            for object in try conn.children(storage: storage, parent: parent) {
                let name = object.info.filename
                guard !name.hasPrefix(".") else { continue }
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let ext = (name as NSString).pathExtension.lowercased()
                if object.info.isFolder {
                    if ext != "sdr" { try walk(object.handle, prefix: relative) }
                    continue
                }
                guard supportedFormats.contains(ext), !isSystemFile(relativePath: relative)
                else { continue }
                results.append(
                    DeviceFile(
                        relativePath: relative,
                        size: Int64(object.info.size),
                        modifiedAt: object.info.modified ?? .distantPast
                    ))
            }
        }

        try walk(documents, prefix: "")
        return results
    }

    /// The home-screen thumbnail for an EPUB, read off the main actor
    /// (it parses the EPUB and resizes the cover). Nil when there's no
    /// cover or it can't be read.
    private static func coverThumbnail(epubURL: URL, coverOverride: URL?) async -> (
        filename: String, bytes: Data
    )? {
        await Task.detached {
            do {
                let manifest = try EPUBSource.read(
                    from: epubURL, coverSource: .override(coverOverride))
                return KindleCoverThumbnail.thumbnail(for: manifest)
            } catch {
                deliveryLogger.warning(
                    "kindle mtp thumbnail skipped: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }
}
