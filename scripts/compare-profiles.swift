// Local visual calibration tool. Uses the production processor, never publishes over inputs.
import Foundation
import AppKit
import ImageIO
import CryptoKit

@main
struct ProfileComparison {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Expected input directory, output directory, and fixture directory") }
        let inputs = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        if inputs == output.appendingPathComponent("inputs", isDirectory: true) {
            try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
            for name in ["photo-quality100.jpg", "lossy.webp", "exact-alpha.webp", "avif-auto.avif"] {
                let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
                try (name.hasSuffix("jpg") ? demoJPEG(data) : data).write(to: inputs.appendingPathComponent(name))
            }
            try makeArtwork(in: inputs)
            let photoURL = inputs.appendingPathComponent("photo-quality100.jpg")
            if let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                try webSamples(image, name: "foto-ijg", in: inputs)
            }
        }
        let urls = try fm.contentsOfDirectory(at: inputs, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { ["jpg", "jpeg", "png", "webp", "avif", "heic"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw ProcessingError.invalid("No supported static images in the input directory.") }
        var rows: [[String: Any]] = []
        for (index, url) in urls.enumerated() {
            try autoreleasepool {
                let folder = output.appendingPathComponent("sample-\(index)", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let original = try Data(contentsOf: url)
                let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
                let snapshot = folder.appendingPathComponent("original.\(url.pathExtension)")
                try original.write(to: snapshot)
                let processor = NativeImageProcessor()
                let info = try processor.inspect(snapshot)
                let dimensions = try preview(snapshot, to: folder.appendingPathComponent("original-preview.png"))
                var results: [[String: Any]] = []
                for profile in CompressionProfile.allCases {
                    try autoreleasepool {
                        let work = folder.appendingPathComponent(profile.rawValue, isDirectory: true)
                        try fm.createDirectory(at: work, withIntermediateDirectories: true)
                        let start = ContinuousClock.now
                        let candidate = try processor.optimize(source: snapshot, workDirectory: work,
                            settings: .init(fileSaveMode: .copyBesideOriginal, profile: profile), cancellation: CancellationToken())
                        let elapsed = start.duration(to: .now).components
                        let result = try candidate.map { try Data(contentsOf: $0) } ?? original
                        let saved = work.appendingPathComponent("result.\(url.pathExtension)")
                        try result.write(to: saved)
                        _ = try preview(saved, to: work.appendingPathComponent("preview.png"))
                        var row: [String: Any] = ["profile": profile.rawValue, "bytes": result.count,
                            "saved_percent": 100 * (1 - Double(result.count) / Double(original.count)),
                            "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                            "changed": candidate != nil,
                            "preview": "sample-\(index)/\(profile.rawValue)/preview.png",
                            "file": "sample-\(index)/\(profile.rawValue)/result.\(url.pathExtension)"]
                        if info.format == .jpeg || info.format == .webp {
                            var scores = [Float](repeating: 0, count: 5)
                            original.withUnsafeBytes { a in result.withUnsafeBytes { b in
                                if info.format == .jpeg { _ = rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count, b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores) }
                                else { _ = rc_webp_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count, b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores) }
                            }}
                            row["rgb_ssim_db"] = scores.prefix(3).map { $0.isFinite ? Double($0) : -1 }
                        }
                        results.append(row)
                        print("\(url.lastPathComponent) / \(profile.rawValue): \(original.count) → \(result.count)")
                    }
                }
                guard try Data(contentsOf: url) == original else { throw ProcessingError.changedSource }
                rows.append(["name": url.lastPathComponent, "format": info.format.rawValue,
                    "width": dimensions.0, "height": dimensions.1, "bytes": original.count, "sha256": hash,
                    "preview": "sample-\(index)/original-preview.png", "file": "sample-\(index)/original.\(url.pathExtension)", "results": results])
            }
        }
        let report: [String: Any] = ["samples": rows, "method": "Production NativeImageProcessor, sequential optimized build. Every candidate starts from the same source snapshot. Full-resolution PNG previews decoded by Image I/O with orientation applied. File sizes refer to encoded originals/results, not previews. Thresholds are preliminary; visual approval is still needed."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }

    static func preview(_ input: URL, to output: URL) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 40_000
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw ProcessingError.invalid("Could not create a comparison preview.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.invalid("Could not save preview.") }
        return (image.width, image.height)
    }

    // Only for authored/default fixtures. Image I/O writes a Photoshop APP13
    // resource that intentionally disables recompression in production. Remove
    // it in the demo source without touching coefficients or any user inputs.
    static func demoJPEG(_ data: Data) -> Data {
        var result = Data(data.prefix(2)), offset = 2
        while offset + 4 <= data.count && data[offset] == 255 {
            let marker = data[offset + 1]
            if marker == 218 || marker == 217 { break }
            let length = Int(data[offset + 2]) * 256 + Int(data[offset + 3])
            guard length >= 2, offset + 2 + length <= data.count else { return data }
            let end = offset + 2 + length
            if marker != 237 { result.append(data[offset..<end]) }
            offset = end
        }
        result.append(data[offset...])
        return result
    }

    static func webSamples(_ image: CGImage, name: String, in folder: URL) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data else { throw ProcessingError.invalid("Could not generate demo pixels.") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let raw = folder.appendingPathComponent(name + ".rgba")
        try Data(bytes: bytes, count: image.width * image.height * 4).write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let process = Process()
        process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("encode-rgba")
        process.arguments = [raw.path, String(image.width), String(image.height), folder.appendingPathComponent(name).path, "1"]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProcessingError.invalid("Could not generate WebP and AVIF demo files.") }
    }

    static func makeArtwork(in folder: URL) throws {
        let width = 1200, height = 800
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Context") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.5, alpha: 1).cgColor,
                     NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.3, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        context.saveGState(); context.clip(to: CGRect(x: 40, y: 420, width: 1120, height: 330))
        context.drawLinearGradient(gradient, start: CGPoint(x: 40, y: 420), end: CGPoint(x: 1160, y: 750), options: [])
        context.restoreGState()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, size) in [14.0, 18.0, 24.0, 36.0].enumerated() {
            let text = "Resim · Detalle y compresión / Aa Bb 0123456789"
            (text as NSString).draw(at: CGPoint(x: 40, y: 350 - index * 70), withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.4, alpha: 1)])
        }
        NSGraphicsContext.restoreGraphicsState()
        for x in stride(from: 780, to: 1160, by: 4) {
            context.setFillColor(NSColor(calibratedRed: 0.8, green: 0.15, blue: 0.3, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: 70, width: 1, height: 260))
        }
        guard let image = context.makeImage() else { fatalError("Image") }
        try webSamples(image, name: "texto-lineas-degradado", in: folder)
        for (ext, type) in [("png", "public.png"), ("jpg", "public.jpeg"), ("heic", "public.heic")] {
            let url = folder.appendingPathComponent("texto-lineas-degradado.\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { fatalError("Encoder") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ProcessingError.invalid("Could not encode comparison artwork.") }
            if ext == "jpg" { try demoJPEG(Data(contentsOf: url)).write(to: url) }
        }
    }
}
