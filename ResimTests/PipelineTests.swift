import XCTest
import CryptoKit
import Darwin
@testable import Resim

@MainActor
final class PipelineTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories.removeAll()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ResimTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func fixture(_ name: String = "image.PNG", byte: UInt8 = 42, in folder: URL? = nil) throws -> URL {
        let url = try (folder ?? directory()).appendingPathComponent(name)
        try Data(repeating: byte, count: 256).write(to: url)
        return url
    }

    private func model(_ processor: PipelineProcessor) -> AppModel {
        AppModel(processor: processor, defaults: UserDefaults(suiteName: "ResimTests.\(UUID().uuidString)")!)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
    }

    private func hash(_ url: URL) throws -> SHA256.Digest { SHA256.hash(data: try Data(contentsOf: url)) }

    func testDefaultReplacesOriginalWithoutRenamingOrLeavingCopiesAndPreservesPermissions() async throws {
        let source = try fixture("Foto Ñ.UPPERCASE")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let original = try Data(contentsOf: source)
        let app = model(PipelineProcessor())
        XCTAssertEqual(app.settings.fileSaveMode, .replaceOriginal)
        // A previously chosen folder must not redirect replacement mode.
        app.settings.destination = try directory().appendingPathComponent("missing")
        app.addURLs([source])
        try await waitUntil { !app.hasActiveJobs }
        let job = try XCTUnwrap(app.jobs.first)
        XCTAssertEqual(job.state, .optimized, job.message ?? "")
        XCTAssertEqual(job.resultURL, source)
        XCTAssertEqual(job.originalBytes, 256)
        XCTAssertEqual(job.resultBytes, 128)
        XCTAssertEqual(app.savedBytes, 128)
        XCTAssertEqual(try Data(contentsOf: source), Data(original.prefix(128)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path),
                       [source.lastPathComponent])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testCopyBesideOriginalKeepsOriginalAndAvoidsExistingCopies() async throws {
        let source = try fixture()
        let original = try hash(source)
        let existing = source.deletingLastPathComponent().appendingPathComponent("image-optimized.PNG")
        let sentinel = Data("existing copy".utf8)
        try sentinel.write(to: existing)
        let app = model(PipelineProcessor())
        app.settings.fileSaveMode = .copyBesideOriginal
        app.settings.destination = try directory().appendingPathComponent("missing")
        app.addURLs([source])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.first?.state, .optimized)
        XCTAssertEqual(app.jobs.first?.resultURL?.lastPathComponent, "image-optimized-2.PNG")
        XCTAssertEqual(try hash(source), original)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    func testDefaultLeavesUnchangedAndFailedSourcesIntact() async throws {
        for processor in [PipelineProcessor(unchanged: true), PipelineProcessor(rejectingByte: 42)] {
            let source = try fixture()
            let original = try hash(source)
            let app = model(processor)
            app.addURLs([source])
            try await waitUntil { !app.hasActiveJobs }
            XCTAssertTrue(app.jobs.first?.state == .unchanged || app.jobs.first?.state == .failed)
            XCTAssertNil(app.jobs.first?.resultURL)
            XCTAssertEqual(try hash(source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path),
                           [source.lastPathComponent])
        }
    }

    func testReplacementRejectsSourceChangedAfterSnapshot() async throws {
        let source = try fixture()
        let processor = PipelineProcessor(held: true)
        defer { processor.release() }
        let app = model(processor)
        app.addURLs([source])
        try await waitUntil { processor.startedCount == 1 }
        let edited = Data(repeating: 99, count: 256)
        try edited.write(to: source, options: .atomic)
        processor.release()
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.first?.state, .failed)
        XCTAssertEqual(try Data(contentsOf: source), edited)
        XCTAssertNil(app.jobs.first?.resultURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path),
                       [source.lastPathComponent])
    }

    func testFailedReplacementPublicationLeavesOriginalIntact() throws {
        let source = try fixture()
        let original = try Data(contentsOf: source)
        let signature = try SafeFiles.contentSignature(source)
        let candidate = try fixture("candidate.png", in: directory())
        let work = try directory()
        let publication = try SafeFiles.preparePublication(candidate: candidate, original: source,
                                                         settings: .init(), workDirectory: work,
                                                         cancellation: CancellationToken())
        try FileManager.default.removeItem(at: publication.stage)
        XCTAssertThrowsError(try SafeFiles.publish(publication, original: source, format: .png, expectedSource: signature))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAllSaveModesPersistAndLegacyCopyPreferencesMigrate() throws {
        let suite = "ResimTests.saveModes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try directory()
        for mode in FileSaveMode.allCases {
            let app = AppModel(processor: PipelineProcessor(), defaults: defaults)
            app.settings = .init(mode: .lossless, destination: folder, stripPersonalMetadata: true, fileSaveMode: mode)
            XCTAssertEqual(AppModel(processor: PipelineProcessor(), defaults: defaults).settings, app.settings)
        }
        for destination in [nil, folder] as [URL?] {
            var legacy: [String: Any] = ["mode": "lossless", "stripPersonalMetadata": true]
            if let destination { legacy["destination"] = destination.absoluteString }
            defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "Resim.optimizationSettings.v1")
            let saved = AppModel(processor: PipelineProcessor(), defaults: defaults).settings
            XCTAssertEqual(saved.fileSaveMode, destination == nil ? .copyBesideOriginal : .copyToFolder)
            XCTAssertEqual(saved.destination, destination)
            XCTAssertEqual(saved.mode, .lossless)
            XCTAssertTrue(saved.stripPersonalMetadata)
        }
    }

    func testSnapshotRejectsChangedSourceIncludingSameSizeReplacement() throws {
        let source = try fixture()
        let before = try SafeFiles.fingerprint(source)
        let work = try directory()
        try Data(repeating: 13, count: 256).write(to: source, options: .atomic)
        XCTAssertThrowsError(try SafeFiles.snapshot(source: source, expected: before, directory: work)) {
            guard case ProcessingError.changedSource = $0 else { return XCTFail("Expected changedSource") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("source.PNG").path))
    }

    func testSnapshotRejectsInPlaceWritesWithRestoredModificationTime() throws {
        let source = try fixture()
        let signature = try SafeFiles.contentSignature(source)
        let expected = signature.fingerprint
        let writer = try FileHandle(forWritingTo: source)
        try writer.write(contentsOf: Data(repeating: 13, count: Int(expected.bytes)))
        try writer.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: expected.modifiedSeconds, tv_nsec: expected.modifiedNanoseconds)]
        let restored = source.withUnsafeFileSystemRepresentation { path in utimensat(AT_FDCWD, path!, &times, 0) }
        XCTAssertEqual(restored, 0)

        let changed = try SafeFiles.fingerprint(source)
        XCTAssertEqual(changed.identity, expected.identity, "The write must occur on the same inode")
        XCTAssertEqual(changed.bytes, expected.bytes)
        XCTAssertEqual(changed.modifiedSeconds, expected.modifiedSeconds)
        XCTAssertEqual(changed.modifiedNanoseconds, expected.modifiedNanoseconds)
        XCTAssertTrue(changed.changedSeconds != expected.changedSeconds || changed.changedNanoseconds != expected.changedNanoseconds,
                      "ctime must detect the write even when mtime is restored")
        let work = try directory()
        XCTAssertThrowsError(try SafeFiles.snapshot(source: source, expected: expected, directory: work)) {
            guard case ProcessingError.changedSource = $0 else { return XCTFail("Expected changedSource: \($0)") }
        }
        XCTAssertThrowsError(try SafeFiles.verifiedFingerprint(source, expected: expected, digest: signature.digest, phase: "in-place write regression")) {
            guard case ProcessingError.changedSource = $0 else { return XCTFail("Do not reconcile different bytes as metadata: \($0)") }
        }
        XCTAssertThrowsError(try SafeFiles.snapshot(source: source, expected: expected, directory: work, expectedDigest: signature.digest)) {
            guard case ProcessingError.changedSource = $0 else { return XCTFail("The snapshot with a digest must reject the write: \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("source.PNG").path))
    }

    func testMetadataOnlyCTimeChangeRequiresMatchingContentDigest() throws {
        let source = try fixture()
        let bytes = try Data(contentsOf: source)
        let signature = try SafeFiles.contentSignature(source)
        let metadata = Data("Disposable metadata generated by ResimTests".utf8)
        let status = metadata.withUnsafeBytes { value in
            source.withUnsafeFileSystemRepresentation { path in
                setxattr(path!, "com.resim.tests.metadata", value.baseAddress, value.count, 0, 0)
            }
        }
        XCTAssertEqual(status, 0)
        let changed = try SafeFiles.fingerprint(source)
        XCTAssertEqual(changed.identity, signature.fingerprint.identity)
        XCTAssertEqual(changed.bytes, signature.fingerprint.bytes)
        XCTAssertEqual(changed.modifiedSeconds, signature.fingerprint.modifiedSeconds)
        XCTAssertEqual(changed.modifiedNanoseconds, signature.fingerprint.modifiedNanoseconds)
        XCTAssertTrue(changed.changedSeconds != signature.fingerprint.changedSeconds ||
                      changed.changedNanoseconds != signature.fingerprint.changedNanoseconds)

        let verified = try SafeFiles.verifiedFingerprint(source, expected: signature.fingerprint,
                                                        digest: signature.digest, phase: "metadata regression")
        XCTAssertEqual(verified, changed)
        let copy = try SafeFiles.snapshot(source: source, expected: signature.fingerprint,
                                         directory: directory(), expectedDigest: signature.digest)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testContentSignatureRejectsDirectoriesBeforeReadingTheirContents() throws {
        XCTAssertThrowsError(try SafeFiles.contentSignature(directory())) {
            guard case ProcessingError.unsupported = $0 else {
                return XCTFail("A directory must be excluded before attempting read: \($0)")
            }
        }
    }

    func testContentSignatureRejectsNamedPipesWithoutWaitingForAWriter() async throws {
        let fifo = try directory().appendingPathComponent("fake-file.png")
        XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }, 0)
        let completed = XCTestExpectation(description: "FIFO rejected without blocking open/read")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SafeFiles.contentSignature(fifo)
                XCTFail("A FIFO must not be admitted")
            } catch ProcessingError.unsupported {
                // Expected before any attempt to read from the pipe.
            } catch {
                XCTFail("Expected unsupported for FIFO: \(error)")
            }
            completed.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        if result != .completed {
            // Rescue a regressed blocking open/read so a failed test cannot leave a worker hanging.
            let descriptor = fifo.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
            if descriptor >= 0 {
                var byte: UInt8 = 1
                _ = write(descriptor, &byte, 1)
                close(descriptor)
            }
        }
        XCTAssertEqual(result, .completed, "FIFO admission must not wait for a writer")
    }

    func testConcurrentSameNamePublicationPreservesOriginalAndExistingDestination() async throws {
        let first = try fixture("misleading photo.txt")
        let second = try fixture("misleading photo.txt", byte: 17)
        let originalHashes = try [hash(first), hash(second)]
        let destination = try directory()
        let existing = destination.appendingPathComponent("misleading photo-optimized.png")
        let preserved = Data("existing file".utf8)
        try preserved.write(to: existing)
        let processor = PipelineProcessor(delay: 0.04)
        let app = model(processor)
        app.settings.destination = destination
        app.settings.fileSaveMode = .copyToFolder
        app.addURLs([first, second])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.map(\.state), [.optimized, .optimized])
        XCTAssertEqual(Set(app.jobs.compactMap(\.resultURL).map(\.lastPathComponent)),
                       ["misleading photo-optimized-2.png", "misleading photo-optimized-3.png"])
        XCTAssertEqual(try Data(contentsOf: existing), preserved)
        XCTAssertEqual(try hash(first), originalHashes[0])
        XCTAssertEqual(try hash(second), originalHashes[1])
        XCTAssertEqual(app.savedBytes, 256)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".resim") })
    }

    func testPoolCapsConcurrencyAndRespectsAggregateMemoryBudget() async throws {
        // Medium jobs can overlap up to 384 MiB, including the exact boundary.
        // Larger pairs and the largest admitted job must still run alone.
        for (mebibytes, expectedConcurrency) in [(64, 2), (128, 2), (192, 2), (200, 1), (300, 1), (512, 1)] {
            let memory = UInt64(mebibytes) * 1_024 * 1_024
            let processor = PipelineProcessor(memory: memory, delay: 0.08)
            let app = model(processor)
            app.addURLs(try (0..<5).map { try fixture("\($0).png") })
            try await waitUntil { !app.hasActiveJobs }
            XCTAssertEqual(app.completedCount, 5)
            XCTAssertLessThanOrEqual(processor.maximumConcurrent, expectedConcurrency)
            XCTAssertEqual(processor.maximumConcurrent, expectedConcurrency)
        }
    }

    func testLongASCIINamesPublishWithoutOverwritingTruncatedCollisions() async throws {
        try await checkLongNamePublication(stem: String(repeating: "a", count: 250))
    }

    func testLongUnicodeNamesPublishWithoutSplittingCharacters() async throws {
        try await checkLongNamePublication(stem: String(repeating: "🌅", count: 60) + String(repeating: "ñ", count: 5))
    }

    private func checkLongNamePublication(stem: String) async throws {
        let sources = try [fixture(stem + ".PNG"), fixture(stem + ".PNG", byte: 17)]
        let originalHashes = try sources.map(hash)
        let destination = try directory()
        // A short existing name must survive even when long inputs are truncated.
        let existing = destination.appendingPathComponent("existing-optimized.PNG")
        let preserved = Data("existing file".utf8)
        try preserved.write(to: existing)
        let processor = PipelineProcessor(delay: 0.04)
        let app = model(processor)
        app.settings.destination = destination
        app.settings.fileSaveMode = .copyToFolder
        app.addURLs(sources)
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.map(\.state), [.optimized, .optimized])
        let outputs = app.jobs.compactMap(\.resultURL)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(Set(outputs).count, 2)
        XCTAssertTrue(outputs.contains { $0.lastPathComponent.hasSuffix("-optimized.PNG") })
        XCTAssertTrue(outputs.contains { $0.lastPathComponent.hasSuffix("-optimized-2.PNG") })
        for output in outputs {
            XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
            let outputStem = output.deletingPathExtension().lastPathComponent
                .components(separatedBy: "-optimized")[0]
            XCTAssertFalse(outputStem.isEmpty)
            XCTAssertTrue(stem.hasPrefix(outputStem), "Truncation must preserve complete characters")
            XCTAssertEqual(try Data(contentsOf: output).count, 128)
        }
        XCTAssertEqual(try sources.map(hash), originalHashes)
        XCTAssertEqual(try Data(contentsOf: existing), preserved)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".resim") })
    }

    func testCancellationDiscardsRunningCandidatesAndNeverStartsQueuedWork() async throws {
        let processor = PipelineProcessor(held: true)
        let app = model(processor)
        let sources = try (0..<4).map { try fixture("cancel\($0).png") }
        let originals = try sources.map(hash)
        app.addURLs(sources)
        try await waitUntil { processor.startedCount == 2 }
        app.cancelAll()
        try await waitUntil { processor.cancelledTokens == 2 && app.cancelledCount == 2 }
        processor.release()
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.cancelledCount, 4)
        XCTAssertEqual(processor.startedCount, 2)
        XCTAssertEqual(app.savedBytes, 0)
        XCTAssertTrue(app.jobs.allSatisfy { $0.resultURL == nil })
        XCTAssertEqual(try sources.map(hash), originals)
        XCTAssertTrue(processor.workDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testIdentityDeduplicationAndDifferentCapturedPreferences() async throws {
        let source = try fixture()
        let alias = source.deletingLastPathComponent().appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let hardlink = source.deletingLastPathComponent().appendingPathComponent("hardlink.png")
        try FileManager.default.linkItem(at: source, to: hardlink)
        let finderAlias = source.deletingLastPathComponent().appendingPathComponent("Image Alias")
        let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: finderAlias)
        let processor = PipelineProcessor(unchanged: true)
        let app = model(processor)
        app.addURLs([source, alias, hardlink, finderAlias])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.count, 1)
        XCTAssertEqual(processor.startedCount, 1)
        XCTAssertEqual(app.jobs.first?.resultBytes, 256)
        app.settings.mode = .lossless
        app.addURLs([source])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.count, 2)
        XCTAssertEqual(app.jobs[0].settings.mode, .automatic)
        XCTAssertEqual(app.jobs[1].settings.mode, .lossless)
        XCTAssertEqual(processor.startedCount, 2)
    }

    func testGeneratedResultCannotBeReadmittedEvenAfterClearingRows() async throws {
        let app = model(PipelineProcessor())
        app.addURLs([try fixture()])
        try await waitUntil { !app.hasActiveJobs }
        let result = try XCTUnwrap(app.jobs.first?.resultURL)
        app.clearFinished()
        try await waitUntil { app.jobs.isEmpty }
        app.addURLs([result])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertTrue(app.jobs.isEmpty)
    }

    func testMixedBatchFailureDoesNotStopOtherFilesAndRetryUsesCurrentDestination() async throws {
        let source = try fixture()
        let original = try hash(source)
        let app = model(PipelineProcessor())
        let missingDestination = try directory().appendingPathComponent("missing")
        app.settings.destination = missingDestination
        app.settings.fileSaveMode = .copyToFolder
        app.addURLs([source, try directory()])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.failedCount, 1)
        XCTAssertEqual(app.excludedCount, 1)
        XCTAssertEqual(try hash(source), original)
        let id = try XCTUnwrap(app.jobs.first(where: { $0.state == .failed })?.id)
        let destination = try directory()
        app.settings.destination = destination
        app.retry(id)
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.first(where: { $0.id == id })?.state, .optimized)
        XCTAssertEqual(app.jobs.first(where: { $0.id == id })?.resultURL?.deletingLastPathComponent().path, destination.path)
        XCTAssertEqual(try hash(source), original)
    }

    func testResourceGuardsRejectBeforeWorkerAllocations() async throws {
        let processor = PipelineProcessor(memory: SafeFiles.memoryBudget + 1)
        let app = model(processor)
        let source = try fixture()
        app.addURLs([source])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.first?.state, .unsupported)
        XCTAssertEqual(processor.startedCount, 0)
        app.addURLs([source])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.count, 1, "Failures require an explicit retry rather than another duplicate admission")
    }

    func testSettingsPersistAndAdmissionCapturesThemSynchronously() async throws {
        let defaults = UserDefaults(suiteName: "ResimTests.settings.\(UUID().uuidString)")!
        let processor = PipelineProcessor(unchanged: true)
        let app = AppModel(processor: processor, defaults: defaults)
        app.settings = OptimizationSettings(mode: .lossless, stripPersonalMetadata: true, profile: .conservative)
        app.addURLs([try fixture()])
        app.settings.mode = .automatic
        app.settings.profile = .maximum
        XCTAssertTrue(app.hasActiveJobs)
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.jobs.first?.settings.mode, .lossless)
        XCTAssertTrue(app.jobs.first?.settings.stripPersonalMetadata == true)
        let reloaded = AppModel(processor: processor, defaults: defaults)
        XCTAssertEqual(reloaded.settings.mode, .automatic)
        XCTAssertEqual(reloaded.settings.profile, .maximum)
        XCTAssertEqual(app.jobs.first?.settings.profile, .conservative)
        XCTAssertTrue(reloaded.settings.stripPersonalMetadata)
    }

    func testCodecFailureIsIsolatedAndOriginalHashesRemainIntact() async throws {
        let processor = PipelineProcessor(rejectingByte: 99)
        let app = model(processor)
        app.settings.fileSaveMode = .copyBesideOriginal
        let good = try fixture("good.png")
        let bad = try fixture("failed.png", byte: 99)
        let hashes = try [hash(good), hash(bad)]
        app.addURLs([bad, good])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.failedCount, 1)
        XCTAssertEqual(app.completedCount, 1)
        XCTAssertEqual(try hash(good), hashes[0])
        XCTAssertEqual(try hash(bad), hashes[1])
        XCTAssertTrue(processor.workDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testHundredFileQueueAndAddingAfterCancellation() async throws {
        let processor = PipelineProcessor(unchanged: true)
        let app = model(processor)
        let folder = try directory()
        let sources = try (0..<100).map { try fixture("stress-\($0).png", in: folder) }
        app.addURLs(Array(sources.prefix(20)))
        app.addURLs(Array(sources.dropFirst(20)))
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.completedCount, 100)
        XCTAssertEqual(processor.startedCount, 100)
        XCTAssertLessThanOrEqual(processor.maximumConcurrent, 2)
        app.cancelAll()
        app.addURLs([try fixture("new.png")])
        try await waitUntil { !app.hasActiveJobs }
        XCTAssertEqual(app.completedCount, 101)
    }
}

