import XCTest
import ImageIO
@testable import Resim

final class WebPMetadataTests: XCTestCase {
    func testStrictLossyWebPRemovesPersonalMetadataWithoutTouchingImageOrICC() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("resim-webp-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sourceImage = try fixture("lossy.webp")
        let profile = try fixture("sRGB.icc")
        let exif = try exifFromJPEG(fixture("orientation-gps.jpg"))
        let imageChunks = try chunks(sourceImage).filter { ["VP8 ", "VP8L", "ALPH"].contains($0.0) }
        // Fixture canvas is 192 x 128. VP8X flags: ICC (0x20), EXIF (0x08), XMP (0x04).
        let extended = Data([0x2c, 0, 0, 0, 191, 0, 0, 127, 0, 0])
        let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>" + String(repeating: "Resim fixture author ", count: 200) + "</dc:creator></rdf:Description></rdf:RDF></x:xmpmeta>"
        let original = riff([("VP8X", extended), ("ICCP", profile)] + imageChunks + [("EXIF", exif), ("XMP ", Data(packet.utf8))])
        let source = work.appendingPathComponent("with-metadata.webp")
        try original.write(to: source)
        let processor = NativeImageProcessor()
        _ = try processor.inspect(source)
        XCTAssertNil(try processor.optimize(source: source, workDirectory: work, settings: .init(mode: .lossless), cancellation: CancellationToken()), "Default lossy strict mode must preserve the complete source bitstream and metadata")
        let output = try XCTUnwrap(processor.optimize(source: source, workDirectory: work,
            settings: .init(mode: .lossless, stripPersonalMetadata: true), cancellation: CancellationToken()))
        let optimized = try Data(contentsOf: output)
        XCTAssertLessThan(optimized.count, original.count)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let result = try chunks(optimized)
        XCTAssertEqual(result.filter { ["VP8 ", "VP8L", "ALPH"].contains($0.0) }.map(\.1), imageChunks.map(\.1))
        XCTAssertEqual(result.first { $0.0 == "ICCP" }?.1, profile)
        XCTAssertFalse(result.contains { $0.0 == "XMP " })
        let sourceProperties = try properties(original)
        let outputProperties = try properties(optimized)
        XCTAssertEqual(sourceProperties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(outputProperties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(outputProperties[kCGImagePropertyGPSDictionary])
    }
    private func fixture(_ name: String) throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try Data(contentsOf: root.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }
    private func properties(_ data: Data) throws -> [CFString: Any] {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil)) as! [CFString: Any]
    }
    private func exifFromJPEG(_ jpeg: Data) throws -> Data {
        var at = 2
        while at + 4 <= jpeg.count && jpeg[at] == 0xff {
            let marker = jpeg[at + 1]
            if marker == 0xda || marker == 0xd9 { break }
            let count = Int(jpeg[at + 2]) * 256 + Int(jpeg[at + 3])
            guard count >= 2, at + 2 + count <= jpeg.count else { break }
            let payload = jpeg.subdata(in: at + 4..<at + 2 + count)
            if marker == 0xe1 && payload.starts(with: Data("Exif\0\0".utf8)) { return payload.dropFirst(6) }
            at += count + 2
        }
        throw NSError(domain: "FixtureEXIF", code: 1)
    }
    private func chunks(_ data: Data) throws -> [(String, Data)] {
        var output: [(String, Data)] = []
        var at = 12
        while at + 8 <= data.count {
            let n = Int(data[at+4]) | Int(data[at+5]) << 8 | Int(data[at+6]) << 16 | Int(data[at+7]) << 24
            guard n <= data.count - at - 8 else { throw NSError(domain: "FixtureRIFF", code: 1) }
            output.append((String(decoding: data[at..<at+4], as: UTF8.self), data.subdata(in: at+8..<at+8+n)))
            at += 8 + n + n % 2
        }
        return output
    }
    private func little(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    private func riff(_ chunks: [(String, Data)]) -> Data {
        var payload = Data("WEBP".utf8)
        for (name, bytes) in chunks {
            payload.append(Data(name.utf8)); payload.append(little(bytes.count)); payload.append(bytes)
            if bytes.count % 2 != 0 { payload.append(0) }
        }
        return Data("RIFF".utf8) + little(payload.count) + payload
    }
}
