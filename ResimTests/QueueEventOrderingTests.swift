import XCTest
@testable import Resim

final class QueueEventOrderingTests: XCTestCase {
    @MainActor
    func testSuspendedAdmissionCannotResurrectClearedRows() async throws {
        let receiver = SuspendedQueueReceiver()
        let processor = AdmissionGateProcessor()
        defer { processor.release() }
        let coordinator = QueueCoordinator(processor: processor) { await receiver.receive($0) }
        await receiver.suspendNextDelivery()
        let source = URL(fileURLWithPath: "/unused-queue-ordering.png")
        let admission = Task { await coordinator.addURLs([source], settings: .init()) }
        defer { Task { await receiver.resume() } }
        try await waitUntil { await receiver.isSuspended }

        // No inspection starts: cancellation and removal both happen while the
        // receiver is still waiting to apply the initial queued event.
        await coordinator.cancelAll()
        await coordinator.clearFinished()
        await receiver.resume()
        await admission.value
        let jobs = await receiver.jobs
        XCTAssertTrue(jobs.isEmpty, "An older queued event must not recreate a cleared row")
        XCTAssertFalse(processor.didEnterInspection)
    }

    @MainActor
    func testCancellationBatchCannotOverwriteAConcurrentRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-event-ordering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try (1...2).map { index -> URL in
            let source = directory.appendingPathComponent("image-\(index).png")
            try Data(repeating: UInt8(index), count: 64).write(to: source)
            return source
        }
        let receiver = SuspendedQueueReceiver()
        let processor = AdmissionGateProcessor()
        defer { processor.release() }
        let coordinator = QueueCoordinator(processor: processor) { await receiver.receive($0) }
        let admission = Task { await coordinator.addURLs(sources, settings: .init()) }
        defer { Task { await receiver.resume() } }
        try await waitUntil { processor.didEnterInspection }
        let admitted = await receiver.jobs
        let secondID = try XCTUnwrap(admitted.values.first { $0.sourceURL == sources[1] }?.id)

        await receiver.suspendNextDelivery()
        let cancellation = Task { await coordinator.cancelAll() }
        try await waitUntil { await receiver.isSuspended }
        // The second row's retry is a newer transition than the cancellation
        // batch, even though delivery of the first cancelled row is suspended.
        await coordinator.retry(secondID, settings: .init(mode: .lossless))
        await receiver.resume()
        await cancellation.value
        let retried = await receiver.jobs[secondID]
        XCTAssertEqual(retried?.state, .queued)
        XCTAssertEqual(retried?.settings.mode, .lossless)

        await coordinator.cancelAll()
        processor.release()
        await admission.value
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await condition() else {
            XCTFail("Timed out waiting for a controlled event transition", file: file, line: line)
            throw NSError(domain: "QueueEventOrderingTests.Timeout", code: 1)
        }
    }
}

private actor SuspendedQueueReceiver {
    private(set) var jobs: [UUID: ImageJob] = [:]
    private var suspendNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    func suspendNextDelivery() { suspendNext = true }

    func receive(_ event: QueueEvent) async {
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { continuation = $0 }
        }
        switch event {
        case .updated(let job): jobs[job.id] = job
        case .removed(let id): jobs.removeValue(forKey: id)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private nonisolated final class AdmissionGateProcessor: ImageProcessing, @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var entered = false
    var didEnterInspection: Bool { condition.withLock { entered } }

    func release() {
        condition.lock()
        held = false
        condition.broadcast()
        condition.unlock()
    }

    func inspect(_ source: URL) throws -> ImageInfo {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while held && Date() < deadline { _ = condition.wait(until: deadline) }
        condition.unlock()
        return ImageInfo(format: .png, width: 8, height: 8, hasAlpha: false, estimatedMemory: 1_024)
    }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        try cancellation.check()
        return nil
    }
}
