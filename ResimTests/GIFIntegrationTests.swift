import XCTest
import CoreGraphics
import ImageIO
@testable import Resim

final class GIFIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let url = root.appendingPathComponent("Fixtures/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        return url
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resim-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Independent fixture parser: preserves raw hundredths instead of ImageIO's
    /// playback-clamped delay (0 and 1 centisecond are deliberately exercised).
    private struct GIFFacts: Equatable {
        var delays: [Int] = []
        var disposals: [Int] = []
        var transparent: [Bool] = []
        var loop: Int?
        var extensions: [Data] = []
    }

    private func facts(_ data: Data, stripping: Bool = false) throws -> GIFFacts {
        let bytes = [UInt8](data)
        func require(_ condition: Bool) throws {
            if !condition { throw NSError(domain: "GIF fixture parser", code: 1) }
        }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        try require(bytes.count >= 13)
        var offset = 13
        if bytes[10] & 0x80 != 0 { offset += 3 * (1 << (Int(bytes[10] & 7) + 1)) }
        var result = GIFFacts(), delay = 0, disposal = 0, transparent = false
        func subblocks() throws -> Data {
            var payload = Data()
            while true {
                try require(offset < bytes.count)
                let size = Int(bytes[offset]); offset += 1
                if size == 0 { return payload }
                try require(offset + size <= bytes.count)
                payload.append(contentsOf: bytes[offset..<offset + size]); offset += size
            }
        }
        while offset < bytes.count {
            let start = offset, marker = bytes[offset]; offset += 1
            if marker == 0x3B { return result }
            if marker == 0x21 {
                try require(offset < bytes.count)
                let label = bytes[offset]; offset += 1
                let payload = try subblocks()
                if label == 0xF9 {
                    try require(payload.count == 4)
                    delay = Int(payload[1]) | Int(payload[2]) << 8
                    disposal = Int((payload[0] >> 2) & 7)
                    transparent = payload[0] & 1 != 0
                } else {
                    if label == 0xFF, payload.starts(with: Data("NETSCAPE2.0".utf8)) {
                        try require(payload.count == 14 && payload[11] == 1)
                        result.loop = Int(payload[12]) | Int(payload[13]) << 8
                    }
                    if !stripping || ![UInt8(0xFE), UInt8(0xCE)].contains(label) {
                        result.extensions.append(Data(bytes[start..<offset]))
                    }
                }
            } else if marker == 0x2C {
                try require(offset + 9 <= bytes.count)
                _ = word(offset + 4); _ = word(offset + 6)
                let packed = bytes[offset + 8]; offset += 9
                if packed & 0x80 != 0 { offset += 3 * (1 << (Int(packed & 7) + 1)) }
                try require(offset < bytes.count)
                offset += 1 // LZW minimum code size.
                _ = try subblocks()
                result.delays.append(delay); result.disposals.append(disposal)
                result.transparent.append(transparent)
                delay = 0; disposal = 0; transparent = false
            } else { throw NSError(domain: "GIF fixture marker", code: Int(marker)) }
        }
        throw NSError(domain: "GIF fixture trailer", code: 1)
    }

    /// Render every decoded frame in a common space independently of gifdiff.
    private func renderedFrames(_ data: Data) throws -> [Data] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(source)).map { index in
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
    }

    private func optimize(_ name: String, mode: OptimizationMode = .lossless,
                          stripping: Bool = false) throws -> (Data, Data) {
        let input = try fixture(name), original = try Data(contentsOf: input)
        let output = try XCTUnwrap(NativeImageProcessor().optimize(source: input, workDirectory: directory(),
            settings: .init(mode: mode, stripPersonalMetadata: stripping), cancellation: CancellationToken()),
            "Deliberately uncompressed GIF must actually reduce: \(name)")
        let candidate = try Data(contentsOf: output)
        XCTAssertLessThan(candidate.count, original.count)
        XCTAssertEqual(try Data(contentsOf: input), original, "Original must remain byte-identical")
        XCTAssertEqual(try renderedFrames(original), try renderedFrames(candidate), "Every composited frame must match")
        let before = try facts(original, stripping: stripping), after = try facts(candidate)
        XCTAssertEqual(before.delays, after.delays, "Raw 0/1 cs delays must survive without playback clamping")
        XCTAssertEqual(before.loop, after.loop)
        XCTAssertEqual(before.extensions, after.extensions, "Unknown metadata must survive byte-for-byte")
        print("GIF \(mode.rawValue) \(name) strip=\(stripping): \(original.count) -> \(candidate.count)")
        return (original, candidate)
    }

    func testStaticAndAnimatedGIFActuallyReduceInBothModes() throws {
        for mode in OptimizationMode.allCases {
            for name in ["gif-static.gif", "gif-animated.gif", "gif-loop-infinite.gif", "gif-no-loop.gif"] {
                _ = try optimize(name, mode: mode)
            }
        }
    }

    func testAnimationRetainsFrameCountMixedTimingTransparencyAndDisposalSemantics() throws {
        let (original, candidate) = try optimize("gif-animated.gif")
        let sourceFacts = try facts(original), outputFacts = try facts(candidate)
        XCTAssertEqual(sourceFacts.delays, [0, 1, 2, 7, 20, 7])
        XCTAssertEqual(sourceFacts.disposals, [1, 2, 3, 1, 1, 1])
        XCTAssertEqual(sourceFacts.transparent, [true, true, true, true, true, true])
        XCTAssertEqual(sourceFacts.loop, 3)
        XCTAssertEqual(outputFacts.delays.count, 6, "Identical trailing frame must remain present")
        let frames = try renderedFrames(original)
        XCTAssertEqual(frames[4], frames[5], "Fixture really exercises an identical frame")
        XCTAssertNotEqual(frames[0], frames[1], "Fixture really animates")
        // Optimizer may change disposal instructions when the rendered animation
        // remains exactly equal; renderedFrames above checks all six outputs.
        let info = try GIFProcessor().inspect(candidate)
        XCTAssertEqual(info.format, .gif); XCTAssertEqual(info.width, 64); XCTAssertEqual(info.height, 48)
        XCTAssertTrue(info.hasAlpha)
    }

    func testStripDropsOnlyCommentAndImageNamesKeepsICCXMPOpaqueApplicationAndLoop() throws {
        let (original, candidate) = try optimize("gif-animated.gif", stripping: true)
        let originalFacts = try facts(original), candidateFacts = try facts(candidate)
        for label in [UInt8(0xFE), UInt8(0xCE)] {
            XCTAssertTrue(originalFacts.extensions.contains { $0[1] == label })
            XCTAssertFalse(candidateFacts.extensions.contains { $0[1] == label })
        }
        for identifier in ["ICCRGBG1012", "XMP DataXMP", "RESIMTEST01", "NETSCAPE2.0"] {
            XCTAssertNotNil(candidate.range(of: Data(identifier.utf8)), identifier)
        }
    }

    func testContentSniffingIgnoresMisleadingExtensionAndRetainsOriginal() throws {
        let original = try Data(contentsOf: fixture("gif-animated.gif"))
        let work = try directory(), input = work.appendingPathComponent("Fóto Ñ 试.PNG")
        try original.write(to: input)
        XCTAssertEqual(try NativeImageProcessor().inspect(input).format, .gif)
        let output = try XCTUnwrap(NativeImageProcessor().optimize(source: input, workDirectory: work,
            settings: .init(), cancellation: CancellationToken()))
        XCTAssertEqual(output.pathExtension, "gif")
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testMalformedTruncatedAndDangerousExtensionsAreRejected() throws {
        let original = try Data(contentsOf: fixture("gif-static.gif"))
        for size in [0, 6, 12, 25, original.count - 1, original.count / 2] {
            XCTAssertThrowsError(try GIFProcessor().inspect(Data(original.prefix(size))), "Truncated at \(size)")
        }
        // Insert before first frame, at the known fixture's graphic control block.
        let gce = try XCTUnwrap(original.range(of: Data([0x21, 0xF9, 4])))
        var userInput = original
        userInput[gce.lowerBound + 3] |= 2
        XCTAssertThrowsError(try GIFProcessor().inspect(userInput))
        var reserved = original
        reserved[gce.lowerBound + 3] |= 0x80
        XCTAssertThrowsError(try GIFProcessor().inspect(reserved))
        var plainText = original
        plainText.insert(contentsOf: [0x21, 1, 12] + [UInt8](repeating: 0, count: 12) + [0], at: gce.lowerBound)
        XCTAssertThrowsError(try GIFProcessor().inspect(plainText))
        var trailing = original; trailing.append(1)
        XCTAssertThrowsError(try GIFProcessor().inspect(trailing))
    }

    func testOpaqueUnknownExtensionIsRetainedWithoutInterpretingItsPayload() throws {
        var original = try Data(contentsOf: fixture("gif-static.gif"))
        let gce = try XCTUnwrap(original.range(of: Data([0x21, 0xF9, 4])))
        let opaque = Data([0x21, 0xEE, 4, 42, 0, 255, 128, 0])
        original.insert(contentsOf: opaque, at: gce.lowerBound)
        let work = try directory(), source = work.appendingPathComponent("opaque.gif")
        try original.write(to: source)
        XCTAssertEqual(try GIFProcessor().inspect(original).format, .gif)
        let output = try XCTUnwrap(NativeImageProcessor().optimize(source: source, workDirectory: work,
            settings: .init(stripPersonalMetadata: true), cancellation: CancellationToken()))
        let candidate = try Data(contentsOf: output)
        XCTAssertLessThan(candidate.count, original.count)
        XCTAssertTrue(try facts(candidate).extensions.contains(opaque))
        XCTAssertEqual(try renderedFrames(original), try renderedFrames(candidate))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAdmissionRejectsOversizedCanvasCumulativePixelsAndTooManyFrames() throws {
        for name in ["gif-oversized.gif", "gif-cumulative-pixels.gif", "gif-too-many-frames.gif"] {
            XCTAssertThrowsError(try GIFProcessor().inspect(Data(contentsOf: fixture(name))), name)
        }
    }

    func testValidationRejectsChangedRawDelayLoopICCAndFrameCount() throws {
        let original = try Data(contentsOf: fixture("gif-animated.gif")), processor = GIFProcessor()
        XCTAssertTrue(processor.metadataAndTimingPreserved(original: original, candidate: original, stripping: false))
        let gce = try XCTUnwrap(original.range(of: Data([0x21, 0xF9, 4])))
        var delay = original; delay[gce.lowerBound + 4] = 1
        XCTAssertFalse(processor.metadataAndTimingPreserved(original: original, candidate: delay, stripping: false),
                       "Even raw 0 vs 1 cs must differ, though ImageIO clamps both for playback")
        let loop = try XCTUnwrap(original.range(of: Data("NETSCAPE2.0".utf8)))
        var differentLoop = original; differentLoop[loop.upperBound + 2] = 0
        XCTAssertFalse(processor.metadataAndTimingPreserved(original: original, candidate: differentLoop, stripping: false))
        let icc = try XCTUnwrap(original.range(of: Data("ICCRGBG1012".utf8)))
        var alteredICC = original; alteredICC[icc.upperBound + 10] ^= 1
        XCTAssertFalse(processor.metadataAndTimingPreserved(original: original, candidate: alteredICC, stripping: false))
        let controls = original.indices.filter { offset in
            offset + 2 < original.count && original[offset] == 0x21 && original[offset + 1] == 0xF9 && original[offset + 2] == 4
        }
        var lostFrame = original
        lostFrame.removeSubrange(try XCTUnwrap(controls.last)..<(original.count - 1))
        XCTAssertFalse(processor.metadataAndTimingPreserved(original: original, candidate: lostFrame, stripping: false))
    }

    func testBundledVisualComparatorRejectsChangedPalette() throws {
        let original = try Data(contentsOf: fixture("gif-animated.gif")), work = try directory()
        let a = work.appendingPathComponent("original.gif"), b = work.appendingPathComponent("degraded.gif")
        try original.write(to: a)
        var degraded = original; degraded[16] = 0; degraded[17] = 0; degraded[18] = 255
        try degraded.write(to: b)
        XCTAssertTrue(GIFProcessor().metadataAndTimingPreserved(original: original, candidate: degraded, stripping: false),
                      "Metadata alone cannot detect a changed palette; the visual comparator is required")
        XCTAssertNotEqual(try renderedFrames(original), try renderedFrames(degraded))
        let executable = try XCTUnwrap(Bundle.main.url(forResource: "gifdiff", withExtension: nil, subdirectory: "Codecs")
            ?? Bundle.main.url(forResource: "gifdiff", withExtension: nil))
        let process = Process(); process.executableURL = executable
        process.arguments = ["--brief", a.path, b.path]
        let log = work.appendingPathComponent("gifdiff-test.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, "Known changed pixels must fail real gifdiff")
    }

    func testAlreadyCancelledGIFLeavesOriginalAndWorkingDirectoryUntouched() throws {
        let input = try fixture("gif-animated.gif"), original = try Data(contentsOf: input)
        let work = try directory(), token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try NativeImageProcessor().optimize(source: input, workDirectory: work,
            settings: .init(), cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty,
                      "No helper or candidate should be launched for an already-cancelled job")
    }
}