private nonisolated final class PipelineProcessor: ImageProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = NSCondition()
    private let memory: UInt64
    private let delay: TimeInterval
    private let unchanged: Bool
    private let rejectingByte: UInt8?
    private var held: Bool
    private var active = 0
    private var maximum = 0
    private var count = 0
    private var tokens: [CancellationToken] = []
    private var directories: [URL] = []

    init(memory: UInt64 = 1_024, delay: TimeInterval = 0, held: Bool = false, unchanged: Bool = false,
         rejectingByte: UInt8? = nil) {
        self.memory = memory
        self.delay = delay
        self.held = held
        self.unchanged = unchanged
        self.rejectingByte = rejectingByte
    }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    var startedCount: Int { lock.withLock { count } }
    var cancelledTokens: Int { lock.withLock { tokens.filter(\.isCancelled).count } }
    var workDirectories: [URL] { lock.withLock { directories } }

    func release() { gate.lock(); held = false; gate.broadcast(); gate.unlock() }

    func inspect(_ source: URL) throws -> ImageInfo {
        guard FileManager.default.fileExists(atPath: source.path) else { throw ProcessingError.invalid("Missing file") }
        return ImageInfo(format: .png, width: 8, height: 8, hasAlpha: false, estimatedMemory: memory)
    }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
            count += 1
            tokens.append(cancellation)
            directories.append(workDirectory)
        }
        defer { lock.withLock { active -= 1 } }
        gate.lock()
        while held { gate.wait() }
        gate.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        // Deliberately returns a candidate even after cancellation to test the coordinator's publication gate.
        if unchanged { return nil }
        let data = try Data(contentsOf: source)
        if let rejectingByte, data.first == rejectingByte { throw ProcessingError.invalid("Simulated codec failure") }
        let result = workDirectory.appendingPathComponent("candidate.png")
        try Data(data.prefix(data.count / 2)).write(to: result)
        return result
    }
}
