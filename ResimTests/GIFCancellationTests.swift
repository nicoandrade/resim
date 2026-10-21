import XCTest
@testable import Resim

final class GIFCancellationTests: XCTestCase {
    func testCancellingAnActiveGIFHelperWaitsForItsExit() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "gif-static.gif", withExtension: nil, subdirectory: "Fixtures"))
        let sample = try Data(contentsOf: fixture)
        let firstFrame = try XCTUnwrap(sample.range(of: Data([0x21, 0xF9, 4])))
        var animation = sample.prefix(firstFrame.lowerBound)
        let frame = sample[firstFrame.lowerBound..<(sample.count - 1)]
        // 800 valid frames / 9.8MP keep the real helper alive long enough to
        // observe it, while staying below every admission/memory guard.
        for _ in 0..<800 { animation.append(frame) }
        animation.append(0x3B)
        let original = Data(animation)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("resim-gif-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source.gif")
        try original.write(to: source)
        _ = try NativeImageProcessor().inspect(source)
        let cancellation = CancellationToken()
        let task = Task.detached {
            try NativeImageProcessor().optimize(source: source, workDirectory: work,
                settings: .init(), cancellation: cancellation)
        }
        defer { cancellation.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        var observed = false
        while ContinuousClock.now < deadline {
            if try childIsRunning(in: work) { observed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("An actively cancelled GIF cannot return a candidate")
        } catch is CancellationError {
            // The helper has exited before cancellation is returned to the caller.
        }
        XCTAssertTrue(observed, "Exercise an actual running helper, not only pre-cancellation")
        XCTAssertFalse(try childIsRunning(in: work))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("source-optimized.gif").path))
    }

    private func childIsRunning(in directory: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // The unique private directory occurs only in this test's helper arguments.
        process.arguments = ["-f", directory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
