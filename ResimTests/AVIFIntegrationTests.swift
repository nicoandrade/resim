import XCTest
import ImageIO
@testable import Resim

final class AVIFIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let url = root.appendingPathComponent("Fixtures").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        return url
    }
    private func candidate(_ name: String, mode: OptimizationMode = .lossless, strip: Bool = false) throws -> (Data, Data?) {
        let source = try fixture(name), original = try Data(contentsOf: source)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("resim-avif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let processor = NativeImageProcessor()
        let output = try processor.optimize(source: source, workDirectory: work,
                                            settings: .init(mode: mode, stripPersonalMetadata: strip), cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: source), original, "AVIF original must stay byte-identical")
        guard let output else { return (original, nil) }
        let optimized = try Data(contentsOf: output)
        XCTAssertLessThan(optimized.count, original.count)
        let a = try processor.inspect(source), b = try processor.inspect(output)
        XCTAssertEqual(a.format, b.format)
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        XCTAssertEqual(a.hasAlpha, b.hasAlpha)
        return (original, optimized)
    }
    private func nativeEqual(_ a: Data, _ b: Data) -> Int32 {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in
            rc_avif_pixels_equal(x.bindMemory(to: UInt8.self).baseAddress, x.count,
                                 y.bindMemory(to: UInt8.self).baseAddress, y.count)
        }}
    }
    private func qualityPass(_ a: Data, _ b: Data) -> Int32 {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in
            rc_avif_ssim_rgb(x.bindMemory(to: UInt8.self).baseAddress, x.count,
                             y.bindMemory(to: UInt8.self).baseAddress, y.count)
        }}
    }
    func testLosslessAVIFPreservesNativeYUVAndTransparentRGB() throws {
        for name in ["avif-lossless-alpha.avif", "avif-lossy.avif"] {
            let (original, output) = try candidate(name)
            XCTAssertEqual(nativeEqual(original, try XCTUnwrap(output)), 1, name)
        }
    }
    func testAVIFRetainsICCExifXMPAndAllPresentationTransforms() throws {
        let (original, output) = try candidate("avif-orientation-icc.avif")
        let result = try XCTUnwrap(output)
        // Native comparison includes ICC/Exif/XMP, CICP, range, chroma, crop, aspect, mirror and rotation.
        XCTAssertEqual(nativeEqual(original, result), 1)
        XCTAssertNotNil(result.range(of: Data("Resim Private Artist XX".utf8)))
        XCTAssertNotNil(result.range(of: Data("https://resim.example/essential/".utf8)))
    }
    func testAVIFPrivacyStripsPersonalExifAndKeepsPresentationMetadata() throws {
        let (original, output) = try candidate("avif-orientation-icc.avif", strip: true)
        let result = try XCTUnwrap(output)
        XCTAssertNotNil(original.range(of: Data("Resim Private Artist XX".utf8)))
        XCTAssertNil(result.range(of: Data("Resim Private Artist XX".utf8)))
        XCTAssertNotNil(result.range(of: Data("https://resim.example/essential/".utf8)), "Unknown XMP semantics must survive")
        let a = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let b = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        let ap = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(a, 0, nil)) as NSDictionary
        let bp = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(b, 0, nil)) as NSDictionary
        XCTAssertEqual(ap[kCGImagePropertyOrientation] as? Int, bp[kCGImagePropertyOrientation] as? Int)
        let ai = try XCTUnwrap(CGImageSourceCreateImageAtIndex(a, 0, nil))
        let bi = try XCTUnwrap(CGImageSourceCreateImageAtIndex(b, 0, nil))
        XCTAssertEqual(ai.colorSpace?.copyICCData() as Data?, bi.colorSpace?.copyICCData() as Data?)
        XCTAssertEqual(ai.dataProvider?.data as Data?, bi.dataProvider?.data as Data?)
    }
    func testAutomaticAVIFAcceptsOnlySmallerQualityValidatedRecompression() throws {
        let (original, output) = try candidate("avif-auto.avif", mode: .automatic)
        let result = try XCTUnwrap(output, "Smooth lossless AVIF must exercise automatic recompression")
        XCTAssertEqual(nativeEqual(original, result), 0, "Fixture must actually change encoded samples")
        XCTAssertEqual(qualityPass(original, result), 1, "Every RGB channel must meet 30 dB SSIM; alpha stays exact")
        print("AVIF automatic \(original.count) -> \(result.count)")
    }
    func testAVIFQualityGateRejectsDegradedPixels() throws {
        let original = try Data(contentsOf: fixture("avif-lossy.avif"))
        let degraded = try Data(contentsOf: fixture("avif-degraded.avif"))
        XCTAssertEqual(qualityPass(original, original), 1)
        XCTAssertEqual(qualityPass(original, degraded), 0)
    }
    func testAVIFRejectsAnimationHDRGainMapUnknownPropertiesAndCorruption() throws {
        for name in ["avif-animated.avif", "avif-hdr10.avif", "avif-gain-map.avif", "avif-unknown-property.avif"] {
            XCTAssertThrowsError(try NativeImageProcessor().inspect(fixture(name)), name)
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("resim-corrupt-\(UUID().uuidString).avif")
        defer { try? FileManager.default.removeItem(at: work) }
        try Data((try Data(contentsOf: fixture("avif-auto.avif"))).prefix(40)).write(to: work)
        XCTAssertThrowsError(try NativeImageProcessor().inspect(work))
    }
    func testAVIFAlreadyCancelledNeverReturnsCandidate() throws {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try NativeImageProcessor().optimize(source: fixture("avif-auto.avif"),
                                                               workDirectory: FileManager.default.temporaryDirectory,
                                                               settings: .init(), cancellation: token))
    }
}
