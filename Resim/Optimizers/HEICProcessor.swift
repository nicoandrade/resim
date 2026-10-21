import Foundation
import CoreGraphics
import ImageIO

/// ImageIO's native HEVC encoder, bounded to one conservative automatic candidate.
/// Opaque EXIF/XMP items are copied back verbatim because ImageIO normalizes EXIF
/// during encoding, including tags it doesn't expose through its property API.
nonisolated struct HEICProcessor {
    private let maximumPixels = 40_000_000

    func inspect(_ data: Data) throws -> ImageInfo {
        let (_, properties, _) = try source(data)
        return try imageInfo(properties: properties, bytes: data.count)
    }

    private func imageInfo(properties: [CFString: Any], bytes: Int) throws -> ImageInfo {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height else {
            throw ProcessingError.resourceLimit(String(localized: "The image exceeds the 40-megapixel limit."))
        }
        return ImageInfo(format: .heic, width: width, height: height,
                         hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
                         // Keep the conservative reserve from the earlier 4032x3024
                         // profile after reducing overlapping decode/validation buffers.
                         estimatedMemory: UInt64(width) * UInt64(height) * 40 + UInt64(bytes) * 4 + 16 * 1_024 * 1_024)
    }

    func optimize(_ original: Data, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL? {
        try cancellation.check()
        let (input, properties, originalItems) = try source(original)
        let info = try imageInfo(properties: properties, bytes: original.count)
        guard info.estimatedMemory <= 512 * 1_024 * 1_024 else {
            throw ProcessingError.resourceLimit(String(localized: "The image needs more than 512 MB to process safely."))
        }
        // Opaque metadata preservation and personal tag removal cannot both be
        // guaranteed by ImageIO. Never silently publish an incompletely stripped file.
        guard !settings.stripPersonalMetadata else {
            throw ProcessingError.unsupported(String(localized: "Removing personal metadata from HEIC is not supported yet. Turn off this option to optimize it."))
        }
        // Preserve rejection of unreadable or non-RGB inputs even when a native
        // lossless copy would return No Reduction, without retaining its CGImage.
        try validateInput(input)
        var best: Data?
        // Always include a safe copy. Each lossy attempt starts from the admitted
        // source, never the preceding candidate. Release native buffers per pass.
        let attempts = Int(rc_profile_attempts(settings.codecProfile))
        for step in -1..<attempts {
            try cancellation.check()
            let candidate: Data? = try autoreleasepool {
                let quality: Double? = step < 0 ? nil : rc_profile_quality(settings.codecProfile, 3, Int32(step))
                guard let encoded = try encode(input, smallerThan: best?.count ?? original.count,
                                               quality: quality, cancellation: cancellation),
                      let candidate = try? preserveOpaqueMetadata(originalItems, in: encoded),
                      candidate.count < (best?.count ?? original.count) else { return nil }
                try cancellation.check()
                guard let decoded = CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                      decoded.bitsPerComponent == 8, decoded.colorSpace?.model == .rgb else { throw unsupported() }
                guard let (result, resultProperties, resultItems) = try? source(candidate),
                      NSDictionary(dictionary: properties).isEqual(to: resultProperties),
                      originalItems.map(\.key) == resultItems.map(\.key),
                      zip(originalItems, resultItems).allSatisfy({ $0.payload == $1.payload }),
                      let resultImage = CGImageSourceCreateImageAtIndex(result, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                      decoded.width == resultImage.width, decoded.height == resultImage.height,
                      decoded.bitsPerComponent == resultImage.bitsPerComponent,
                      decoded.colorSpace?.copyICCData() as Data? == resultImage.colorSpace?.copyICCData() as Data? else { return nil }
                if quality == nil {
                    guard exactSamples(decoded, resultImage) else { return nil }
                } else {
                    let a = try rgba(decoded), b = try rgba(resultImage)
                    try cancellation.check()
                    let valid = a.withUnsafeBytes { left in b.withUnsafeBytes { right in
                        rc_rgba_quality_rgb(left.bindMemory(to: UInt8.self).baseAddress,
                                            right.bindMemory(to: UInt8.self).baseAddress,
                                            Int32(decoded.width), Int32(decoded.height), settings.codecProfile)
                    }}
                    guard valid != 0 else { return nil }
                }
                return candidate
            }
            if let candidate { best = candidate }
        }
        try cancellation.check()
        guard let best else { return nil }
        let url = workDirectory.appendingPathComponent("candidate.heic")
        try best.write(to: url, options: .atomic)
        try cancellation.check()
        return url
    }

    private func validateInput(_ input: CGImageSource) throws {
        try autoreleasepool {
            guard let image = CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.bitsPerComponent == 8, image.colorSpace?.model == .rgb else {
                throw unsupported()
            }
        }
    }

    /// Return only encoded bytes across this scope, so encoder sessions and their
    /// Foundation/ImageIO temporaries cannot overlap the validation buffers.
    private func encode(_ input: CGImageSource, smallerThan originalBytes: Int, quality: Double?,
                        cancellation: CancellationToken) throws -> Data? {
        try autoreleasepool {
            try cancellation.check()
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else {
                throw ProcessingError.unavailable(String(localized: "The HEIC encoder is not available on this Mac."))
            }
            if quality == nil {
                // Copy the encoded image without HEVC recompression. An unavailable
                // or non-improving native copy remains a valid No Reduction result.
                guard CGImageDestinationCopyImageSource(destination, input, nil, nil) else { return nil }
            } else {
                CGImageDestinationAddImageFromSource(destination, input, 0, [
                    kCGImageDestinationLossyCompressionQuality: quality!,
                    kCGImageDestinationOptimizeColorForSharing: false,
                    kCGImageDestinationEmbedThumbnail: false
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ProcessingError.invalid(String(localized: "The HEIC encoder could not process the image."))
                }
            }
            try cancellation.check()
            guard output.length > 0, output.length < originalBytes else { return nil }
            return output as Data
        }
    }

    private func source(_ data: Data) throws -> (CGImageSource, [CFString: Any], [MetadataItem]) {
        guard data.count <= 100 * 1_024 * 1_024 else { throw unsupported() }
        // Admission rejects auxiliary references and oversized metadata before
        // ImageIO can materialize auxiliary images or parse arbitrary EXIF/XMP.
        let container = try Container(data)
        guard
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.heic",
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetPrimaryImageIndex(source) == 0,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw unsupported() }
        guard (p[kCGImagePropertyDepth] as? Int ?? 8) == 8,
              !(p[kCGImagePropertyIsFloat] as? Bool ?? false),
              (p["Headroom" as CFString] as? Double ?? 1) <= 1,
              p[kCGImagePropertyHEICSDictionary] == nil else { throw unsupported() }
        var auxiliary: [CFString] = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap]
        if #available(macOS 15, *) { auxiliary.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        guard !auxiliary.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) else { throw unsupported() }
        return (source, p, container.metadata)
    }

    private func unsupported() -> ProcessingError {
        .unsupported(String(localized: "Only 8-bit SDR HEIC images without sequences, depth maps, or auxiliary data are supported."))
    }

    private func exactSamples(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.bitsPerPixel == b.bitsPerPixel, a.bytesPerRow == b.bytesPerRow,
              a.alphaInfo == b.alphaInfo, a.bitmapInfo == b.bitmapInfo,
              let x = a.dataProvider?.data, let y = b.dataProvider?.data else { return false }
        return x as Data == y as Data
    }

    private func rgba(_ image: CGImage) throws -> Data {
        var pixels = Data(count: image.width * image.height * 4)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { throw ProcessingError.invalid(String(localized: "Could not validate the HEIC image.")) }
        return pixels
    }

    private struct MetadataItem {
        let key: Data // Item type, name, MIME type and encoding; excludes the unstable item ID.
        let payload: Data
        let offsetField: Int
        let offsetBytes: Int
        let lengthField: Int
        let lengthBytes: Int
    }

    private func preserveOpaqueMetadata(_ original: [MetadataItem], in data: Data) throws -> Data {
        let parsed = try Container(data)
        guard parsed.metadata.map(\.key) == original.map(\.key) else { throw unsupported() }
        var result = data
        for (before, after) in zip(original, parsed.metadata) where before.payload != after.payload {
            // New mdat keeps every old location valid. Only the metadata item's
            // absolute extent is redirected. The source is never changed.
            let offset = result.count + 8
            guard before.payload.count <= Int(UInt32.max) - 8 else { throw unsupported() }
            var size = UInt32(before.payload.count + 8).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(Data("mdat".utf8)); result.append(before.payload)
            try Container.write(offset, to: &result, at: after.offsetField, bytes: after.offsetBytes)
            try Container.write(before.payload.count, to: &result, at: after.lengthField, bytes: after.lengthBytes)
        }
        return result
    }

    /// Small bounded ISO-BMFF reader. Unknown item/metadata containers fail closed.
    /// This also finds auxiliary/high-bit-depth image properties before decoding.
    private struct Container {
        struct Box { let type: String; let payload: Int; let end: Int }
        let data: Data
        var metadata: [MetadataItem] = []
        init(_ data: Data) throws {
            self.data = data
            let top = try boxes(0, data.count)
            guard top.allSatisfy({ ["ftyp", "meta", "mdat", "free", "skip"].contains($0.type) }),
                  let meta = top.first(where: { $0.type == "meta" }),
                  top.filter({ $0.type == "meta" }).count == 1 else { throw bad() }
            let children = try boxes(meta.payload + 4, meta.end)
            guard children.allSatisfy({ ["hdlr", "dinf", "pitm", "iinf", "iloc", "iref", "iprp", "idat"].contains($0.type) }),
                  let iinf = children.first(where: { $0.type == "iinf" }),
                  let iloc = children.first(where: { $0.type == "iloc" }) else { throw bad() }
            if let refs = children.first(where: { $0.type == "iref" }) {
                guard try boxes(refs.payload + 4, refs.end).allSatisfy({ ["cdsc", "dimg", "thmb"].contains($0.type) }) else { throw bad() }
            }
            if let iprp = children.first(where: { $0.type == "iprp" }) {
                for ipco in try boxes(iprp.payload, iprp.end) where ipco.type == "ipco" {
                    for property in try boxes(ipco.payload, ipco.end) {
                        guard ["hvcC", "ispe", "pixi", "colr", "irot", "imir", "clap", "clli", "mdcv"].contains(property.type) else { throw bad() }
                        if property.type == "hvcC" {
                            guard property.end - property.payload >= 19,
                                  data[property.payload + 17] & 7 == 0, data[property.payload + 18] & 7 == 0 else { throw bad() }
                        }
                        if property.type == "pixi" {
                            guard property.end - property.payload >= 5 else { throw bad() }
                            let count = Int(data[property.payload + 4])
                            guard property.payload + 5 + count <= property.end,
                                  data[(property.payload + 5)..<(property.payload + 5 + count)].allSatisfy({ $0 == 8 }) else { throw bad() }
                        }
                        if property.type == "colr", property.end - property.payload >= 10,
                           String(decoding: data[property.payload..<(property.payload + 4)], as: UTF8.self) == "nclx" {
                            let transfer = try number(property.payload + 6, 2)
                            guard ![16, 18].contains(transfer) else { throw bad() }
                        }
                    }
                }
            }
            var kinds = [Int: Data]()
            let entriesOffset = iinf.payload + (try number(iinf.payload, 1) == 0 ? 6 : 8)
            for entry in try boxes(entriesOffset, iinf.end) {
                guard entry.type == "infe", entry.end - entry.payload >= 12 else { throw bad() }
                let version = try number(entry.payload, 1)
                guard version == 2 || version == 3 else { throw bad() }
                let idBytes = version == 2 ? 2 : 4
                let id = try number(entry.payload + 4, idBytes)
                let typeOffset = entry.payload + 6 + idBytes
                guard typeOffset + 4 <= entry.end, try number(entry.payload + 4 + idBytes, 2) == 0 else { throw bad() }
                let type = String(decoding: data[typeOffset..<(typeOffset + 4)], as: UTF8.self)
                guard ["hvc1", "grid", "Exif", "mime"].contains(type), kinds[id] == nil else { throw bad() }
                if ["Exif", "mime"].contains(type) { kinds[id] = data.subdata(in: typeOffset..<entry.end) }
            }
            var cursor = iloc.payload
            let version = try number(cursor, 1); cursor += 4
            guard version <= 2 else { throw bad() }
            let sizes = try number(cursor, 1), sizes2 = try number(cursor + 1, 1); cursor += 2
            let offsetBytes = sizes >> 4, lengthBytes = sizes & 15, baseBytes = sizes2 >> 4
            let indexBytes = version == 0 ? 0 : sizes2 & 15
            guard [0, 4, 8].contains(offsetBytes), [0, 4, 8].contains(lengthBytes),
                  [0, 4, 8].contains(baseBytes), [0, 4, 8].contains(indexBytes) else { throw bad() }
            let countBytes = version < 2 ? 2 : 4
            let count = try number(cursor, countBytes); cursor += countBytes
            guard count <= 4096 else { throw bad() }
            var metadataBytes = 0
            var metadataRanges = [Range<Int>]()
            for _ in 0..<count {
                let idBytes = version < 2 ? 2 : 4
                let id = try number(cursor, idBytes); cursor += idBytes
                var method = 0
                if version > 0 { method = try number(cursor, 2) & 15; cursor += 2 }
                let reference = try number(cursor, 2); cursor += 2
                let base = try number(cursor, baseBytes); cursor += baseBytes
                let extentCount = try number(cursor, 2); cursor += 2
                guard reference == 0, method <= 1, extentCount <= 4096 else { throw bad() }
                if kinds[id] != nil {
                    // Validate before reading/copying any extent. In particular a
                    // hostile table must not concatenate repeated 100 MB ranges.
                    guard method == 0, base == 0, extentCount == 1, offsetBytes > 0, lengthBytes > 0 else { throw bad() }
                }
                var payload = Data(), offsetField = 0, lengthField = 0
                for _ in 0..<extentCount {
                    cursor += indexBytes
                    offsetField = cursor
                    let offset = try number(cursor, offsetBytes); cursor += offsetBytes
                    lengthField = cursor
                    let length = try number(cursor, lengthBytes); cursor += lengthBytes
                    if kinds[id] != nil {
                        guard base <= data.count, offset <= data.count - base else { throw bad() }
                        var position = base + offset
                        if method == 1 {
                            guard let idat = children.first(where: { $0.type == "idat" }), position <= data.count - idat.payload else { throw bad() }
                            position += idat.payload
                        }
                        guard position <= data.count, length <= data.count - position else { throw bad() }
                        guard length <= 8 * 1_024 * 1_024 - metadataBytes else { throw bad() }
                        let range = position..<(position + length)
                        guard !metadataRanges.contains(where: { $0.overlaps(range) }) else { throw bad() }
                        metadataRanges.append(range); metadataBytes += length
                        payload.append(data.subdata(in: range))
                    }
                }
                guard cursor <= iloc.end else { throw bad() }
                if let key = kinds.removeValue(forKey: id) {
                    // Native encoder uses absolute, single extents with no base.
                    // Refuse other layouts rather than writing an ambiguous offset.
                    guard method == 0, base == 0, extentCount == 1, offsetBytes > 0, lengthBytes > 0 else { throw bad() }
                    metadata.append(MetadataItem(key: key, payload: payload, offsetField: offsetField,
                        offsetBytes: offsetBytes, lengthField: lengthField, lengthBytes: lengthBytes))
                }
            }
            guard kinds.isEmpty else { throw bad() }
            metadata.sort { $0.key.lexicographicallyPrecedes($1.key) }
        }
        private func boxes(_ start: Int, _ end: Int) throws -> [Box] {
            guard start >= 0, start <= end, end <= data.count else { throw bad() }
            var cursor = start, result = [Box]()
            while cursor < end {
                guard result.count < 4096, end - cursor >= 8 else { throw bad() }
                var size = try number(cursor, 4), header = 8
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                if size == 1 { size = try number(cursor + 8, 8); header = 16 }
                if size == 0 { size = end - cursor }
                guard size >= header, size <= end - cursor else { throw bad() }
                result.append(Box(type: type, payload: cursor + header, end: cursor + size)); cursor += size
            }
            return result
        }
        private func number(_ at: Int, _ bytes: Int) throws -> Int {
            guard at >= 0, at <= data.count, bytes <= data.count - at else { throw bad() }
            var value: UInt64 = 0
            for byte in data[at..<(at + bytes)] { value = (value << 8) | UInt64(byte) }
            guard value <= UInt64(Int.max) else { throw bad() }
            return Int(value)
        }
        static func write(_ value: Int, to data: inout Data, at: Int, bytes: Int) throws {
            guard value >= 0, [4, 8].contains(bytes), at >= 0, at + bytes <= data.count,
                  bytes == 8 || value <= Int(UInt32.max) else { throw ProcessingError.invalid("HEIC metadata offset") }
            for index in 0..<bytes { data[at + index] = UInt8(truncatingIfNeeded: UInt64(value) >> ((bytes - index - 1) * 8)) }
        }
        private func bad() -> ProcessingError {
            .unsupported(String(localized: "HEIC structure, auxiliary data, or precision is not supported. The original is preserved."))
        }
    }
}
