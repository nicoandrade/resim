import XCTest
@testable import Resim

final class QueueFairnessTests: XCTestCase {
    @MainActor
    func testLargeReadyImageDrainsActiveWorkersBeforeLaterSmallImagesCanStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-queue-fairness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try (1...4).map { marker -> URL in
            let source = directory.appendingPathComponent("image-\(marker).png")
            try Data(repeating: UInt8(marker), count: 64).write(to: source)
            return source
        }
        let laterSmallStarted = XCTestExpectation(description: "A later small image must not bypass the waiting large image")
        laterSmallStarted.isInverted = true
        let processor = FairnessProcessor(forbiddenLaterStart: laterSmallStarted)
        defer { processor.releaseAll() }
        let suite = "resim-queue-fairness-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(processor: processor, defaults: defaults)
        model.addURLs(sources)
        try await waitUntil { model.pendingAdmissions == 0 && Set(processor.started) == [1, 2] }
        XCTAssertEqual(model.jobs.count, 4)

        // Each worker has its own gate. Releasing only the first guarantees that
        // one 64 MiB worker remains active while the 400 MiB image is waiting.
        processor.watchLaterStart()
        processor.release(1)
        try await waitUntil { model.jobs.first { $0.sourceURL == sources[0] }?.state == .unchanged }
        let result = await XCTWaiter.fulfillment(of: [laterSmallStarted], timeout: 0.2)
        processor.stopWatchingLaterStart()
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(Set(processor.started), [1, 2])
        XCTAssertEqual(model.jobs.first { $0.sourceURL == sources[2] }?.state, .queued)
        XCTAssertEqual(model.jobs.first { $0.sourceURL == sources[3] }?.state, .queued)

        processor.release(2)
        try await waitUntil { processor.started.contains(3) }
        XCTAssertEqual(processor.activeWhenLargeStarted, [3], "The large image must run alone")
        XCTAssertFalse(processor.started.contains(4))
        processor.release(3)
        try await waitUntil { processor.started.contains(4) }
        XCTAssertEqual(Array(processor.started.suffix(2)), [3, 4])
        processor.release(4)
        try await waitUntil { !model.hasActiveJobs }
        XCTAssertEqual(model.completedCount, 4)
        XCTAssertEqual(model.failedCount + model.cancelledCount + model.excludedCount, 0)
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0).first }, [1, 2, 3, 4])
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(remaining.map(\.lastPathComponent)), Set(sources.map(\.lastPathComponent)))
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else {
            XCTFail("Timed out waiting for a controlled queue transition", file: file, line: line)
            throw NSError(domain: "QueueFairnessTests.Timeout", code: 1)
        }
    }
}

private nonisolated final class FairnessProcessor: ImageProcessing, @unchecked Sendable {
    private let condition = NSCondition()
    private let forbiddenLaterStart: XCTestExpectation
    private var starts: [UInt8] = []
    private var active: Set<UInt8> = []
    private var largeStart: Set<UInt8> = []
    private var released: Set<UInt8> = []
    private var allReleased = false
    private var watching = false

    init(forbiddenLaterStart: XCTestExpectation) { self.forbiddenLaterStart = forbiddenLaterStart }
    var started: [UInt8] { condition.withLock { starts } }
    var activeWhenLargeStarted: Set<UInt8> { condition.withLock { largeStart } }
    func watchLaterStart() { condition.withLock { watching = true } }
    func stopWatchingLaterStart() { condition.withLock { watching = false } }
    func release(_ marker: UInt8) {
        condition.lock(); released.insert(marker); condition.broadcast(); condition.unlock()
    }
    func releaseAll() {
        condition.lock(); allReleased = true; condition.broadcast(); condition.unlock()
    }

    func inspect(_ source: URL) throws -> ImageInfo {
        let marker = try XCTUnwrap(Data(contentsOf: source).first)
        let mebibytes: UInt64 = marker == 3 ? 400 : 64
        return ImageInfo(format: .png, width: 8, height: 8, hasAlpha: false,
                         estimatedMemory: mebibytes * 1_024 * 1_024)
    }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        let marker = try XCTUnwrap(Data(contentsOf: source).first)
        condition.lock()
        starts.append(marker); active.insert(marker)
        if marker == 3 { largeStart = active }
        let forbidden = marker == 4 && watching
        condition.unlock()
        if forbidden { forbiddenLaterStart.fulfill() }
        defer { condition.withLock { _ = active.remove(marker) } }
        condition.lock()
        while !allReleased, !released.contains(marker), !cancellation.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        condition.unlock()
        try cancellation.check()
        return nil
    }
}
