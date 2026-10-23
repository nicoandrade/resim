// Benchmark the production processor without changing any input files.
import Foundation
import CryptoKit

@main
struct ImageOptimComparison {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Expected inputs, output, repetitions") }
        let inputs = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let repetitions = Int(args[3])!
        let fm = FileManager.default
        let sources = try fm.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg", "gif", "svg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rows: [[String: Any]] = []
        for source in sources {
            let original = try Data(contentsOf: source)
            let cases: [(String, OptimizationSettings)] = [
                ("resim-lossless", .init(mode: .lossless)),
                ("resim-conservative", .init(profile: .conservative)),
                ("resim-web", .init(profile: .web)),
                ("resim-maximum", .init(profile: .maximum))
            ]
            for (label, settings) in cases {
                try autoreleasepool {
                    let folder = output.appendingPathComponent(label).appendingPathComponent(source.lastPathComponent + ".work")
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = output.appendingPathComponent(label).appendingPathComponent(source.lastPathComponent)
                    var timings: [Double] = [], hashes: [String] = []
                    var row: [String: Any] = ["name": source.lastPathComponent, "case": label]
                    do {
                        for _ in 0..<repetitions {
                            let start = ContinuousClock.now
                            let candidate = try NativeImageProcessor().optimize(source: source, workDirectory: folder,
                                settings: settings, cancellation: CancellationToken())
                            let elapsed = start.duration(to: .now).components
                            timings.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                            let data = try candidate.map { try Data(contentsOf: $0) } ?? original
                            hashes.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                            try data.write(to: destination)
                            row["bytes"] = data.count
                        }
                        row["samples_ms"] = timings
                        row["deterministic"] = Set(hashes).count == 1
                        row["file"] = label + "/" + source.lastPathComponent
                        row["sha256"] = hashes[0]
                    } catch {
                        row["error"] = String(describing: error)
                    }
                    rows.append(row)
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent("resim-results.json"), options: .atomic)
                    print("\(source.lastPathComponent) / \(label): \(row["bytes"] ?? row["error"] ?? "?")")
                    fflush(stdout)
                }
            }
            guard try Data(contentsOf: source) == original else { throw ProcessingError.changedSource }
        }
    }
}
