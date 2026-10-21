import XCTest
import UniformTypeIdentifiers
@testable import Resim

final class FileURLDropTests: XCTestCase {
    func testFinderURLRepresentationsAndVirtualContentExclusion() {
        let url = URL(fileURLWithPath: "/tmp/Fóto Ñ 试.PNG")
        XCTAssertEqual(FileURLDropReader.fileURL(from: url as NSURL), url)
        XCTAssertEqual(FileURLDropReader.fileURL(from: url.dataRepresentation as NSData), url)
        XCTAssertEqual(FileURLDropReader.fileURL(from: url.absoluteString as NSString), url)
        XCTAssertNil(FileURLDropReader.fileURL(from: URL(string: "https://example.com/image.png")! as NSURL))
        XCTAssertNil(FileURLDropReader.fileURL(from: "not a local file" as NSString))
        XCTAssertNil(FileURLDropReader.fileURL(from: nil))
    }
    @MainActor
    func testNativeItemProvidersDeliverFinderFileURLsAsynchronously() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/Fóto Ñ.jpg"), URL(fileURLWithPath: "/tmp/logo.webp")]
        let providers = [
            NSItemProvider(item: urls[0] as NSURL, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: urls[1].dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
        ]
        var received: [URL] = []
        XCTAssertTrue(FileURLDropReader.receive(providers) { received.append($0) })
        for _ in 0..<300 {
            if received.count == urls.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(received), Set(urls))
        XCTAssertFalse(FileURLDropReader.receive([NSItemProvider(item: "virtual image" as NSString, typeIdentifier: UTType.plainText.identifier)]) { _ in
            XCTFail("A virtual item must not become a file URL")
        })
    }

