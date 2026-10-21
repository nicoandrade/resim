import Foundation
import ImageIO
import CoreGraphics
import zlib

/// Blocking codec work. The coordinator invokes this processor on its bounded worker pool.
nonisolated struct NativeImageProcessor: ImageProcessing {
    private static let maximumBytes = 100 * 1_024 * 1_024
    private static let maximumPixels = 40_000_000
    private static let maximumMemory: UInt64 = 512 * 1_024 * 1_024

    func inspect(_ source: URL) throws -> ImageInfo {
        let data = try read(source)
        return try inspect(data)
    }

    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        try cancellation.check()
        let original = try read(source)
        let info = try inspect(original, validatingPNG: true)
        guard info.estimatedMemory <= Self.maximumMemory else {
            throw ProcessingError.resourceLimit(String(localized: "The image needs more than 512 MB to process safely."))
        }
        if info.format == .png {
            return try optimizePNG(original, source: source, workDirectory: workDirectory,
                                   strip: settings.stripPersonalMetadata, cancellation: cancellation)
        }
        if info.format == .heic {
            return try HEICProcessor().optimize(original, workDirectory: workDirectory,
                                                settings: settings, cancellation: cancellation)
        }
        if info.format == .gif {
            return try GIFProcessor().optimize(original, source: source, workDirectory: workDirectory,
                                               settings: settings, cancellation: cancellation)
        }
        if info.format == .svg {
            return try SVGProcessor().optimize(original, source: source, workDirectory: workDirectory,
                                               settings: settings, cancellation: cancellation)
        }
        var buffer = RCBuffer(bytes: nil, size: 0)
        defer { rc_buffer_free(&buffer) }
        var error = [CChar](repeating: 0, count: 512)
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        let callback: RCShouldCancel = { context in
            guard let context else { return 1 }
            return Unmanaged<CancellationToken>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }
        let result = original.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            if info.format == .jpeg {
                return rc_jpeg_optimize(bytes, original.count, settings.mode == .automatic ? 1 : 0,
                                        settings.stripPersonalMetadata ? 1 : 0, callback, context, &buffer, &error, error.count)
            }
            if info.format == .avif {
                return rc_avif_optimize(bytes, original.count, settings.mode == .automatic ? 1 : 0,
                                        settings.stripPersonalMetadata ? 1 : 0, callback, context, &buffer, &error, error.count)
            }
            return rc_webp_optimize(bytes, original.count, settings.mode == .automatic ? 1 : 0,
                                    settings.stripPersonalMetadata ? 1 : 0, callback, context, &buffer, &error, error.count)
        }
        try cancellation.check()
        guard result != 0 else { throw ProcessingError.invalid(errorMessage(error)) }
        guard let bytes = buffer.bytes, buffer.size > 0, buffer.size < original.count else { return nil }
        let candidate = Data(bytes: bytes, count: buffer.size)
        let candidateInfo = try inspect(candidate, validatingPNG: true)
        guard candidateInfo.format == info.format, candidateInfo.width == info.width,
              candidateInfo.height == info.height, candidateInfo.hasAlpha == info.hasAlpha else { return nil }
        guard metadataPreserved(original, candidate, format: info.format, stripping: settings.stripPersonalMetadata) else { return nil }
        let output = workDirectory.appendingPathComponent("candidate.\(info.format.fileExtension)")
        try candidate.write(to: output, options: .atomic)
        try cancellation.check()
        return output
    }

    private func read(_ source: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max <= Self.maximumBytes else {
            throw ProcessingError.resourceLimit(String(localized: "The file exceeds the 100 MB limit."))
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes else { throw ProcessingError.resourceLimit(String(localized: "The file exceeds the 100 MB limit.")) }
        return data
    }

    private func inspect(_ data: Data, validatingPNG: Bool = false) throws -> ImageInfo {
        var native = RCImageInfo(width: 0, height: 0, has_alpha: 0, lossless: 0)
        var error = [CChar](repeating: 0, count: 512)
        let format: ImageFormat
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            format = .png
            let header = try inspectPNGHeader(data)
            native.width = Int32(header.width); native.height = Int32(header.height)
            native.has_alpha = header.alpha ? 1 : 0
            if validatingPNG {
                _ = try pngChunks(data, payloads: .none) // Full CRC validation belongs inside the reserved worker budget.
                guard let source = imageSource(data), CGImageSourceGetCount(source) == 1,
                      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
                    throw ProcessingError.invalid(String(localized: "The PNG is damaged or incomplete."))
                }
            }
        } else if data.starts(with: [255, 216]) {
            format = .jpeg
            let ok = data.withUnsafeBytes { raw in rc_jpeg_inspect(raw.bindMemory(to: UInt8.self).baseAddress!, data.count, &native, &error, error.count) }
            guard ok != 0 else { throw ProcessingError.unsupported(errorMessage(error)) }
        } else if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) {
            format = .webp
            let ok = data.withUnsafeBytes { raw in rc_webp_inspect(raw.bindMemory(to: UInt8.self).baseAddress!, data.count, &native, &error, error.count) }
            guard ok != 0 else { throw ProcessingError.unsupported(errorMessage(error)) }
        } else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return try GIFProcessor().inspect(data)
        } else if looksLikeXML(data) {
            return try SVGProcessor().inspect(data)
        } else if let containerFormat = isoImageFormat(data) {
            if containerFormat == .heic { return try HEICProcessor().inspect(data) }
            format = .avif
            let ok = data.withUnsafeBytes { raw in rc_avif_inspect(raw.bindMemory(to: UInt8.self).baseAddress!, data.count, &native, &error, error.count) }
            guard ok != 0 else { throw ProcessingError.unsupported(errorMessage(error)) }
        } else { throw ProcessingError.unsupported(String(localized: "Unsupported format. Use PNG, JPEG, WebP, HEIC, AVIF, GIF, or SVG.")) }
        let width = Int(native.width), height = Int(native.height)
        guard width > 0, height > 0, width <= Self.maximumPixels / height else {
            throw ProcessingError.resourceLimit(String(localized: "The image exceeds the 40-megapixel limit."))
        }
        // Conservative admission estimates include decoded images, validation scratch,
        // compressed copies and encoder workspace; they are not a hard RSS limit.
        let bytesPerPixel: UInt64 = format == .png ? 24 : (format == .avif ? 80 : 40)
        let memory = UInt64(width) * UInt64(height) * bytesPerPixel + UInt64(data.count) * 4 + 16 * 1_024 * 1_024
        return ImageInfo(format: format, width: width, height: height, hasAlpha: native.has_alpha != 0, estimatedMemory: memory)
    }

    private func looksLikeXML(_ data: Data) -> Bool {
        var prefix = data.prefix(65_536)
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { prefix = prefix.dropFirst(3) }
        return prefix.first(where: { ![9, 10, 13, 32].contains($0) }) == 60
    }

    /// Identify the ISO BMFF major/compatible brands only; the codec validates the container.
    /// This is independent of filename and avoids decoding pixels during admission.
    private func isoImageFormat(_ data: Data) -> ImageFormat? {
        guard data.count >= 16, data[4..<8] == Data("ftyp".utf8) else { return nil }
        let size = Int(big32(data, 0))
        guard size >= 16, size <= data.count, size <= 4096, size % 4 == 0 else { return nil }
        var brands = [String(decoding: data[8..<12], as: UTF8.self)]
        for offset in stride(from: 16, to: size, by: 4) {
            brands.append(String(decoding: data[offset..<(offset + 4)], as: UTF8.self))
        }
        if brands.contains(where: { ["avif", "avis"].contains($0) }) { return .avif }
        if brands.contains(where: { ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains($0) }) { return .heic }
        return nil
    }

    private func optimizePNG(_ original: Data, source: URL, workDirectory: URL, strip: Bool,
                             cancellation: CancellationToken) throws -> URL? {
        let bundled = Bundle.main.url(forResource: "oxipng", withExtension: nil, subdirectory: "Codecs")
            ?? Bundle.main.url(forResource: "oxipng", withExtension: nil)
        guard let executable = bundled, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessingError.unavailable(String(localized: "The PNG optimizer bundled with the app is missing."))
        }
        let output = workDirectory.appendingPathComponent("candidate.png")
        let process = Process()
        process.executableURL = executable
        // No sample/palette/bit-depth transformations. Keep color, gamma and EXIF untouched.
        var arguments = ["--opt", "2", "--threads", "1", "--nx", "--out", output.path]
        var pngSource = source
        if strip {
            pngSource = workDirectory.appendingPathComponent("metadata-clean.png")
            try cleanPNGExif(original).write(to: pngSource, options: .atomic)
        }
        arguments += ["--", pngSource.path]
        process.arguments = arguments
        // Directly to a file: no pipe can fill up and block the worker during cancellation.
        let log = workDirectory.appendingPathComponent("oxipng.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try cancellation.check()
        try process.run()
        while process.isRunning {
            if cancellation.isCancelled { process.terminate(); process.waitUntilExit(); try cancellation.check() }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        try cancellation.check()
        guard process.terminationStatus == 0 else { throw ProcessingError.invalid(String(localized: "The PNG optimizer could not validate the image.")) }
        guard FileManager.default.fileExists(atPath: output.path) else { return nil }
        let candidate = try read(output)
        guard candidate.count < original.count else { return nil }
        let a = try inspect(original), b = try inspect(candidate, validatingPNG: true)
        guard a.width == b.width, a.height == b.height, a.hasAlpha == b.hasAlpha,
              exactPNG(original, candidate, stripping: strip) else { return nil }
        return output
    }

    private func imageSource(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private func image(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private func exactPNG(_ a: Data, _ b: Data, stripping: Bool) -> Bool {
        autoreleasepool {
            // Validate metadata, ICC and raw samples with one decoded pair, rather
            // than decoding separate pairs for the profile and sample checks.
            guard metadataPreserved(a, b, format: .png, stripping: stripping),
                  let sa = imageSource(a), let sb = imageSource(b),
                  let x = image(sa), let y = image(sb),
                  x.width == y.width, x.height == y.height, x.bitsPerComponent == y.bitsPerComponent,
                  x.bitsPerPixel == y.bitsPerPixel, x.bytesPerRow == y.bytesPerRow, x.alphaInfo == y.alphaInfo,
                  x.colorSpace?.copyICCData() as Data? == y.colorSpace?.copyICCData() as Data?,
                  x.bitmapInfo == y.bitmapInfo, let xb = x.dataProvider?.data, let yb = y.dataProvider?.data else { return false }
            // --nx keeps the raw representation. This compares all decoded bytes, including 16-bit
            // samples and RGB beneath alpha 0, without premultiplication or an 8-bit conversion.
            return (xb as Data) == (yb as Data)
        }
    }

    private func metadataPreserved(_ a: Data, _ b: Data, format: ImageFormat, stripping: Bool) -> Bool {
        autoreleasepool {
            if format == .png {
                guard let ca = try? pngChunks(a, payloads: .metadata),
                      let cb = try? pngChunks(b, payloads: .metadata) else { return false }
                let ignored: Set<String> = ["IDAT", "IEND", "iCCP", "tRNS"]
                let ma = ca.filter { !ignored.contains($0.name) && !(stripping && shouldStripPNG($0)) }.map {
                    PNGChunk(name: $0.name, payload: stripping && $0.name == "eXIf" ? cleanExif($0.payload) : $0.payload)
                }
                let mb = cb.filter { !ignored.contains($0.name) && !(stripping && shouldStripPNG($0)) }
                guard ma.map(\.name) == mb.map(\.name), zip(ma, mb).allSatisfy({ $0.payload == $1.payload }),
                      equalPNGProfiles(ca, cb) else { return false }
                // The decoded ICC profile is checked alongside raw samples in exactPNG.
                return true
            }
            // The native bridge copies marker/chunk payloads and never transforms orientation or ICC.
            // Inspect again independently through Image I/O when that format is supported by macOS.
            if let sa = imageSource(a), let sb = imageSource(b),
               let pa = CGImageSourceCopyPropertiesAtIndex(sa, 0, nil) as? [CFString: Any],
               let pb = CGImageSourceCopyPropertiesAtIndex(sb, 0, nil) as? [CFString: Any] {
                let oa = pa[kCGImagePropertyOrientation] as? Int ?? 1, ob = pb[kCGImagePropertyOrientation] as? Int ?? 1
                guard oa == ob else { return false }
                if let x = image(sa), let y = image(sb),
                   x.colorSpace?.copyICCData() as Data? != y.colorSpace?.copyICCData() as Data? { return false }
            }
            return true
        }
    }

    private func equalPNGProfiles(_ a: [PNGChunk], _ b: [PNGChunk]) -> Bool {
        let x = a.filter { $0.name == "iCCP" }, y = b.filter { $0.name == "iCCP" }
        guard x.count == y.count else { return false }
        for (left, right) in zip(x, y) {
            guard let li = left.payload.firstIndex(of: 0), let ri = right.payload.firstIndex(of: 0),
                  left.payload.count > li + 2, right.payload.count > ri + 2,
                  li > 0, li <= 79, ri > 0, ri <= 79,
                  left.payload[li + 1] == 0, right.payload[ri + 1] == 0 else { return false }
            let lp = left.payload.subdata(in: (li + 2)..<left.payload.count)
            let rp = right.payload.subdata(in: (ri + 2)..<right.payload.count)
            let equal = lp.withUnsafeBytes { l in rp.withUnsafeBytes { r in
                rc_zlib_equal(l.bindMemory(to: UInt8.self).baseAddress, l.count, r.bindMemory(to: UInt8.self).baseAddress, r.count)
            }}
            guard equal != 0 else { return false }
        }
        return true
    }

    private func cleanExif(_ input: Data) -> Data {
        var output = RCBuffer(bytes: nil, size: 0)
        defer { rc_buffer_free(&output) }
        let ok = input.withUnsafeBytes { raw in
            rc_exif_strip(raw.bindMemory(to: UInt8.self).baseAddress, input.count, &output)
        }
        guard ok != 0, let bytes = output.bytes else { return input }
        return Data(bytes: bytes, count: output.size)
    }

    private func shouldStripPNG(_ chunk: PNGChunk) -> Bool {
        if chunk.name == "tIME" { return true }
        guard ["tEXt", "zTXt", "iTXt"].contains(chunk.name),
              let end = chunk.payload.firstIndex(of: 0),
              let keyword = String(data: chunk.payload.prefix(upTo: end), encoding: .isoLatin1) else { return false }
        // Unknown keywords and XMP packets can describe presentation. Preserve them whole.
        let personal = Set(["Title", "Author", "Description", "Copyright", "Creation Time", "Software", "Disclaimer", "Warning", "Source", "Comment"])
        return personal.contains(keyword)
    }

    private func crc(_ data: Data) -> UInt32 {
        // Every chunk is bounded by the 100 MiB input limit, below zlib's uInt limit.
        data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)))
        }
    }
    private func cleanPNGExif(_ input: Data) throws -> Data {
        var output = Data(input.prefix(8))
        for chunk in try pngChunks(input) {
            if shouldStripPNG(chunk) { continue }
            let payload = chunk.name == "eXIf" ? cleanExif(chunk.payload) : chunk.payload
            let count = UInt32(payload.count)
            output.append(contentsOf: [UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
            var body = Data(chunk.name.utf8); body.append(payload)
            output.append(body)
            let checksum = crc(body)
            output.append(contentsOf: [UInt8(checksum >> 24), UInt8(truncatingIfNeeded: checksum >> 16), UInt8(truncatingIfNeeded: checksum >> 8), UInt8(truncatingIfNeeded: checksum)])
        }
        return output
    }

    /// Admission reads only fixed-size headers from mapped data, without copying IDAT,
    /// inflating color profiles or decoding samples outside the coordinator's memory budget.
    private func inspectPNGHeader(_ data: Data) throws -> (width: Int, height: Int, alpha: Bool) {
        guard data.count >= 33, big32(data, 8) == 13, data[12..<16] == Data("IHDR".utf8) else {
            throw ProcessingError.invalid(String(localized: "The PNG header is damaged."))
        }
        let width = Int(big32(data, 16)), height = Int(big32(data, 20))
        guard width > 0, height > 0, width <= Self.maximumPixels / height else {
            throw ProcessingError.resourceLimit(String(localized: "The image exceeds the 40-megapixel limit."))
        }
        guard crc(data[12..<29]) == big32(data, 29) else {
            throw ProcessingError.invalid(String(localized: "The PNG header is damaged."))
        }
        var alpha = [4, 6].contains(data[25]), offset = 8, count = 0, hasImageData = false
        while offset < data.count {
            guard count < 4096 else { throw ProcessingError.resourceLimit(String(localized: "The PNG has too many chunks to process safely.")) }
            guard data.count - offset >= 12 else { throw ProcessingError.invalid(String(localized: "Incomplete PNG.")) }
            let size = Int(big32(data, offset))
            guard size <= data.count - offset - 12 else { throw ProcessingError.invalid(String(localized: "Incomplete PNG.")) }
            let name = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if ["acTL", "fcTL", "fdAT"].contains(name) {
                throw ProcessingError.unsupported(String(localized: "Animated PNG (APNG) is not supported."))
            }
            if name == "tRNS" { alpha = true }
            if name == "IDAT" { hasImageData = true }
            offset += size + 12; count += 1
            if name == "IEND" {
                guard size == 0, offset == data.count, hasImageData else { throw ProcessingError.invalid(String(localized: "Incomplete PNG.")) }
                return (width, height, alpha)
            }
        }
        throw ProcessingError.invalid(String(localized: "Incomplete PNG."))
    }

    private struct PNGChunk { let name: String; let payload: Data }
    private enum PNGPayloads { case all, metadata, none }
    private func pngChunks(_ data: Data, payloads: PNGPayloads = .all) throws -> [PNGChunk] {
        var chunks = [PNGChunk](), offset = 8
        while offset < data.count {
            guard chunks.count < 4096 else { throw ProcessingError.resourceLimit(String(localized: "The PNG has too many chunks to process safely.")) }
            guard data.count - offset >= 12 else { throw ProcessingError.invalid(String(localized: "Incomplete PNG.")) }
            let size = Int(big32(data, offset))
            guard size <= data.count - offset - 12,
                  let name = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
                throw ProcessingError.invalid(String(localized: "Incomplete PNG."))
            }
            guard crc(data[(offset + 4)..<(offset + 8 + size)]) == big32(data, offset + 8 + size) else {
                throw ProcessingError.invalid(String(localized: "The PNG has an invalid checksum."))
            }
            // Always validate and count image chunks, but only copy their compressed
            // payloads when rebuilding a metadata-clean PNG. Metadata comparisons
            // discard IDAT/IEND and inspection only needs the validation result.
            let capture = payloads == .all || (payloads == .metadata && name != "IDAT" && name != "IEND")
            let payload = capture ? data.subdata(in: (offset + 8)..<(offset + 8 + size)) : Data()
            chunks.append(PNGChunk(name: name, payload: payload))
            offset += size + 12
            if name == "IEND" { break }
        }
        guard chunks.last?.name == "IEND", offset == data.count else { throw ProcessingError.invalid(String(localized: "Incomplete PNG.")) }
        return chunks
    }
    private func big32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func errorMessage(_ chars: [CChar]) -> String {
        let message = chars.withUnsafeBufferPointer { pointer in String(cString: pointer.baseAddress!) }
        return message.isEmpty ? String(localized: "The codec could not validate the image.") : NSLocalizedString(message, comment: "Codec error")
    }
}
