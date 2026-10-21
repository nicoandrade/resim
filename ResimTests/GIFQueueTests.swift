import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
@testable import Resim

final class GIFQueueTests: XCTestCase {
    @MainActor
    func testLargeOpaqueAnimationActuallyShrinksWithExactFullResolutionFramesInBothModes() async throws {
        // Three full 1600×1200 frames, encoded locally with a clear code before
        // every palette sample. All bytes are real image data rather than padding.
        let original = largeAnimation()
        XCTAssertGreaterThan(original.count, 4_000_000)
        let originalHash = SHA256.hash(data: original)
        let referenceFrames = try renderedFrames(original)
        XCTAssertEqual(referenceFrames.count, 3)
        XCTAssertTrue(referenceFrames.allSatisfy { $0.count == 1_600 * 1_200 * 4 })
        XCTAssertNotEqual(referenceFrames[0], referenceFrames[1])
        XCTAssertNotEqual(referenceFrames[1], referenceFrames[2])
        try assertLargeAnimationTiming(original)

        for mode in OptimizationMode.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-large-gif-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("large-animation.gif")
            try original.write(to: source)
            let info = try NativeImageProcessor().inspect(source)
            XCTAssertEqual(info.width, 1_600); XCTAssertEqual(info.height, 1_200)
            XCTAssertFalse(info.hasAlpha)
            let preexistingWork = currentProcessWorkDirectories()
            let suite = "resim-large-gif-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.settings = .init(mode: mode, fileSaveMode: .copyBesideOriginal)
            let started = ContinuousClock.now
            model.addURLs([source])
            let deadline = started + .seconds(45)
            while model.hasActiveJobs && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if model.hasActiveJobs { model.cancelAll(); XCTFail("Large GIF queue timed out"); return }
            let job = try XCTUnwrap(model.jobs.first)
            XCTAssertEqual(job.state, .optimized, job.message ?? "Real LZW image data must actually shrink")
            let output = try XCTUnwrap(job.resultURL)
            XCTAssertNotEqual(output, source)
            let candidate = try Data(contentsOf: output)
            XCTAssertLessThan(candidate.count, original.count)
            XCTAssertEqual(job.originalBytes, Int64(original.count))
            XCTAssertEqual(job.resultBytes, Int64(candidate.count))
            XCTAssertEqual(try renderedFrames(candidate), referenceFrames,
                           "Compare every RGBA sample of all three full-resolution composited frames")
            try assertLargeAnimationTiming(candidate)
            XCTAssertTrue(GIFProcessor().metadataAndTimingPreserved(original: original, candidate: candidate, stripping: false))
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), originalHash)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { $0.resolvingSymlinksInPath() }),
                           Set([source, output].map { $0.resolvingSymlinksInPath() }), "No hidden stages, logs, snapshots, or extra outputs may remain")
            XCTAssertEqual(currentProcessWorkDirectories(), preexistingWork,
                           "The private helper work directory must be cleaned before the queue finishes")
            print("GIF large \(mode.rawValue): 1600x1200 x3, \(original.count) -> \(candidate.count), elapsed=\(started.duration(to: .now)), full-resolution RGBA/timing/loop exact, source SHA256 unchanged")
        }
    }

    @MainActor
    func testOpaqueAnimationCanPublishTransparentDeltaFramesInBothModes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "gif-opaque-delta.gif", withExtension: nil, subdirectory: "Fixtures"))
        let original = try Data(contentsOf: fixture)
        XCTAssertEqual(original.count, 1_612)
        let referenceFrames = try renderedFrames(original)
        XCTAssertEqual(referenceFrames.count, 2)
        XCTAssertNotEqual(referenceFrames[0], referenceFrames[1])
        for frame in referenceFrames {
            XCTAssertTrue(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 },
                          "Both full frames must be opaque before GIF delta optimization")
        }

        for mode in OptimizationMode.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resim-gif-delta-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("opaque.gif")
            try original.write(to: source)
            XCTAssertFalse(try NativeImageProcessor().inspect(source).hasAlpha)
            let suite = "resim-gif-delta-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.settings.mode = mode
            model.addURLs([source])
            let deadline = ContinuousClock.now + .seconds(20)
            while model.hasActiveJobs && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if model.hasActiveJobs { model.cancelAll(); XCTFail("GIF queue timed out"); return }
            let job = try XCTUnwrap(model.jobs.first)
            XCTAssertEqual(job.state, .optimized, job.message ?? "The valid delta animation must publish")
            let output = try XCTUnwrap(job.resultURL)
            let candidate = try Data(contentsOf: output)
            XCTAssertLessThan(candidate.count, original.count)
            XCTAssertTrue(try NativeImageProcessor().inspect(output).hasAlpha,
                          "The fixture must exercise the optimizer's transparent delta-frame representation")
            XCTAssertEqual(try renderedFrames(candidate), referenceFrames,
                           "Transparency in encoded deltas must not change the composited pixels")
            XCTAssertTrue(GIFProcessor().metadataAndTimingPreserved(original: original, candidate: candidate, stripping: false))
            XCTAssertEqual(output, source, "Default mode replaces the original without renaming it")
            XCTAssertEqual(try Data(contentsOf: source), candidate)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["opaque.gif"])
            print("GIF opaque delta \(mode.rawValue): \(original.count) -> \(candidate.count), exact rendered frames")
        }
    }

    /// Apple Image I/O independently validates composited pixels rather than the
    /// optimizer's per-frame transparent-palette flags.
    private func renderedFrames(_ data: Data) throws -> [Data] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(source)).map { index in
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
    }

    private func assertLargeAnimationTiming(_ data: Data) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        // Image I/O reports four total plays for a Netscape repeat count of
        // three. Compare the original raw repeat field independently instead.
        let loopHeader = Data([0x21, 0xFF, 11]) + Data("NETSCAPE2.0".utf8) + Data([3, 1])
        let loop = try XCTUnwrap(data.range(of: loopHeader))
        let offset = loop.upperBound
        XCTAssertLessThan(offset + 2, data.count)
        XCTAssertEqual(Int(data[offset]) | Int(data[offset + 1]) << 8, 3)
        XCTAssertEqual(data[offset + 2], 0)
        for (index, expected) in [0.07, 0.13, 0.25].enumerated() {
            let frame = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let control = try XCTUnwrap(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try XCTUnwrap((control[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue)
            XCTAssertEqual(delay, expected, accuracy: 0.000_001)
        }
    }

    private func currentProcessWorkDirectories() -> Set<URL> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let prefix = "resim-\(ProcessInfo.processInfo.processIdentifier)-"
        return Set(entries.filter { $0.lastPathComponent.hasPrefix(prefix) })
    }

    /// Equivalent to the tiny Python fixture generator, generated in memory to
    /// avoid checking a four-megabyte uncompressed animation into the repository.
    private func largeAnimation() -> Data {
        let width = 1_600, height = 1_200
        var result = Data("GIF89a".utf8)
        func word(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8)] }
        result.append(contentsOf: word(width) + word(height) + [0xF1, 0, 0])
        result.append(contentsOf: [0, 0, 0, 250, 110, 70, 70, 170, 230, 255, 220, 130])
        result.append(contentsOf: [0x21, 0xFF, 11])
        result.append(contentsOf: Data("NETSCAPE2.0".utf8))
        result.append(contentsOf: [3, 1] + word(3) + [0])
        for (frame, delay) in [7, 13, 25].enumerated() {
            result.append(contentsOf: [0x21, 0xF9, 4, 4] + word(delay) + [0, 0])
            // Separate the descriptor fields to keep Swift 6.2 type checking bounded.
            result.append(0x2C)
            result.append(contentsOf: word(0))
            result.append(contentsOf: word(0))
            result.append(contentsOf: word(width))
            result.append(contentsOf: word(height))
            result.append(contentsOf: [0, 2])
            var compressed = [UInt8]()
            compressed.reserveCapacity(width * height * 3 / 4 + 1)
            var accumulator = 0, available = 0
            func code(_ value: Int) {
                accumulator |= value << available
                available += 3
                while available >= 8 {
                    compressed.append(UInt8(accumulator & 255))
                    accumulator >>= 8; available -= 8
                }
            }
            let left = 80 + frame * 280
            for y in 0..<height {
                for x in 0..<width {
                    let sample = (240..<520).contains(y) && (left..<(left + 280)).contains(x) ? frame + 1 : 0
                    code(4); code(sample)
                }
            }
            code(5)
            if available > 0 { compressed.append(UInt8(accumulator & 255)) }
            for offset in stride(from: 0, to: compressed.count, by: 255) {
                let end = min(offset + 255, compressed.count)
                result.append(UInt8(end - offset))
                result.append(contentsOf: compressed[offset..<end])
            }
            result.append(0)
        }
        result.append(0x3B)
        return result
    }
}
