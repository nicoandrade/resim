import XCTest
import ImageIO
@testable import Resim

final class CodecIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let url = root.appendingPathComponent("Fixtures").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        return url
    }
    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("resim-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }
    private func candidate(_ name: String, settings: OptimizationSettings = .init(mode: .lossless)) throws -> (Data, Data?) {
        let source = try fixture(name)
        let before = try Data(contentsOf: source)
        let processor = NativeImageProcessor()
        let output = try processor.optimize(source: source, workDirectory: temporaryDirectory(), settings: settings, cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: source), before, "Original must remain byte-identical")
        let visualNames = ["photo-quality100.jpg", "smooth-auto.jpg", "lossy.webp", "rgba.png", "rgb16.png", "accepted-auto.jpg"]
        let visualRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/visual-qa/\(name)")
        if visualNames.contains(name) {
            try FileManager.default.createDirectory(at: visualRoot, withIntermediateDirectories: true)
            try before.write(to: visualRoot.appendingPathComponent("original.\(source.pathExtension)"))
        }
        guard let output else {
            if visualNames.contains(name) { try Data("No reduction: candidate rejected or not smaller".utf8).write(to: visualRoot.appendingPathComponent("\(settings.mode.rawValue)-unchanged.txt")) }
            return (before, nil)
        }
        let result = try Data(contentsOf: output)
        if visualNames.contains(name) { try result.write(to: visualRoot.appendingPathComponent("candidate-\(settings.mode.rawValue).\(source.pathExtension)")) }
        XCTAssertLessThan(result.count, before.count)
        let originalInfo = try processor.inspect(source)
        let outputInfo = try processor.inspect(output)
        XCTAssertEqual(originalInfo.format, outputInfo.format)
        XCTAssertEqual(originalInfo.width, outputInfo.width)
        XCTAssertEqual(originalInfo.height, outputInfo.height)
        XCTAssertEqual(originalInfo.hasAlpha, outputInfo.hasAlpha)
        return (before, result)
    }
    func testPNGVariantsAndUnicodeAreLossless() throws {
        for name in ["rgba.png", "rgb16.png", "palette.png", "Fóto Ñ 试.PNG", "fine-lines.png"] {
            let (original, output) = try candidate(name)
            let result = try XCTUnwrap(output, "Uncompressed fixture must reduce: \(name)")
            let a = try decodePNG(original)
            let b = try decodePNG(result)
            XCTAssertEqual(a.depth, b.depth, "Original precision must survive: \(name)")
            XCTAssertEqual(a.data, b.data, "Decoded native samples must match: \(name)")
        }
    }
    private func decodePNG(_ data: Data) throws -> (depth: Int, data: Data) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
        let provider = try XCTUnwrap(image.dataProvider)
        // ImageIO's native sample provider: no draw, 8-bit conversion or premultiplication.
        return (image.bitsPerComponent, try XCTUnwrap(provider.data) as Data)
    }
    func testJPEGUsesIdenticalDCTCoefficients() throws {
        for name in ["landscape.jpg", "photo-ijg.jpg", "icc-444.jpg", "grayscale.jpg", "progressive.jpg", "orientation-gps.jpg", "already-compressed.jpg"] {
            let (original, candidate) = try candidate(name)
            guard let candidate else { continue }
            let equal = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                           b.bindMemory(to: UInt8.self).baseAddress, b.count)
            }}
            XCTAssertEqual(equal, 1, name)
            if name == "orientation-gps.jpg" {
                let a = try properties(original)
                let b = try properties(candidate)
                XCTAssertEqual(a[kCGImagePropertyOrientation] as? Int, b[kCGImagePropertyOrientation] as? Int)
                XCTAssertNotNil(b[kCGImagePropertyGPSDictionary])
            }
        }
    }
    func testWebPLosslessPreservesTransparentRGBExactly() throws {
        let (original, output) = try candidate("exact-alpha.webp")
        guard let output else { return }
        let equal = original.withUnsafeBytes { a in output.withUnsafeBytes { b in
            rc_webp_pixels_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                 b.bindMemory(to: UInt8.self).baseAddress, b.count)
        }}
        XCTAssertEqual(equal, 1)
    }
    func testLossyWebPStrictModePreservesImageBitstream() throws {
        let (original, output) = try candidate("lossy.webp")
        guard let output else { return }
        XCTAssertEqual(try chunks(original).filter { ["VP8 ", "ALPH"].contains($0.0) }.map(\.1),
                       try chunks(output).filter { ["VP8 ", "ALPH"].contains($0.0) }.map(\.1))
    }
    func testAutomaticProducesOnlyValidatedSmallerCandidates() throws {
        for name in ["landscape.jpg", "already-compressed.jpg", "lossy.webp"] {
            _ = try candidate(name, settings: .init(mode: .automatic, profile: .conservative))
        }
    }
    func testConservativeQualityGateReportsRGBChannels() throws {
        for name in ["landscape.jpg", "photo-ijg.jpg", "photo-quality100.jpg", "smooth-auto.jpg", "icc-444.jpg", "already-compressed.jpg", "lossy.webp"] {
            let (original, output) = try candidate(name, settings: .init(mode: .automatic, profile: .conservative))
            guard let output else { continue }
            var scores = [Float](repeating: 0, count: 5)
            let pass = original.withUnsafeBytes { a in output.withUnsafeBytes { b in
                if name.hasSuffix("jpg") {
                    return rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                           b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
                }
                return rc_webp_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                       b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
            }}
            XCTAssertEqual(pass, 1, "Accepted candidate must pass per-RGB SSIM and exact alpha: \(name) \(scores)")
            XCTAssertTrue(scores.prefix(3).allSatisfy { $0.isFinite && $0 >= 30 })
            print("SSIM \(name) B/G/R/A/All \(scores)")
        }
    }
    func testConservativeRecompressionAcceptedAtCalibratedThreshold() throws {
        let (original, result) = try candidate("accepted-auto.jpg", settings: .init(mode: .automatic, profile: .conservative))
        let output = try XCTUnwrap(result)
        var scores = [Float](repeating: 0, count: 5)
        let (coefficientsEqual, pass) = original.withUnsafeBytes { a in output.withUnsafeBytes { b in
            (rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                        b.bindMemory(to: UInt8.self).baseAddress, b.count),
             rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                              b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores))
        }}
        XCTAssertEqual(coefficientsEqual, 0, "Fixture must exercise actual automatic recompression")
        XCTAssertEqual(pass, 1)
        XCTAssertTrue(scores.prefix(3).allSatisfy { $0 >= 30 && $0 < 99 })
        print("SSIM ACCEPT auto B/G/R/A/All \(scores), bytes \(original.count) -> \(output.count)")
    }
    func testSSIMRejectsKnownDegradedImageAndAcceptsIdenticalOriginal() throws {
        let original = try Data(contentsOf: fixture("icc-444.jpg"))
        let degraded = try Data(contentsOf: fixture("degraded.jpg"))
        var identicalScores = [Float](repeating: 0, count: 5)
        var degradedScores = [Float](repeating: 0, count: 5)
        let identicalPass = original.withUnsafeBytes { a in
            rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                             a.bindMemory(to: UInt8.self).baseAddress, a.count, &identicalScores)
        }
        let degradedPass = original.withUnsafeBytes { a in degraded.withUnsafeBytes { b in
            rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                             b.bindMemory(to: UInt8.self).baseAddress, b.count, &degradedScores)
        }}
        XCTAssertEqual(identicalPass, 1)
        XCTAssertEqual(degradedPass, 0)
        XCTAssertTrue(degradedScores.prefix(3).contains { $0 < 30 })
        print("SSIM REJECT known degraded B/G/R/A/All \(degradedScores)")
    }
    func testMetadataRemovalRetainsOrientation() throws {
        let (_, output) = try candidate("orientation-gps.jpg", settings: .init(mode: .lossless, stripPersonalMetadata: true))
        let p = try properties(XCTUnwrap(output))
        XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary])
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
    }
    func testAnimatedAndCorruptFilesAreExcludedByContent() throws {
        for name in ["animated.png", "animated.webp", "corrupt.png", "not-image.jpg", "cmyk.jpg"] {
            XCTAssertThrowsError(try NativeImageProcessor().inspect(fixture(name)), name)
        }
    }
    func testAlreadyCancelledCodecNeverReturnsCandidate() throws {
        let cancellation = CancellationToken()
        cancellation.cancel()
        XCTAssertThrowsError(try NativeImageProcessor().optimize(source: fixture("rgba.png"), workDirectory: temporaryDirectory(), settings: .init(), cancellation: cancellation))
    }
    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as! [CFString: Any]
    }
    private func chunks(_ data: Data) throws -> [(String, Data)] {
        var result: [(String, Data)] = []
        var offset = 12
        while offset + 8 <= data.count {
            let bytes = [UInt8](data[(offset+4)..<(offset+8)])
            let size = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
            guard offset + 8 + size <= data.count else { throw NSError(domain: "fixture", code: 1) }
            result.append((String(decoding: data[offset..<(offset+4)], as: UTF8.self), Data(data[(offset+8)..<(offset+8+size)])))
            offset += 8 + size + size % 2
        }
        return result
    }
}
