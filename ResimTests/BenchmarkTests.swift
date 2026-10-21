import XCTest
import AppKit
import Darwin
@testable import Resim

final class BenchmarkTests: XCTestCase {
    func testReleaseCorpusBenchmark() throws {
        guard ProcessInfo.processInfo.environment["RESIM_RUN_BENCHMARK"] == "1" ||
              FileManager.default.fileExists(atPath: repository.appendingPathComponent(".build/run-benchmark").path) else {
            throw XCTSkip("Run scripts/benchmark.sh to benchmark the corpus in Release")
        }
        let processor = NativeImageProcessor()
        var rows: [[String: Any]] = []
        let corpus = ["landscape.png", "rgba.png", "rgb16.png", "palette.png", "fine-lines.png", "landscape.jpg", "photo-ijg.jpg", "photo-quality100.jpg", "smooth-auto.jpg", "accepted-auto.jpg", "icc-444.jpg", "grayscale.jpg", "progressive.jpg", "orientation-gps.jpg", "already-compressed.jpg", "exact-alpha.webp", "lossy.webp"]
        let idleRSS = residentMemory()
        for name in corpus {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let original = try Data(contentsOf: source)
            for mode in OptimizationMode.allCases {
                var milliseconds: [Double] = []
                var resultBytes = original.count
                var finalCandidate: Data?
                for _ in 0..<5 {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("resim-benchmark-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let start = ContinuousClock.now
                    let output = try processor.optimize(source: source, workDirectory: temporary, settings: .init(mode: mode), cancellation: CancellationToken())
                    let elapsed = start.duration(to: .now).components
                    milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                    finalCandidate = try output.map { try Data(contentsOf: $0) }
                    resultBytes = finalCandidate?.count ?? original.count
                }
                milliseconds.sort()
                var quality: [String: Any] = [:]
                if let candidate = finalCandidate, name.hasSuffix("jpg") || name.hasSuffix("webp") {
                    var scores = [Float](repeating: 0, count: 5)
                    let pass = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                        if name.hasSuffix("jpg") {
                            return rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                                    b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
                        }
                        return rc_webp_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                                b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
                    }}
                    quality["ssim_db_bgra_all"] = scores.map { $0.isFinite ? Double($0) : -1 }
                    quality["passes_rgb_gate"] = mode == .lossless ? pass == 1 : scores.prefix(3).allSatisfy { $0.isFinite && $0 >= rc_profile_min_ssim_db(2) }
                    quality["profile"] = mode == .lossless ? "lossless" : "web"
                    if name.hasSuffix("jpg") {
                        quality["identical_dct"] = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                            rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count, b.bindMemory(to: UInt8.self).baseAddress, b.count) == 1
                        }}
                    }
                }
                rows.append(["quality":quality, "fixture":name, "mode":mode.rawValue, "samples_ms":milliseconds,
                             "median_ms":milliseconds[2], "p95_ms":milliseconds[4],
                             "original_bytes":original.count, "result_bytes":resultBytes,
                             "saved_bytes":original.count-resultBytes])
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = utsname(); uname(&info)
        let hardware = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let report: [String: Any] = ["date":ISO8601DateFormatter().string(from: Date()),
            "os":ProcessInfo.processInfo.operatingSystemVersionString, "architecture":hardware,
            "processor_count":ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes":ProcessInfo.processInfo.physicalMemory,
            "configuration":"Release (script enforces)", "method":"Hosted XCTest; sequential, five full-resolution iterations per fixture/mode; p95 nearest rank. Original procedural corpus plus redistributable IJG photograph (see Fixtures/README.md). RSS includes app/test host.",
            "idle_host_rss_bytes":idleRSS, "peak_host_rss_bytes":usage.ru_maxrss, "rows":rows]
        let path = repository.appendingPathComponent(".build/benchmark.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: path)
        print("BENCHMARK_REPORT \(path.path)")
    }
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
