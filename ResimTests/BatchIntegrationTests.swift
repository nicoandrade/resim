import XCTest
import CryptoKit
import ImageIO
@testable import Resim

final class BatchIntegrationTests: XCTestCase {
    @MainActor
    func testSevenFormatsShareQueueAndPublishCorrectExtensionsWithoutOverwriting() async throws {
        try await checkSevenFormats(replacing: false)
    }

    @MainActor
    func testSevenFormatsReplaceOriginalsWithSameNamesByDefault() async throws {
        try await checkSevenFormats(replacing: true)
    }

    @MainActor
    private func checkSevenFormats(replacing: Bool) async throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var sources = try ["rgba.png", "landscape.jpg", "exact-alpha.webp", "gif-animated.gif", "svg-icon.svg"].map { name in
            let url = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture(name), to: url)
            return url
        }
        // Content, rather than the misleading extension, determines the output type.
        let avif = directory.appendingPathComponent("Imagen Ñ.dat")
        try FileManager.default.copyItem(at: fixture("avif-auto.avif"), to: avif)
        sources.append(avif)
        let heic = directory.appendingPathComponent("Photo.HEIF")
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithURL(try fixture("landscape.jpg") as CFURL, nil))
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(encoder, jpeg, 0, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        sources.append(heic)
        let hashes = try sources.map(hash)
        let originalInfo = try sources.map { try NativeImageProcessor().inspect($0) }
        let sentinel = destination.appendingPathComponent("Imagen Ñ-optimized.avif")
        let sentinelData = Data("existing destination".utf8)
        try sentinelData.write(to: sentinel)
        let model = AppModel(defaults: try XCTUnwrap(UserDefaults(suiteName: "resim-seven-formats-\(UUID().uuidString)")))
        if !replacing { model.settings = .init(mode: .automatic, destination: destination) }
        model.addURLs(sources)
        try await wait(model)
        XCTAssertEqual(model.completedCount, 7)
        XCTAssertEqual(model.failedCount + model.excludedCount, 0)
        if !replacing { XCTAssertEqual(try sources.map(hash), hashes) }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        let avifJob = try XCTUnwrap(model.jobs.first { $0.sourceURL == avif })
        XCTAssertEqual(avifJob.state, .optimized)
        XCTAssertEqual(avifJob.resultURL?.lastPathComponent, replacing ? "Imagen Ñ.dat" : "Imagen Ñ-optimized-2.avif")
        let heicJob = try XCTUnwrap(model.jobs.first { $0.sourceURL == heic })
        if let output = heicJob.resultURL { XCTAssertEqual(output.pathExtension, "HEIF") }
        for (index, job) in model.jobs.enumerated() {
            if let output = job.resultURL {
                let info = try NativeImageProcessor().inspect(output)
                XCTAssertEqual(info.format, originalInfo[index].format)
                XCTAssertEqual(info.width, originalInfo[index].width)
                XCTAssertEqual(info.height, originalInfo[index].height)
                let outputBytes = try SafeFiles.fingerprint(output).bytes
                let originalBytes = try XCTUnwrap(job.originalBytes)
                XCTAssertLessThan(outputBytes, originalBytes)
                if replacing { XCTAssertEqual(output, job.sourceURL) }
            } else {
                XCTAssertEqual(try hash(job.sourceURL), hashes[index])
            }
        }
        if replacing {
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                           Set(sources.map(\.lastPathComponent) + ["output"]))
        }
    }

    @MainActor
    func testRealMixedTwentyPreservesOriginalsAndNeverOverwrites() async throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sources = try corpus(count: 20, in: directory)
        let originalHashes = try sources.map(hash)
        let sentinel = destination.appendingPathComponent("foto-0-optimized.png")
        let sentinelData = Data("existing file must survive".utf8)
        try sentinelData.write(to: sentinel)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resim-batch-\(UUID().uuidString)"))
        let model = AppModel(defaults: defaults)
        model.settings = .init(mode: .lossless, destination: destination)
        let start = ContinuousClock.now
        model.addURLs(sources)
        while model.jobs.count < sources.count && start.duration(to: .now) < .seconds(5) {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.jobs.count, 20)
        let feedback = start.duration(to: .now)
        print("REAL_ADMISSION_FEEDBACK_20_MS \(milliseconds(feedback))")
        // Admission must expose rows without waiting for codec completion. The product target is
        // measured here; avoid turning environment scheduling jitter into a flaky correctness test.
        XCTAssertLessThan(feedback, .seconds(5))
        try await wait(model)
        XCTAssertEqual(model.completedCount, 20)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertEqual(model.excludedCount, 0)
        XCTAssertEqual(try sources.map(hash), originalHashes)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertEqual(Set(model.jobs.compactMap(\.resultURL)).count, model.jobs.filter { $0.state == .optimized }.count)
        XCTAssertEqual(model.savedBytes, model.jobs.reduce(0) { $0 + $1.savedBytes })
        for job in model.jobs {
            if let output = job.resultURL {
                XCTAssertLessThan(try Data(contentsOf: output).count, try Data(contentsOf: job.sourceURL).count)
                XCTAssertEqual(try NativeImageProcessor().inspect(output).format, try NativeImageProcessor().inspect(job.sourceURL).format)
            }
        }
        let produced = model.jobs.compactMap(\.resultURL)
        model.clearFinished()
        for _ in 0..<100 where !model.jobs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.jobs.isEmpty)
        model.addURLs(produced)
        try await wait(model)
        XCTAssertTrue(model.jobs.isEmpty, "Session outputs stay excluded even after clearing the list")
    }

    @MainActor
    func testRealHundredImagesAllowsAddingWhileRunning() async throws {
        let directory = try makeDirectory()
        let sources = try corpus(count: 100, in: directory)
        let originalHashes = try sources.map(hash)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "resim-stress-\(UUID().uuidString)"))
        let model = AppModel(defaults: defaults)
        model.settings = .init(mode: .automatic, fileSaveMode: .copyBesideOriginal)
        model.addURLs(Array(sources.prefix(20)))
        // Add the rest before waiting for the first batch to complete.
        model.addURLs(Array(sources.dropFirst(20)))
        try await wait(model, timeout: .seconds(120))
        XCTAssertEqual(model.jobs.count, 100)
        XCTAssertEqual(model.completedCount, 100)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertEqual(try sources.map(hash), originalHashes)
        XCTAssertEqual(model.progress, 1)
    }

    @MainActor
    func testRealMixedExclusionsDoNotStopValidImages() async throws {
        let directory = try makeDirectory()
        let sources = try corpus(count: 3, in: directory)
        let wrong = directory.appendingPathComponent("corrupt.jpg")
        try Data([0xff, 0xd8, 0, 0]).write(to: wrong)
        let apng = try fixture("animated.png")
        let model = AppModel(defaults: try XCTUnwrap(UserDefaults(suiteName: "resim-excluded-\(UUID().uuidString)")))
        model.settings.mode = .lossless
        model.addURLs(sources + [wrong, apng, directory])
        try await wait(model)
        XCTAssertEqual(model.jobs.count, 6)
        XCTAssertEqual(model.completedCount, 3)
        XCTAssertEqual(model.excludedCount + model.failedCount, 3)
    }

    @MainActor
    private func wait(_ model: AppModel, timeout: Duration = .seconds(60)) async throws {
        let start = ContinuousClock.now
        while model.hasActiveJobs && start.duration(to: .now) < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hasActiveJobs, "Batch timed out")
        if model.hasActiveJobs { model.cancelAll(); throw NSError(domain: "BatchTimeout", code: 1) }
    }
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-real-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }
    private func corpus(count: Int, in directory: URL) throws -> [URL] {
        let names = ["rgba.png", "landscape.jpg", "exact-alpha.webp", "rgb16.png", "lossy.webp"]
        return try (0..<count).map { index in
            let name = names[index % names.count]
            let ext = URL(fileURLWithPath: name).pathExtension
            let output = directory.appendingPathComponent(index == 0 ? "photo-0.png" : "Imagen Ñ 试 \(index).\(ext)")
            try FileManager.default.copyItem(at: fixture(name), to: output)
            return output
        }
    }
    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
