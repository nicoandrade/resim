// One real NativeImageProcessor operation. Parent alternates old/new executables.
import Foundation
import CryptoKit
import ImageIO

@main
struct JPEGMaximumBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Expected source, work directory, profile") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = URL(fileURLWithPath: CommandLine.arguments[2])
        let key = CommandLine.arguments[3]
        let settings: OptimizationSettings
        switch key {
        case "lossless": settings = .init(mode: .lossless)
        case "conservative": settings = .init(profile: .conservative)
        case "web": settings = .init(profile: .web)
        default: settings = .init(profile: .maximum)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let original = try Data(contentsOf: source)
        let processor = NativeImageProcessor()
        let start = ContinuousClock.now
        let candidate = try processor.optimize(source: source, workDirectory: work,
            settings: settings, cancellation: CancellationToken())
        let elapsed = start.duration(to: .now).components
        let result = try candidate.map { try Data(contentsOf: $0) } ?? original
        let resultURL = work.appendingPathComponent("result.jpg")
        try result.write(to: resultURL)
        let before = try processor.inspect(source), after = try processor.inspect(resultURL)
        var scores = [Float](repeating: 0, count: 5)
        let identical = original.withUnsafeBytes { a in result.withUnsafeBytes { b in
            _ = rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                 b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
            return rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                              b.bindMemory(to: UInt8.self).baseAddress, b.count) == 1
        }}
        let left = CGImageSourceCreateWithData(original as CFData, nil)!
        let right = CGImageSourceCreateWithData(result as CFData, nil)!
        let orientation: (CGImageSource) -> Int = {
            let properties = CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyOrientation] as? Int ?? 1
        }
        let profile: (CGImageSource) -> Data? = {
            CGImageSourceCreateImageAtIndex($0, 0, nil)?.colorSpace?.copyICCData() as Data?
        }
        let row: [String: Any] = [
            "name": source.lastPathComponent, "profile": key,
            "milliseconds": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
            "bytes": result.count, "original_bytes": original.count,
            "sha256": SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined(),
            "min_rgb_ssim_db": scores.prefix(3).min()!, "identical_dct": identical,
            "dimensions_equal": before.width == after.width && before.height == after.height,
            "format_equal": before.format == after.format,
            "icc_equal": profile(left) == profile(right),
            "orientation_equal": orientation(left) == orientation(right),
            "source_unchanged": try Data(contentsOf: source) == original
        ]
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            .write(to: work.appendingPathComponent("measurement.json"), options: .atomic)
    }
}
