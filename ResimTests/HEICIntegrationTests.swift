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
    private func fixture(orientation: Int = 6, p3: Bool = false, width: Int = 512, height: Int = 384, colorful: Bool = false, flat: Bool = false, padded: Bool = false) throws -> Data {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            if colorful {
                rgba[offset] = UInt8((x * 255 / width + y / 5) % 256)
                rgba[offset + 1] = UInt8(y * 255 / height)
                rgba[offset + 2] = UInt8((x + y) * 127 / (width + height))
            } else {
                let value = flat ? UInt8(128) : UInt8(100 + ((x * 512 / width) / 3 + (y * 384 / height) / 3) / 8)
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
        var result = data as Data
        if padded {
            // A valid, removable ISO-BMFF free box guarantees space to reduce
            // independently of the OS's hardware/software encoder efficiency.
            var size = UInt32(16_384 + 8).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(Data("free".utf8))
            result.append(Data(repeating: 0, count: 16_384))
        }
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

    func testHEICAutomaticReducesPaddedImageAndPreservesOrientationICCAndOpaqueMetadata() throws {
        for p3 in [false, true] {
            // Flat samples pass the unchanged RGB quality gate on both native
            // encoder implementations. Colorful rejection is tested separately.
            let original = try fixture(p3: p3, flat: true, padded: true)
            let work = try directory()
            let input = work.appendingPathComponent("Fóto Ñ.HEIC")
            try original.write(to: input)
            let output = try XCTUnwrap(NativeImageProcessor().optimize(source: input, workDirectory: work,
                settings: .init(mode: .automatic), cancellation: CancellationToken()), "Padded flat fixture must reduce")
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
            print("HEIC automatic \(p3 ? "Display P3" : "sRGB"): \(original.count) -> \(candidate.count)")
        }
    }

    func testHEICSmoothImagePreservesOriginalAcrossNativeEncoderQualityDifferences() throws {
        let original = try fixture()
        let work = try directory()
        let input = work.appendingPathComponent("smooth.heic")
        try original.write(to: input)
        let output = try NativeImageProcessor().optimize(source: input, workDirectory: work,
            settings: .init(mode: .automatic), cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: input), original)
        if let output {
            XCTAssertLessThan(try Data(contentsOf: output).count, original.count)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("candidate.heic").path))
        }
    }

    func testHEICConservativeRejectsCandidateThatFailsPerRGBQuality() throws {
        let original = try fixture(colorful: true)
        XCTAssertNil(try HEICProcessor().optimize(original, workDirectory: directory(),
            settings: .init(profile: .conservative), cancellation: CancellationToken()))
    }

    func testHEICProfilesPreservePresentationAndRespectQualityFloors() throws {
        let original = try fixture(colorful: true, padded: true)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let image = try decoded(original), a = try pixels(image)
        var previousSize = original.count
        for profile in CompressionProfile.allCases {
            let output = try HEICProcessor().optimize(original, workDirectory: directory(),
                settings: .init(profile: profile), cancellation: CancellationToken())
            let result = try output.map { try Data(contentsOf: $0) } ?? original
            XCTAssertLessThanOrEqual(result.count, previousSize)
            previousSize = result.count
            XCTAssertTrue(NSDictionary(dictionary: try properties(original)).isEqual(to: try properties(result)))
            XCTAssertEqual(try customMetadata(original), try customMetadata(result))
            let candidate = try decoded(result)
            XCTAssertEqual(image.width, candidate.width); XCTAssertEqual(image.height, candidate.height)
            XCTAssertEqual(image.colorSpace?.copyICCData() as Data?, candidate.colorSpace?.copyICCData() as Data?)
            XCTAssertEqual(rc_rgba_quality_rgb(a, try pixels(candidate), Int32(image.width), Int32(image.height), profile.codecValue), 1)
        }
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
