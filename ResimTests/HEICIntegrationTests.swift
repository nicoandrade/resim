import XCTest
import CoreGraphics
import ImageIO
@testable import Resim

final class HEICIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resim-heic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Generated locally; no personal photos or network fixtures.
    private func fixture(orientation: Int = 6, p3: Bool = false, width: Int = 512, height: Int = 384, colorful: Bool = false) throws -> Data {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            if colorful {
                rgba[offset] = UInt8((x * 255 / width + y / 5) % 256)
                rgba[offset + 1] = UInt8(y * 255 / height)
                rgba[offset + 2] = UInt8((x + y) * 127 / (width + height))
            } else {
                let value = UInt8(100 + ((x * 512 / width) / 3 + (y * 384 / height) / 3) / 8)
                rgba[offset] = value; rgba[offset + 1] = value; rgba[offset + 2] = value
            }
        }}
        let space = try XCTUnwrap(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        let image = try XCTUnwrap(rgba.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "https://resim.example/metadata/" as CFString,
                                                                "resim" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "resim:PrivateUnknownTag" as CFString,
                                                      "Opaque metadata must survive unchanged" as CFString))
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Fixture with accented text: Fóto Ñ",
                kCGImagePropertyExifDateTimeOriginal: "2026:10:20 15:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 30, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = data as Data
        let smoke = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/new-format-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: smoke, withIntermediateDirectories: true)
        if width == 512 { try result.write(to: smoke.appendingPathComponent("fixture.heic")) }
        return result
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as! [CFString: Any]
    }
    private func customMetadata(_ data: Data) throws -> String? {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, "resim:PrivateUnknownTag" as CFString) as String?
    }

    func testHEICAutomaticActuallyReducesAndPreservesOrientationICCAndOpaqueMetadata() throws {
        for p3 in [false, true] {
            let original = try fixture(p3: p3)
            let work = try directory()
            let input = work.appendingPathComponent("Fóto Ñ.HEIC")
            try original.write(to: input)
            let output = try XCTUnwrap(NativeImageProcessor().optimize(source: input, workDirectory: work,
                settings: .init(mode: .automatic), cancellation: CancellationToken()), "High quality fixture must actually reduce")
            let candidate = try Data(contentsOf: output)
            XCTAssertLessThan(candidate.count, original.count)
            XCTAssertEqual(try Data(contentsOf: input), original)
            let a = try decoded(original), b = try decoded(candidate)
            XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
            XCTAssertEqual(a.bitsPerComponent, b.bitsPerComponent)
            XCTAssertEqual(a.colorSpace?.copyICCData() as Data?, b.colorSpace?.copyICCData() as Data?)
            XCTAssertEqual(try properties(candidate)[kCGImagePropertyOrientation] as? Int, 6)
            XCTAssertTrue(NSDictionary(dictionary: try properties(original)).isEqual(to: try properties(candidate)))
            XCTAssertEqual(try customMetadata(original), "Opaque metadata must survive unchanged")
            XCTAssertEqual(try customMetadata(original), try customMetadata(candidate))
            XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?, "Exercises recompression")
            print("HEIC automatic \(p3 ? "Display P3" : "sRGB"): \(original.count) -> \(candidate.count)")
        }
    }

    func testHEICAutomaticRejectsCandidateThatFailsPerRGBQuality() throws {
        let original = try fixture(colorful: true)
        XCTAssertNil(try HEICProcessor().optimize(original, workDirectory: directory(),
            settings: .init(), cancellation: CancellationToken()))
    }

    func testHEICOrdinaryTwelveMegapixelPhotoFitsReservedBudget() throws {
        let data = try fixture(width: 4032, height: 3024)
        let info = try HEICProcessor().inspect(data)
        XCTAssertEqual(info.width, 4032); XCTAssertEqual(info.height, 3024)
        XCTAssertLessThanOrEqual(info.estimatedMemory, 512 * 1_024 * 1_024)
        XCTAssertGreaterThan(info.estimatedMemory, 387_629_056, "Reservation must cover measured standalone maximum RSS")
    }

    func testHEICLosslessPreservesOriginalAndExactSamples() throws {
        let original = try fixture(orientation: 1)
        let work = try directory()
        let input = work.appendingPathComponent("lossless.heic")
        try original.write(to: input)
        let output = try NativeImageProcessor().optimize(source: input, workDirectory: work,
            settings: .init(mode: .lossless), cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: input), original)
        if let output {
            let data = try Data(contentsOf: output)
            let a = try decoded(original), b = try decoded(data)
            XCTAssertEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
            XCTAssertLessThan(data.count, original.count)
        }
    }

    func testHEICRejectsHDRTransferFunctionAndHighBitDepthBeforeReencode() throws {
        let original = try fixture()
        // Valid native HEVC record with a higher declared sample precision. Never
        // decode to 8-bit and accidentally accept a tone-mapped or truncated image.
        let hvcc = try XCTUnwrap(original.range(of: Data("hvcC".utf8)))
        var highDepth = original
        highDepth[hvcc.upperBound + 17] |= 1
        XCTAssertThrowsError(try HEICProcessor().inspect(highDepth))
        let nclx = try XCTUnwrap(original.range(of: Data("nclx".utf8)))
        var hdr = original
        hdr[nclx.upperBound + 2] = 0; hdr[nclx.upperBound + 3] = 18 // HLG
        XCTAssertThrowsError(try HEICProcessor().inspect(hdr))
    }

    func testHEICRejectsUnknownContainerMetadataAndMalformedOffsets() throws {
        let original = try fixture()
        var unknown = original
        unknown.append(contentsOf: [0, 0, 0, 24])
        unknown.append(Data("uuid".utf8)); unknown.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try HEICProcessor().inspect(unknown))
        let iloc = try XCTUnwrap(original.range(of: Data("iloc".utf8)))
        var corrupt = original
        corrupt[iloc.upperBound + 4] = 0xFF // Unsupported extent widths
        XCTAssertThrowsError(try HEICProcessor().inspect(corrupt))
        // Native encoder's iloc v0: 4-byte offsets/lengths, no base offset;
        // metadata item #2 starts after the first 14-byte image-item record.
        XCTAssertEqual(original[iloc.upperBound], 0)
        XCTAssertEqual(original[iloc.upperBound + 4], 0x44)
        var repeatedExtents = original
        let metadataExtentCount = iloc.upperBound + 8 + 14 + 4
        repeatedExtents[metadataExtentCount] = 0x10
        repeatedExtents[metadataExtentCount + 1] = 0 // 4096 extents: fail before copying
        XCTAssertThrowsError(try HEICProcessor().inspect(repeatedExtents))
    }

    func testHEICCancelledAndUnsupportedStripNeverWritesCandidate() throws {
        let original = try fixture()
        let work = try directory()
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try HEICProcessor().optimize(original, workDirectory: work,
            settings: .init(), cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try HEICProcessor().optimize(original, workDirectory: work,
            settings: .init(stripPersonalMetadata: true), cancellation: CancellationToken()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("candidate.heic").path))
    }
}
