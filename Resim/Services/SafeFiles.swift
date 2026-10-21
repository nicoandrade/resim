import Foundation
import Darwin
import OSLog
import CryptoKit

nonisolated struct FileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

nonisolated struct FileFingerprint: Equatable, Sendable {
    let identity: FileIdentity
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

nonisolated enum SafeFiles {
    static let maximumBytes: Int64 = 100_000_000
    static let maximumPixels: UInt64 = 40_000_000
    static let memoryBudget: UInt64 = 512 * 1_024 * 1_024
    // Keep the per-image admission limit, but overlap only smaller working sets.
    // Larger valid images run alone rather than being rejected or starving forever.
    static let concurrentMemoryBudget: UInt64 = 384 * 1_024 * 1_024

    static func resolve(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw ProcessingError.unsupported(String(localized: "Add a local file from Finder.")) }
        var url = input.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isAliasFileKey])
        if values.isAliasFile == true {
            url = try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        return url
    }

    static func fingerprint(_ url: URL) throws -> FileFingerprint {
        var attributes = stat()
        guard url.withUnsafeFileSystemRepresentation({ stat($0!, &attributes) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw ProcessingError.unsupported(String(localized: "Only files are supported; folders are not processed."))
        }
        return FileFingerprint(identity: FileIdentity(device: attributes.st_dev, inode: attributes.st_ino),
                               bytes: attributes.st_size,
                               modifiedSeconds: attributes.st_mtimespec.tv_sec,
                               modifiedNanoseconds: attributes.st_mtimespec.tv_nsec,
                               changedSeconds: attributes.st_ctimespec.tv_sec,
                               changedNanoseconds: attributes.st_ctimespec.tv_nsec)
    }

    struct SourceSignature: Sendable {
        let fingerprint: FileFingerprint
        let digest: Data
    }

    /// One bounded buffer per admission, no persistent content-hash database. Reading via
    /// a descriptor anchors identity and detects writes while the digest is being computed.
    static func contentSignature(_ url: URL, cancellation: CancellationToken? = nil) throws -> SourceSignature {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        func descriptorFingerprint() throws -> FileFingerprint {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard value.st_mode & S_IFMT == S_IFREG else {
                throw ProcessingError.unsupported(String(localized: "Only files are supported; folders are not processed."))
            }
            return FileFingerprint(identity: FileIdentity(device: value.st_dev, inode: value.st_ino), bytes: value.st_size,
                                   modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
                                   changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
        }
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        var previousDigest: Data?
        // A system metadata update can also land during hashing. Retry at most twice,
        // keeping the same descriptor and requiring every complete read to agree.
        for _ in 0..<3 {
            try cancellation?.check()
            let before = try descriptorFingerprint()
            try validateSize(before)
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var digest = SHA256()
            var total: Int64 = 0
            while true {
                try cancellation?.check()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 { break }
                total += Int64(count)
                guard total <= maximumBytes else { throw ProcessingError.changedSource }
                buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
            let after = try descriptorFingerprint()
            let path = try fingerprint(url)
            guard total == before.bytes, sameContentState(before, after), sameContentState(after, path) else {
                throw ProcessingError.changedSource
            }
            let content = Data(digest.finalize())
            if let previousDigest, previousDigest != content { throw ProcessingError.changedSource }
            if before == after, after == path {
                return SourceSignature(fingerprint: after, digest: content)
            }
            previousDigest = content
        }
        throw ProcessingError.changedSource
    }

    private static func sameContentState(_ a: FileFingerprint, _ b: FileFingerprint) -> Bool {
        a.identity == b.identity && a.bytes == b.bytes && a.modifiedSeconds == b.modifiedSeconds &&
        a.modifiedNanoseconds == b.modifiedNanoseconds
    }

    /// First access may asynchronously add com.apple.macl and change ctime. A ctime-only
    /// difference is accepted only after a stable descriptor read proves byte identity.
    static func verifiedFingerprint(_ url: URL, expected: FileFingerprint, digest: Data, phase: String) throws -> FileFingerprint {
        let current = try fingerprint(url)
        if current == expected { return current }
        guard sameContentState(expected, current) else {
            try requireUnchanged(expected, current, phase: phase)
            throw ProcessingError.changedSource
        }
        let verified = try contentSignature(url)
        guard sameContentState(expected, verified.fingerprint), verified.digest == digest else {
            throw ProcessingError.changedSource
        }
        return verified.fingerprint
    }

    static func requireUnchanged(_ expected: FileFingerprint, _ actual: FileFingerprint, phase: String) throws {
        guard expected != actual else { return }
        let identityChanged = expected.identity != actual.identity
        let sizeChanged = expected.bytes != actual.bytes
        let modifiedChanged = expected.modifiedSeconds != actual.modifiedSeconds || expected.modifiedNanoseconds != actual.modifiedNanoseconds
        let metadataChanged = expected.changedSeconds != actual.changedSeconds || expected.changedNanoseconds != actual.changedNanoseconds
        Logger(subsystem: "com.resim.app", category: "FileIntegrity").notice("Source mismatch at \(phase, privacy: .public): identity=\(identityChanged), size=\(sizeChanged), mtime=\(modifiedChanged), ctime=\(metadataChanged)")
        throw ProcessingError.changedSource
    }

    static func validateSize(_ value: FileFingerprint) throws {
        guard value.bytes > 0 else { throw ProcessingError.invalid(String(localized: "The file is empty.")) }
        guard value.bytes <= maximumBytes else {
            throw ProcessingError.resourceLimit(String(localized: "The file exceeds the 100 MB limit."))
        }
    }

    static func validateInfo(_ info: ImageInfo) throws {
        guard info.width > 0, info.height > 0 else { throw ProcessingError.invalid(String(localized: "Invalid dimensions.")) }
        let (pixels, overflow) = UInt64(info.width).multipliedReportingOverflow(by: UInt64(info.height))
        guard !overflow, pixels <= maximumPixels else {
            throw ProcessingError.resourceLimit(String(localized: "The image exceeds the 40-megapixel limit."))
        }
        guard info.estimatedMemory <= memoryBudget else {
            throw ProcessingError.resourceLimit(String(localized: "The image requires more than 512 MiB to process safely."))
        }
    }

    /// Identity, size and mtime remain strict. Ctime-only changes require matching
    /// admission bytes, and the private snapshot must match that same digest.
    static func snapshot(source: URL, expected: FileFingerprint, directory: URL, expectedDigest: Data? = nil) throws -> URL {
        let before: FileFingerprint
        if let expectedDigest { before = try verifiedFingerprint(source, expected: expected, digest: expectedDigest, phase: "before snapshot") }
        else {
            before = try fingerprint(source)
            try requireUnchanged(expected, before, phase: "before snapshot")
        }
        let snapshot = directory.appendingPathComponent("source").appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: snapshot)
        if let expectedDigest {
            _ = try verifiedFingerprint(source, expected: before, digest: expectedDigest, phase: "after snapshot")
            guard try contentSignature(snapshot).digest == expectedDigest else { throw ProcessingError.changedSource }
        } else {
            try requireUnchanged(before, fingerprint(source), phase: "after snapshot")
        }
        guard try fingerprint(snapshot).bytes == before.bytes else {
            throw ProcessingError.changedSource
        }
        return snapshot
    }

    static func workDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("resim-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try Data("resim-work-v1".utf8).write(to: directory.appendingPathComponent(".owner"), options: .atomic)
        return directory
    }

    static func cleanAbandonedWork() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for directory in directories {
            let components = directory.lastPathComponent.split(separator: "-")
            guard components.count > 2, components[0] == "resim", let pid = Int32(components[1]),
                  kill(pid, 0) != 0, errno == ESRCH,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  (try? String(contentsOf: directory.appendingPathComponent(".owner"), encoding: .utf8)) == "resim-work-v1" else { continue }
            cleanRecordedStage(in: directory)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func cleanRecordedStage(in directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("stage.json")),
              let record = try? JSONDecoder().decode(StageRecord.self, from: data),
              record.url.lastPathComponent.hasPrefix(".resim-stage-"),
              let info = try? fingerprint(record.url),
              info.identity.device == record.device, info.identity.inode == record.inode else { return }
        try? FileManager.default.removeItem(at: record.url)
    }

    private struct StageRecord: Codable {
        let url: URL
        let device: Int32
        let inode: UInt64
    }

    struct Publication: Sendable {
        let stage: URL
        let destination: URL
        let fingerprint: FileFingerprint
        let replacesOriginal: Bool
    }

    static func preparePublication(candidate: URL, original: URL, settings: OptimizationSettings,
                                   workDirectory: URL, cancellation: CancellationToken) throws -> Publication {
        let folder: URL
        if settings.fileSaveMode == .copyToFolder {
            guard let destination = settings.destination else {
                throw ProcessingError.unavailable(String(localized: "The destination folder is no longer available. Change it in Settings and try again."))
            }
            folder = destination
        } else {
            folder = original.deletingLastPathComponent()
        }
        let destination = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessingError.unavailable(String(localized: "The destination folder is no longer available. Change it in Settings and try again."))
        }
        let stage = destination.appendingPathComponent(".resim-stage-\(UUID().uuidString)")
        do {
            // Exclusive creation and manifest precede the potentially long copy, so crashes are recoverable.
            let descriptor = stage.withUnsafeFileSystemRepresentation { open($0!, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? writer.close() }
            let info = try fingerprint(stage)
            let record = StageRecord(url: stage, device: info.identity.device, inode: info.identity.inode)
            try JSONEncoder().encode(record).write(to: workDirectory.appendingPathComponent("stage.json"), options: .atomic)
            let reader = try FileHandle(forReadingFrom: candidate)
            defer { try? reader.close() }
            while true {
                try cancellation.check()
                guard let data = try reader.read(upToCount: 1_024 * 1_024), !data.isEmpty else { break }
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            return Publication(stage: stage, destination: destination, fingerprint: try fingerprint(stage),
                               replacesOriginal: settings.fileSaveMode == .replaceOriginal)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// Publishes a fully prepared file on the same volume. Replacement verifies that
    /// the source still matches the admitted image and preserves its filesystem metadata.
    /// Called synchronously by the coordinator so cancellation and publication have one serial order.
    static func publish(_ publication: Publication, original: URL, format: ImageFormat,
                        expectedSource: SourceSignature) throws -> URL {
        if publication.replacesOriginal {
            _ = try verifiedFingerprint(original, expected: expectedSource.fingerprint,
                                        digest: expectedSource.digest, phase: "before replacement")
            _ = try FileManager.default.replaceItemAt(original, withItemAt: publication.stage)
            return original
        }
        let stem = original.deletingPathExtension().lastPathComponent
        let inputExtension = original.pathExtension
        let compatibleExtensions: [ImageFormat: Set<String>] = [.png: ["png"], .jpeg: ["jpg", "jpeg"], .webp: ["webp"], .heic: ["heic", "heif", "hif"], .avif: ["avif"], .gif: ["gif"], .svg: ["svg"]]
        let ext = compatibleExtensions[format, default: []].contains(inputExtension.lowercased()) ? inputExtension : format.fileExtension
        let volumeLimit = publication.destination.withUnsafeFileSystemRepresentation { pathconf($0!, _PC_NAME_MAX) }
        let maximumNameBytes = volumeLimit > 0 ? Int(volumeLimit) : Int(NAME_MAX)
        for number in 1...1_000 {
            let suffix = number == 1 ? "-optimized" : "-optimized-\(number)"
            // Reserve space for the full suffix on every collision attempt. Keep
            // complete Unicode characters when a valid source name is near NAME_MAX.
            let tail = suffix + "." + ext
            let stemBudget = maximumNameBytes - tail.utf8.count
            guard stemBudget > 0 else { throw POSIXError(.ENAMETOOLONG) }
            var usedBytes = 0
            var shortenedStem = ""
            for character in stem {
                let count = String(character).utf8.count
                guard usedBytes + count <= stemBudget else { break }
                shortenedStem.append(character)
                usedBytes += count
            }
            if shortenedStem.isEmpty { shortenedStem = String("image".prefix(stemBudget)) }
            let output = publication.destination.appendingPathComponent(shortenedStem + tail)
            let status = publication.stage.withUnsafeFileSystemRepresentation { source in
                output.withUnsafeFileSystemRepresentation { target in
                    let status = renameatx_np(AT_FDCWD, source!, AT_FDCWD, target!, UInt32(RENAME_EXCL))
                    if status != 0, errno == ENOTSUP {
                        // Older/network volumes may support atomic hard links instead.
                        return link(source!, target!)
                    }
                    return status
                }
            }
            if status == 0 { return output }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw ProcessingError.unavailable(String(localized: "There are too many copies with that name in the destination folder."))
    }
}