    @MainActor
    func testDropIsActiveBeforeItsFirstURLAndCancellationDoesNotWaitForProvider() async throws {
        let controller = ControlledDropDelivery()
        let model = try makeModel(DropTestProcessor())
        XCTAssertTrue(model.receiveDrop([controller.provider()]))
        XCTAssertTrue(model.hasActiveJobs, "Esc and close must see pending Finder providers")
        try await waitUntil { controller.wasRequested }
        model.cancelAll()
        XCTAssertFalse(model.hasActiveJobs, "Cancelling must not wait for an external provider")
        controller.finish(data: URL(fileURLWithPath: "/tmp/cancelled-before-arrival.png").dataRepresentation)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.jobs.isEmpty)
    }

    @MainActor
    func testCancellingIncrementalDropRejectsLateURLAndAllowsANewGesture() async throws {
        let sources = try (0..<3).map { try source("drop-\($0).png") }
        let processor = DropTestProcessor(held: true)
        defer { processor.release() }
        let model = try makeModel(processor)
        let delayed = ControlledDropDelivery()
        let immediate = NSItemProvider(item: sources[0].dataRepresentation as NSData,
                                       typeIdentifier: UTType.fileURL.identifier)
        XCTAssertTrue(model.receiveDrop([immediate, delayed.provider()]))
        try await waitUntil { processor.startedCount == 1 && delayed.wasRequested }
        XCTAssertEqual(model.jobs.first?.state, .running)
        model.cancelAll()
        delayed.finish(data: sources[1].dataRepresentation)
        processor.release()
        try await waitUntil { !model.hasActiveJobs }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.jobs.map(\.sourceURL), [sources[0]])
        XCTAssertEqual(model.jobs.first?.state, .cancelled)
        XCTAssertTrue(model.jobs.allSatisfy { $0.resultURL == nil })
        XCTAssertTrue(model.receiveDrop([NSItemProvider(item: sources[2] as NSURL,
                                                      typeIdentifier: UTType.fileURL.identifier)]))
        try await waitUntil { !model.hasActiveJobs }
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.completedCount, 1)
        XCTAssertEqual(model.cancelledCount, 1)
        XCTAssertEqual(processor.startedCount, 2, "The cancelled gesture's late URL must never reach a codec")
        XCTAssertFalse(model.jobs.contains { $0.sourceURL == sources[1] })
    }

    @MainActor
    func testDropCapturesSettingsBeforeAsynchronousProvidersReturn() async throws {
        let input = try source("captured.png")
        let controller = ControlledDropDelivery()
        let model = try makeModel(DropTestProcessor())
        let captured = OptimizationSettings(mode: .lossless, destination: input.deletingLastPathComponent(),
                                            stripPersonalMetadata: true)
        model.settings = captured
        XCTAssertTrue(model.receiveDrop([controller.provider()]))
        model.settings = OptimizationSettings(mode: .automatic, stripPersonalMetadata: false)
        try await waitUntil { controller.wasRequested }
        controller.finish(data: input.dataRepresentation)
        try await waitUntil { !model.hasActiveJobs }
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.settings, captured)
        XCTAssertEqual(model.jobs.first?.state, .unchanged)
    }

    @MainActor
    func testFailedRemoteAndVirtualProvidersFinishWithoutLeavingActiveWork() async throws {
        let controller = ControlledDropDelivery()
        let model = try makeModel(DropTestProcessor())
        let remote = NSItemProvider(item: URL(string: "https://example.com/image.png")!.dataRepresentation as NSData,
                                    typeIdentifier: UTType.fileURL.identifier)
        XCTAssertTrue(model.receiveDrop([controller.provider(), remote]))
        try await waitUntil { controller.wasRequested }
        controller.finish(error: NSError(domain: "DropProviderFailure", code: 1))
        try await waitUntil { !model.hasActiveJobs }
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(model.receiveDrop([NSItemProvider(item: "virtual image" as NSString,
                                                       typeIdentifier: UTType.plainText.identifier)]))
        XCTAssertFalse(model.hasActiveJobs)
    }

    @MainActor
    func testReaderCompletesOnceAfterSuccessfulAndFailedProviders() async throws {
        let input = URL(fileURLWithPath: "/tmp/received.png")
        let controller = ControlledDropDelivery()
        var received: [URL] = []
        var completions = 0
        let providers = [NSItemProvider(item: input as NSURL, typeIdentifier: UTType.fileURL.identifier),
                         controller.provider()]
        XCTAssertTrue(FileURLDropReader.receive(providers, onReceive: { received.append($0) }, onComplete: {
            XCTAssertEqual(received, [input], "Completion must run after incremental delivery")
            completions += 1
        }))
        try await waitUntil { controller.wasRequested }
        controller.finish(error: NSError(domain: "DropProviderFailure", code: 2))
        try await waitUntil { completions == 1 }
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    private func makeModel(_ processor: DropTestProcessor) throws -> AppModel {
        let suite = "ResimTests.drop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(processor: processor, defaults: defaults)
    }

    private func source(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent(name)
        try Data(repeating: 17, count: 4_096).write(to: input)
        return input
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Drop callback or job timed out")
        if !condition() { throw NSError(domain: "DropTestTimeout", code: 1) }
    }

}


/// A real NSItemProvider registration whose asynchronous result is controlled by the test.
private nonisolated final class ControlledDropDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, (any Error)?) -> Void)?
    private var requested = false
    private var completed = false
    private var result: (Data?, (any Error)?)?
    var wasRequested: Bool { lock.withLock { requested } }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { [self] completion in
            let ready = lock.withLock { () -> (Data?, (any Error)?)? in
                requested = true
                if completed { return result }
                callback = completion
                return nil
            }
            if let ready { completion(ready.0, ready.1) }
            return Progress(totalUnitCount: 1)
        }
        return provider
    }

    func finish(data: Data? = nil, error: (any Error)? = nil) {
        let completion = lock.withLock { () -> ((Data?, (any Error)?) -> Void)? in
            guard !completed else { return nil }
            completed = true
            result = (data, error)
            let value = callback
            callback = nil
            return value
        }
        completion?(data, error)
    }
}

private nonisolated final class DropTestProcessor: ImageProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Bool
    private var started = 0
    init(held: Bool = false) { self.held = held }
    var startedCount: Int { lock.withLock { started } }
    func release() { lock.withLock { held = false } }
    func inspect(_ source: URL) throws -> ImageInfo {
        ImageInfo(format: .png, width: 8, height: 8, hasAlpha: false, estimatedMemory: 1_024)
    }
    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        lock.withLock { started += 1 }
        while lock.withLock({ held }), !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        try cancellation.check()
        return nil
    }
}
