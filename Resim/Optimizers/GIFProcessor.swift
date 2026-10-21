import Foundation

/// Lossless animation optimization. Gifsicle owns decoding/compositing; the
/// bounded container reader admits inputs before either native helper runs.
nonisolated struct GIFProcessor {
    private let maximumBytes = 100 * 1_024 * 1_024
    private let maximumMemory: UInt64 = 512 * 1_024 * 1_024

    func inspect(_ data: Data) throws -> ImageInfo {
        let gif = try Container(data)
        return ImageInfo(format: .gif, width: gif.width, height: gif.height,
                         hasAlpha: gif.hasAlpha, estimatedMemory: gif.estimatedMemory)
    }

    func optimize(_ original: Data, source: URL, workDirectory: URL,
                  settings: OptimizationSettings, cancellation: CancellationToken) throws -> URL? {
        try cancellation.check()
        let gif = try Container(original)
        guard gif.estimatedMemory <= maximumMemory else { throw memoryLimit() }
        let optimizer = try helper("gifsicle"), comparator = try helper("gifdiff")
        // Read exactly the same immutable bytes used by admission and metadata
        // validation, independently of the original file's name or location.
        let reference = workDirectory.appendingPathComponent("reference.gif")
        try original.write(to: reference, options: .atomic)
        var input = reference
        if settings.stripPersonalMetadata {
            input = workDirectory.appendingPathComponent("metadata-clean.gif")
            var cleaned = original
            for item in gif.metadata.reversed() where item.isPersonal {
                cleaned.removeSubrange(item.range)
            }
            try cleaned.write(to: input, options: .atomic)
        }
        let output = workDirectory.appendingPathComponent("candidate.gif")
        // Both modes remain lossless: no quantization, lossy LZW or frame dropping.
        let optimizerLog = workDirectory.appendingPathComponent("gifsicle.log")
        let status = try run(optimizer, arguments: ["--optimize=2", "--optimize=keep-empty",
            "--no-ignore-errors", "--conserve-memory", "--max-screen=\(gif.width)x\(gif.height)",
            "--output", output.path, "--", input.path],
            log: optimizerLog, cancellation: cancellation)
        // Some malformed LZW streams produce warnings with a successful exit.
        // Do not report those originals as valid images with no size reduction.
        let optimizerLogSize = (try FileManager.default.attributesOfItem(atPath: optimizerLog.path)[.size] as? NSNumber)?.uint64Value
        guard status == 0, optimizerLogSize == 0 else {
            throw ProcessingError.invalid(String(localized: "The GIF is damaged or the optimizer could not validate it."))
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
              let count = (attributes[.size] as? NSNumber)?.uint64Value,
              count > 0, count < original.count, count <= maximumBytes else { return nil }
        let candidate = try Data(contentsOf: output, options: .mappedIfSafe)
        guard metadataAndTimingPreserved(original: original, candidate: candidate,
                                         stripping: settings.stripPersonalMetadata) else { return nil }
        let diffLog = workDirectory.appendingPathComponent("gifdiff.log")
        let equivalent = try run(comparator, arguments: ["--brief", "--", reference.path, output.path],
                                 log: diffLog, cancellation: cancellation)
        // gifdiff can diagnose malformed LZW without failing its exit status.
        // A valid, identical pair with --brief produces no output at all.
        let logSize = (try FileManager.default.attributesOfItem(atPath: diffLog.path)[.size] as? NSNumber)?.uint64Value
        guard equivalent == 0, logSize == 0 else { return nil }
        try cancellation.check()
        return output
    }

    /// Structural invariants complement gifdiff's rendered-pixel comparison.
    /// Delta rectangles/disposal may change; individual delays and metadata may not.
    func metadataAndTimingPreserved(original: Data, candidate: Data, stripping: Bool) -> Bool {
        guard let a = try? Container(original), let b = try? Container(candidate),
              b.estimatedMemory <= maximumMemory,
              a.width == b.width, a.height == b.height, a.aspect == b.aspect,
              a.background == b.background, a.delays == b.delays, a.loopCount == b.loopCount else { return false }
        let expected = a.metadata.filter { !(stripping && $0.isPersonal) }
        return expected.count == b.metadata.count && zip(expected, b.metadata).allSatisfy {
            $0.label == $1.label && $0.frame == $1.frame && $0.payload == $1.payload
        }
    }

    private func helper(_ name: String) throws -> URL {
        let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Codecs")
            ?? Bundle.main.url(forResource: name, withExtension: nil)
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ProcessingError.unavailable(String(localized: "A GIF tool bundled with the app is missing."))
        }
        return url
    }

    private func run(_ executable: URL, arguments: [String], log: URL,
                     cancellation: CancellationToken) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        try cancellation.check()
        try process.run()
        while process.isRunning {
            if cancellation.isCancelled {
                process.terminate(); process.waitUntilExit(); try cancellation.check()
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        try cancellation.check()
        return process.terminationReason == .exit ? process.terminationStatus : -1
    }

    private func memoryLimit() -> ProcessingError {
        .resourceLimit(String(localized: "The image needs more than 512 MB to process safely."))
    }

    private struct Metadata {
        let label: UInt8
        let frame: Int
        let payload: Data
        let range: Range<Int>
        var isPersonal: Bool { label == 0xFE || label == 0xCE }
    }

    /// GIF framing only, never an LZW decoder. Every read is range checked;
    /// bounded dimensions/frame storage are known before native decompression.
    private struct Container {
        let width: Int
        let height: Int
        let aspect: UInt8
        let background: Data?
        var delays: [Int] = []
        var metadata: [Metadata] = []
        var loopCount: Int?
        var hasAlpha = false
        var estimatedMemory: UInt64 = 0

        init(_ data: Data) throws {
            guard data.count <= 100 * 1_024 * 1_024 else { throw Self.limit() }
            var reader = Reader(data: data)
            let signature = try reader.take(6)
            guard signature == Data("GIF87a".utf8) || signature == Data("GIF89a".utf8) else { throw Self.bad() }
            width = try reader.word(); height = try reader.word()
            guard width > 0, height > 0, width <= 40_000_000 / height else { throw Self.limit() }
            let packed = try reader.byte(), backgroundIndex = Int(try reader.byte())
            aspect = try reader.byte()
            let globalCount = packed & 0x80 == 0 ? 0 : 1 << (Int(packed & 7) + 1)
            let palette = try reader.take(globalCount * 3)
            if globalCount > 0 {
                guard backgroundIndex < globalCount else { throw Self.bad() }
                background = palette.subdata(in: (backgroundIndex * 3)..<(backgroundIndex * 3 + 3))
            } else { background = nil }
            var pendingDelay: Int?, pendingTransparent: Int?
            var framePixels: UInt64 = 0, metadataBytes = 0, blocks = 0
            while true {
                blocks += 1
                guard blocks <= 100_000 else { throw Self.limit() }
                let start = reader.cursor, marker = try reader.byte()
                if marker == 0x3B {
                    guard reader.cursor == data.count, !delays.isEmpty, pendingDelay == nil else { throw Self.bad() }
                    estimatedMemory = framePixels * 4 + UInt64(width * height) * 32
                        + UInt64(data.count) * 4 + 16 * 1_024 * 1_024
                    return
                }
                if marker == 0x2C {
                    guard delays.count < 1_000 else { throw Self.limit() }
                    let left = try reader.word(), top = try reader.word()
                    let frameWidth = try reader.word(), frameHeight = try reader.word()
                    guard frameWidth > 0, frameHeight > 0, left <= width, top <= height,
                          frameWidth <= width - left, frameHeight <= height - top else { throw Self.bad() }
                    framePixels += UInt64(frameWidth) * UInt64(frameHeight)
                    guard framePixels <= 40_000_000 else { throw Self.limit() }
                    let descriptor = try reader.byte()
                    guard descriptor & 0x18 == 0 else { throw Self.bad() }
                    let localCount = descriptor & 0x80 == 0 ? 0 : 1 << (Int(descriptor & 7) + 1)
                    _ = try reader.take(localCount * 3)
                    let activeCount = localCount > 0 ? localCount : globalCount
                    guard activeCount > 0 else { throw Self.bad() }
                    if let transparent = pendingTransparent {
                        guard transparent < activeCount else { throw Self.bad() }
                        hasAlpha = true
                    }
                    let minimumCodeSize = try reader.byte()
                    guard (2...8).contains(minimumCodeSize) else { throw Self.bad() }
                    let imageDataStart = reader.cursor
                    try reader.skipSubblocks()
                    guard reader.cursor > imageDataStart + 1 else { throw Self.bad() }
                    delays.append(pendingDelay ?? 0); pendingDelay = nil; pendingTransparent = nil
                } else if marker == 0x21 {
                    let label = try reader.byte()
                    if label == 0xF9 {
                        guard pendingDelay == nil, try reader.byte() == 4 else { throw Self.bad() }
                        let control = try reader.byte()
                        // Reserved flags/disposals and user-input animations have
                        // semantics that an automatic optimizer cannot reproduce.
                        guard control & 0xE2 == 0, (control >> 2) & 7 <= 3 else { throw Self.unsupported() }
                        pendingDelay = try reader.word()
                        let transparent = Int(try reader.byte())
                        pendingTransparent = control & 1 == 0 ? nil : transparent
                        guard try reader.byte() == 0 else { throw Self.bad() }
                    } else {
                        guard label != 0x01 else { throw Self.unsupported() }
                        let payloadStart = reader.cursor
                        try reader.skipSubblocks()
                        let range = start..<reader.cursor
                        metadataBytes += range.count
                        guard metadataBytes <= 8 * 1_024 * 1_024 else { throw Self.limit() }
                        var payload = data.subdata(in: payloadStart..<reader.cursor)
                        if label == 0xFF {
                            guard payload.count >= 13, payload[0] == 11 else { throw Self.bad() }
                            let identifier = payload.subdata(in: 1..<12)
                            if identifier == Data("NETSCAPE2.0".utf8) || identifier == Data("ANIMEXTS1.0".utf8) {
                                guard loopCount == nil, delays.isEmpty, payload.count == 17,
                                      payload[12] == 3, payload[13] == 1, payload[16] == 0 else { throw Self.bad() }
                                loopCount = Int(payload[14]) | Int(payload[15]) << 8
                                continue
                            }
                        } else if label == 0xFE || label == 0xCE {
                            // Comments/names can be re-chunked without changing
                            // text. Unknown extensions retain exact subblocks.
                            var text = Data(), position = payloadStart
                            while data[position] != 0 {
                                let length = Int(data[position]); position += 1
                                text.append(data[position..<(position + length)]); position += length
                            }
                            payload = text
                        }
                        metadata.append(Metadata(label: label, frame: delays.count, payload: payload, range: range))
                    }
                } else { throw Self.bad() }
            }
        }

        private static func bad() -> ProcessingError {
            .invalid(String(localized: "The GIF is damaged or incomplete."))
        }
        private static func limit() -> ProcessingError {
            .resourceLimit(String(localized: "The GIF exceeds the limit of 100 MB, 1,000 frames, or 40 million total frame pixels."))
        }
        private static func unsupported() -> ProcessingError {
            .unsupported(String(localized: "This GIF contains plain text, user controls, or unsupported graphic extensions. The original is preserved."))
        }

        private struct Reader {
            let data: Data
            var cursor = 0
            mutating func byte() throws -> UInt8 {
                guard cursor < data.count else { throw Container.bad() }
                defer { cursor += 1 }
                return data[cursor]
            }
            mutating func word() throws -> Int {
                let low = try byte(), high = try byte()
                return Int(low) | Int(high) << 8
            }
            mutating func take(_ count: Int) throws -> Data {
                guard count >= 0, cursor <= data.count, count <= data.count - cursor else { throw Container.bad() }
                defer { cursor += count }
                return data.subdata(in: cursor..<(cursor + count))
            }
            mutating func skipSubblocks() throws {
                while true {
                    let count = Int(try byte())
                    if count == 0 { return }
                    guard count <= data.count - cursor else { throw Container.bad() }
                    cursor += count
                }
            }
        }
    }
}
