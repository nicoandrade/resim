import XCTest
import CryptoKit
import Darwin
@testable import Resim

final class BlockingCodecPoolTests: XCTestCase {
    @MainActor
    func testRealImageQueueUsesOnlyTwoFixedOSThreadsAcrossThirtySixJobs() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rgba.png", withExtension: nil, subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-fixed-codec-threads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try (0..<36).map { index -> URL in
            let source = directory.appendingPathComponent("image-\(index).png")
            try FileManager.default.copyItem(at: fixture, to: source)
            return source
        }
        let hashes = try sources.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let preexistingWork = currentProcessWorkDirectories()
        let processor = ThreadRecordingProcessor()
        let suite = "resim-fixed-codec-threads-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(processor: processor, defaults: defaults)
        model.settings.fileSaveMode = .copyBesideOriginal
        model.addURLs(Array(sources.prefix(12)))
        model.addURLs(Array(sources.dropFirst(12)))
        try await waitUntil(timeout: .seconds(30)) { !model.hasActiveJobs }
        XCTAssertEqual(model.jobs.count, 36)
        XCTAssertEqual(model.completedCount, 36)
        XCTAssertEqual(model.failedCount + model.excludedCount + model.cancelledCount, 0)
        XCTAssertEqual(processor.startedCount, 36)
        XCTAssertEqual(processor.threadIDs.count, 2, "Every blocking codec call must stay on the same two OS threads")
        XCTAssertEqual(processor.maximumActive, 2)
        XCTAssertEqual(try sources.map { SHA256.hash(data: try Data(contentsOf: $0)) }, hashes)
        let expected = Set((sources + model.jobs.compactMap(\.resultURL)).map(\.lastPathComponent))
        let actual = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(currentProcessWorkDirectories(), preexistingWork)
    }

    @MainActor
    func testPoolDeinitializesWithoutJoiningAndDrainsAlreadyQueuedJobs() async throws {
        let gate = DrainGate()
        defer { gate.release() }
        var pool: BlockingCodecPool? = BlockingCodecPool()
        weak var weakPool = pool
        for _ in 0..<4 { pool?.submit { gate.run() } }
        try await waitUntil { gate.startedCount == 2 }
        let began = ContinuousClock.now
        pool = nil
        XCTAssertNil(weakPool, "Worker closures must retain State rather than the pool")
        XCTAssertLessThan(began.duration(to: .now), .seconds(1), "Deinitialization must not join blocked codec threads")
        gate.release()
        try await waitUntil { gate.finishedCount == 4 }
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            XCTFail("Timed out waiting for the fixed codec workers", file: file, line: line)
            throw NSError(domain: "BlockingCodecPoolTests.Timeout", code: 1)
        }
    }

    private func currentProcessWorkDirectories() -> Set<URL> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return Set(entries.filter { $0.lastPathComponent.hasPrefix("resim-\(ProcessInfo.processInfo.processIdentifier)-") })
    }
}

private nonisolated final class ThreadRecordingProcessor: ImageProcessing, @unchecked Sendable {
    private let native = NativeImageProcessor()
    private let condition = NSCondition()
    private var threads: Set<UInt64> = []
    private var started = 0
    private var active = 0
    private var maximum = 0
    private var firstArrivals = 0

    var threadIDs: Set<UInt64> { condition.withLock { threads } }
    var startedCount: Int { condition.withLock { started } }
    var maximumActive: Int { condition.withLock { maximum } }
    func inspect(_ source: URL) throws -> ImageInfo { try native.inspect(source) }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        var threadID: UInt64 = 0
        guard pthread_threadid_np(nil, &threadID) == 0 else { throw NSError(domain: "ThreadID", code: 1) }
        condition.lock()
        threads.insert(threadID); started += 1; active += 1
        maximum = max(maximum, active)
        let synchronizeFirstPair = started <= 2
        if synchronizeFirstPair { firstArrivals += 1; condition.broadcast() }
        condition.unlock()
        defer { condition.withLock { active -= 1 } }
        if synchronizeFirstPair {
            let deadline = Date().addingTimeInterval(5)
            condition.lock()
            while firstArrivals < 2 && !cancellation.isCancelled && Date() < deadline {
                _ = condition.wait(until: deadline)
            }
            let paired = firstArrivals == 2
            condition.unlock()
            guard paired else { throw NSError(domain: "FixedCodecPairDidNotStart", code: 1) }
        }
        try cancellation.check()
        return try native.optimize(source: source, workDirectory: workDirectory,
                                   settings: settings, cancellation: cancellation)
    }
}

private nonisolated final class DrainGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = 0
    private var finished = 0
    private var released = false
    var startedCount: Int { condition.withLock { started } }
    var finishedCount: Int { condition.withLock { finished } }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
    func run() {
        condition.lock()
        started += 1
        // The timeout rescues a broken implementation that blocks in deinit,
        // allowing the lifecycle assertion to fail without hanging the suite.
        let deadline = Date().addingTimeInterval(5)
        while !released && Date() < deadline { _ = condition.wait(until: deadline) }
        finished += 1
        condition.unlock()
    }
}
