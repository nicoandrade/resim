import XCTest
import zlib
@testable import Resim

final class CodecSafetyTests: XCTestCase {
    private let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private func fixture(_ name: String) throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try Data(contentsOf: root.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resim-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func optimize(_ data: Data, extension ext: String) throws -> Data {
        let work = try directory()
        let source = work.appendingPathComponent("original").appendingPathExtension(ext)
        try data.write(to: source)
        let result = try NativeImageProcessor().optimize(
            source: source, workDirectory: work,
            settings: .init(mode: .lossless, stripPersonalMetadata: true), cancellation: CancellationToken())
        XCTAssertEqual(try Data(contentsOf: source), data)
        return try Data(contentsOf: XCTUnwrap(result, "The fixture must produce a copy to verify its metadata"))
    }

    func testUnknownDefaultAndPrefixedXMPNamespacesSurviveMetadataRemoval() throws {
        let jpeg = try fixture("photo-ijg.jpg")
        for declaration in ["xmlns=\"urn:vendor:unknown\"", "xmlns:vendor=\"urn:vendor:unknown\""] {
            let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description \(declaration)><UnknownPresentation>mirror</UnknownPresentation></rdf:Description></rdf:RDF></x:xmpmeta>
            """
            let payload = Data("http://ns.adobe.com/xap/1.0/\0\(packet)".utf8)
            let source = jpeg.prefix(2) + jpegMarker(0xE1, payload: payload) + jpeg.dropFirst(2)
            let result = try optimize(Data(source), extension: "jpg")
            XCTAssertTrue(try jpegAPP1Markers(result).contains(payload), "Unknown namespaces must be preserved: \(declaration)")
        }
    }

    func testXMPWithEntityDeclarationsIsPreservedConservatively() throws {
        let jpeg = try fixture("photo-ijg.jpg")
        let packet = """
        <!DOCTYPE x:xmpmeta [<!ENTITY value "unknown">]><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description>&value;</rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let payload = Data("http://ns.adobe.com/xap/1.0/\0\(packet)".utf8)
        let source = jpeg.prefix(2) + jpegMarker(0xE1, payload: payload) + jpeg.dropFirst(2)
        let result = try optimize(Data(source), extension: "jpg")
        XCTAssertTrue(try jpegAPP1Markers(result).contains(payload))
    }

    func testHugePNGDimensionsAreRejectedBeforeParsingOrDecodingTheBody() throws {
        for (width, height) in [(UInt32.max, UInt32(1)), (UInt32(10_000), UInt32(10_000)), (UInt32(1), UInt32.max)] {
            var header = bigEndian(width) + bigEndian(height)
            header.append(contentsOf: [8, 6, 0, 0, 0])
            var png = signature + pngChunk("IHDR", payload: header)
            // A deliberately truncated body would produce invalid/checksum errors if parsed first.
            png.append(contentsOf: [255, 255, 255, 255, 73])
            let source = try directory().appendingPathComponent("huge.png")
            try png.write(to: source)
            XCTAssertThrowsError(try NativeImageProcessor().inspect(source)) {
                guard case ProcessingError.resourceLimit = $0 else {
                    return XCTFail("Dimensions must be rejected before reading chunks or allocating buffers: \($0)")
                }
            }
        }
    }

    func testExcessivePNGChunksAreRejectedWithSmallInput() throws {
        let original = try pngChunks(fixture("rgba.png"))
        var data = signature + pngChunk("IHDR", payload: try XCTUnwrap(original.first?.1))
        let ancillary = pngChunk("ruSt", payload: Data())
        for _ in 0..<4_100 { data.append(ancillary) }
        for chunk in original.dropFirst() { data.append(pngChunk(chunk.0, payload: chunk.1)) }
        XCTAssertLessThan(data.count, 200_000)
        let source = try directory().appendingPathComponent("too-many-chunks.png")
        try data.write(to: source)
        XCTAssertThrowsError(try NativeImageProcessor().inspect(source)) {
            guard case ProcessingError.resourceLimit = $0 else { return XCTFail("Expected resourceLimit: \($0)") }
        }
    }

    func testPNGImageDataChecksumIsValidatedWithoutCopyingItsPayload() throws {
        var original = try fixture("rgba.png")
        var offset = 8
        var corrupted = false
        while offset + 12 <= original.count {
            let size = original[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let name = String(decoding: original[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if name == "IDAT", size > 0 {
                original[offset + 8] ^= 1 // Keep the old CRC to require rejection before decoding.
                corrupted = true
                break
            }
            offset += size + 12
        }
        XCTAssertTrue(corrupted)
        let work = try directory()
        let source = work.appendingPathComponent("invalid-checksum.png")
        try original.write(to: source)
        // Admission intentionally checks headers only; the reserved worker validates every CRC.
        XCTAssertEqual(try NativeImageProcessor().inspect(source).format, .png)
        XCTAssertThrowsError(try NativeImageProcessor().optimize(
            source: source, workDirectory: work, settings: .init(), cancellation: CancellationToken())) {
            guard case ProcessingError.invalid = $0 else { return XCTFail("Expected checksum rejection: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("candidate.png").path))
    }

    func testExcessivePNGImageDataChunksStillCountTowardTheLimit() throws {
        let chunks = try pngChunks(fixture("rgba.png"))
        var original = signature + pngChunk("IHDR", payload: try XCTUnwrap(chunks.first?.1))
        let emptyImageData = pngChunk("IDAT", payload: Data())
        for _ in 0..<4_100 { original.append(emptyImageData) }
        for chunk in chunks.dropFirst() { original.append(pngChunk(chunk.0, payload: chunk.1)) }
        let work = try directory()
        let source = work.appendingPathComponent("too-many-image-chunks.png")
        try original.write(to: source)
        XCTAssertThrowsError(try NativeImageProcessor().optimize(
            source: source, workDirectory: work, settings: .init(), cancellation: CancellationToken())) {
            guard case ProcessingError.resourceLimit = $0 else { return XCTFail("Expected chunk limit: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPNGICCProfileBytesSurviveOptimizationAndPersonalMetadataRemoval() throws {
        let profile = try fixture("sRGB.icc")
        let compressed = try compress(profile, level: 0)
        var payload = Data("Resim sRGB\0".utf8)
        payload.append(0)
        payload.append(compressed)
        let chunks = try pngChunks(fixture("rgba.png"))
        var original = signature
        for (name, data) in chunks where name != "sRGB" && name != "gAMA" && name != "iCCP" {
            original.append(pngChunk(name, payload: data))
            if name == "IHDR" { original.append(pngChunk("iCCP", payload: payload)) }
        }
        let result = try optimize(original, extension: "png")
        let profiles = try pngChunks(result).filter { $0.0 == "iCCP" }
        XCTAssertEqual(profiles.count, 1)
        let saved = try XCTUnwrap(profiles.first?.1)
        let nameEnd = try XCTUnwrap(saved.firstIndex(of: 0))
        // Oxipng can canonicalize the human-readable label to "icc". Color interpretation
        // depends on the exact decompressed profile below, not the PNG chunk label.
        XCTAssertFalse(saved.prefix(upTo: nameEnd).isEmpty)
        XCTAssertEqual(saved[nameEnd + 1], 0)
        let savedStream = saved.subdata(in: (nameEnd + 2)..<saved.count)
        XCTAssertEqual(try decompress(savedStream, expectedSize: profile.count), profile,
                       "Compare the complete profile bytes; ImageIO may ignore a different or damaged profile")
    }

    func testICCStreamComparisonRejectsDifferentAndTruncatedProfiles() throws {
        let profile = try fixture("sRGB.icc")
        let stored = try compress(profile, level: 0)
        let recompressed = try compress(profile, level: 9)
        var different = profile
        different[different.count - 1] ^= 1
        let changed = try compress(different, level: 9)
        XCTAssertEqual(equalStreams(stored, recompressed), 1)
        XCTAssertEqual(equalStreams(stored, changed), 0)
        XCTAssertEqual(equalStreams(stored, Data(recompressed.dropLast())), 0)
    }

    private func equalStreams(_ a: Data, _ b: Data) -> Int32 {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in
            rc_zlib_equal(x.bindMemory(to: UInt8.self).baseAddress, a.count,
                          y.bindMemory(to: UInt8.self).baseAddress, b.count)
        }}
    }

    private func compress(_ data: Data, level: Int32) throws -> Data {
        var size = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(size))
        let status = data.withUnsafeBytes { input in
            compress2(&output, &size, input.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), level)
        }
        XCTAssertEqual(status, Z_OK)
        return Data(output.prefix(Int(size)))
    }

    private func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        var size = uLongf(expectedSize)
        var output = [UInt8](repeating: 0, count: expectedSize)
        let status = data.withUnsafeBytes { input in
            uncompress(&output, &size, input.bindMemory(to: UInt8.self).baseAddress, uLong(data.count))
        }
        XCTAssertEqual(status, Z_OK)
        XCTAssertEqual(Int(size), expectedSize)
        return Data(output.prefix(Int(size)))
    }

    private func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private func pngChunk(_ name: String, payload: Data) -> Data {
        let body = Data(name.utf8) + payload
        let checksum = body.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, uInt(body.count))
        }
        return bigEndian(UInt32(payload.count)) + body + bigEndian(UInt32(checksum))
    }

    private func pngChunks(_ data: Data) throws -> [(String, Data)] {
        var result: [(String, Data)] = [], offset = 8
        while offset + 12 <= data.count {
            let size = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard size <= data.count - offset - 12 else { throw NSError(domain: "CodecSafetyTests", code: 1) }
            let name = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append((name, data.subdata(in: (offset + 8)..<(offset + 8 + size))))
            offset += 12 + size
        }
        return result
    }

    private func jpegMarker(_ marker: UInt8, payload: Data) -> Data {
        let size = payload.count + 2
        return Data([255, marker, UInt8(size >> 8), UInt8(size & 255)]) + payload
    }

    private func jpegAPP1Markers(_ data: Data) throws -> [Data] {
        var output: [Data] = [], offset = 2
        while offset + 4 <= data.count {
            guard data[offset] == 255 else { throw NSError(domain: "CodecSafetyTests", code: 2) }
            let marker = data[offset + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let size = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            guard size >= 2, size <= data.count - offset - 2 else { throw NSError(domain: "CodecSafetyTests", code: 3) }
            if marker == 0xE1 { output.append(data.subdata(in: (offset + 4)..<(offset + size + 2))) }
            offset += size + 2
        }
        return output
    }
}
