import XCTest
@testable import Resim

@MainActor
final class AppModelSummaryTests: XCTestCase {
    func testTotalsStayConsistentAcrossDeduplicationRetryCancellationAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResimSummary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ResimTests.Summary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let processor = SummaryProcessor()
        let model = AppModel(processor: processor, defaults: defaults)
        model.settings.fileSaveMode = .copyBesideOriginal
        defer {
            processor.release()
            model.cancelAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func source(_ name: String, byte: UInt8) throws -> URL {
            let url = directory.appendingPathComponent(name + ".png")
            try Data(repeating: byte, count: 256).write(to: url)
            return url
        }
        let optimized = try source("optimized", byte: 1)
        let unchanged = try source("unchanged", byte: 0)
        let failed = try source("failed", byte: 2)
        model.addURLs([optimized, optimized, unchanged, failed, directory])
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.totalCount, 4)
        XCTAssertEqual(model.completedCount, 2)
        XCTAssertEqual(model.failedCount, 1)
        XCTAssertEqual(model.excludedCount, 1)
        XCTAssertEqual(model.savedBytes, 128)

        let failedID = try XCTUnwrap(model.jobs.first { $0.state == .failed }?.id)
        try Data(repeating: 1, count: 256).write(to: failed)
        model.retry(failedID)
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.completedCount, 3)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertEqual(model.savedBytes, 256)
        let unsupportedID = try XCTUnwrap(model.jobs.first { $0.state == .unsupported }?.id)
        model.retry(unsupportedID)
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.excludedCount, 1)

        processor.hold()
        let heldSources = try (0..<4).map { try source("held\($0)", byte: 1) }
        model.addURLs(heldSources)
        try await wait(model) { model.pendingAdmissions == 0 && model.jobs.filter { $0.state == .running }.count == 2 }
        // Remove the prefix while other rows are active, exercising shifted indices.
        model.clearFinished()
        try await wait(model) { model.totalCount == 4 }
        XCTAssertEqual(model.finishedCount, 0)
        XCTAssertEqual(model.savedBytes, 0)
        model.cancelAll()
        try await wait(model) { model.cancelledCount == 2 }
        XCTAssertTrue(model.hasActiveJobs)
        model.clearFinished()
        try await wait(model) { model.totalCount == 2 }
        XCTAssertEqual(model.cancelledCount, 0)
        processor.release()
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.cancelledCount, 2)
        let cancelledID = try XCTUnwrap(model.jobs.first?.id)
        model.retry(cancelledID)
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.completedCount, 1)
        XCTAssertEqual(model.cancelledCount, 1)
        XCTAssertEqual(model.savedBytes, 128)

        model.clearFinished()
        try await wait(model) { model.jobs.isEmpty }
        XCTAssertEqual(model.progress, 0)
        model.addURLs([unchanged, unchanged])
        try await wait(model) { !model.hasActiveJobs }
        XCTAssertEqual(model.totalCount, 1)
        XCTAssertEqual(model.completedCount, 1)
        XCTAssertEqual(model.savedBytes, 0)
    }

    private func wait(_ model: AppModel, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            assertTotals(model, file: file, line: line)
            try await Task.sleep(for: .milliseconds(5))
        }
        assertTotals(model, file: file, line: line)
        XCTAssertTrue(condition(), "Timed out waiting for queue state", file: file, line: line)
    }

    private func assertTotals(_ model: AppModel, file: StaticString, line: UInt) {
        let jobs = model.jobs
        XCTAssertEqual(model.totalCount, jobs.count, file: file, line: line)
        XCTAssertEqual(model.completedCount, jobs.filter { $0.state == .optimized || $0.state == .unchanged }.count, file: file, line: line)
        XCTAssertEqual(model.failedCount, jobs.filter { $0.state == .failed }.count, file: file, line: line)
        XCTAssertEqual(model.excludedCount, jobs.filter { $0.state == .unsupported }.count, file: file, line: line)
        XCTAssertEqual(model.cancelledCount, jobs.filter { $0.state == .cancelled }.count, file: file, line: line)
        XCTAssertEqual(model.finishedCount, jobs.filter { $0.state.isFinished }.count, file: file, line: line)
        XCTAssertEqual(model.savedBytes, jobs.reduce(Int64(0)) { $0 + $1.savedBytes }, file: file, line: line)
        XCTAssertEqual(model.progress, jobs.isEmpty ? 0 : Double(model.finishedCount) / Double(jobs.count), file: file, line: line)
    }
}

private nonisolated final class SummaryProcessor: ImageProcessing, @unchecked Sendable {
    private let gate = NSCondition()
    private var held = false

    func hold() { gate.lock(); held = true; gate.unlock() }
    func release() { gate.lock(); held = false; gate.broadcast(); gate.unlock() }

    func inspect(_ source: URL) throws -> ImageInfo {
        ImageInfo(format: .png, width: 8, height: 8, hasAlpha: false, estimatedMemory: 1_024)
    }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        gate.lock()
        while held { gate.wait() }
        gate.unlock()
        try cancellation.check()
        let data = try Data(contentsOf: source)
        if data.first == 0 { return nil }
        if data.first == 2 { throw ProcessingError.invalid("Simulated failure") }
        let output = workDirectory.appendingPathComponent("candidate.png")
        try Data(data.prefix(128)).write(to: output)
        return output
    }
}
