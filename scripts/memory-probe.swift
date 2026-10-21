import Foundation
import Darwin
import CryptoKit

// Headless measurement of the production queue/codecs. This excludes SwiftUI and
// XCTest. The runner samples this process and helpers, with fixed existing inputs.
private actor ProbeState {
    var jobs: [UUID: ImageJob] = [:]
    func receive(_ event: QueueEvent) {
        switch event {
        case .updated(let job): jobs[job.id] = job
        case .removed(let id): jobs.removeValue(forKey: id)
        }
    }
    func snapshot() -> [ImageJob] { Array(jobs.values) }
}

@main
struct MemoryProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let mode = OptimizationMode(rawValue: args[3]) else {
            throw NSError(domain: "Usage: MemoryProbe input-directory new-output-directory automatic|lossless all|extension", code: 1)
        }
        let input = URL(fileURLWithPath: args[1], isDirectory: true)
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        // The runner must use a new disposable directory; never overwrite old evidence.
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "Output directory already exists", code: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let extensions = Set(["png", "jpg", "webp", "heic", "avif", "gif", "svg"])
        let formatOrder = ["svg", "gif", "avif", "heic", "webp", "jpg", "png"]
        let urls = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension) && (args[4] == "all" || $0.pathExtension == args[4]) }
            .sorted {
                if $0.deletingPathExtension().lastPathComponent == $1.deletingPathExtension().lastPathComponent {
                    return formatOrder.firstIndex(of: $0.pathExtension)! < formatOrder.firstIndex(of: $1.pathExtension)!
                }
                return $0.lastPathComponent > $1.lastPathComponent
            }
        guard !urls.isEmpty else { throw NSError(domain: "No inputs", code: 1) }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Local Resim memory comparison")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let hashes = try urls.map { try SafeFiles.contentSignature($0).digest }
        let state = ProbeState()
        let queue = QueueCoordinator(processor: NativeImageProcessor()) { await state.receive($0) }
        let started = ContinuousClock.now
        let admission = Task { await queue.addURLs(urls, settings: .init(mode: mode, destination: output, fileSaveMode: .copyToFolder)) }
        let events = output.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let log = try FileHandle(forWritingTo: events)
        var previous: [UUID: JobState] = [:]
        var jobs: [ImageJob] = []
        while true {
            jobs = await state.snapshot()
            for job in jobs where previous[job.id] != job.state {
                let row: [String: Any] = ["elapsed_s": seconds(started.duration(to: .now)), "file": job.filename, "state": job.state.rawValue]
                try log.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
                previous[job.id] = job.state
            }
            if jobs.count == urls.count && jobs.allSatisfy({ $0.state.isFinished }) { break }
            if started.duration(to: .now) > .seconds(1200) { await queue.cancelAll(); throw NSError(domain: "Probe timed out", code: 1) }
            try await Task.sleep(for: .milliseconds(25))
        }
        await admission.value
        try log.close()
        let elapsed = seconds(started.duration(to: .now))
        let unchanged = try urls.map { try SafeFiles.contentSignature($0).digest } == hashes
        let rows: [[String: Any]] = try jobs.sorted { $0.filename < $1.filename }.map { job in
            var row: [String: Any] = ["file": job.filename, "state": job.state.rawValue, "original_bytes": job.originalBytes ?? 0]
            if let url = job.resultURL {
                row["result_bytes"] = job.resultBytes
                row["sha256"] = try SafeFiles.contentSignature(url).digest.map { String(format: "%02x", $0) }.joined()
            }
            if let message = job.message { row["message"] = message }
            return row
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["method": "Headless production queue and codecs; no SwiftUI or XCTest. Existing corpus, native picker order. App Nap disabled for the measurement without preventing system sleep. RSS externally sampled with descendants; own physical footprint queried from TASK_VM_INFO.", "mode": mode.rawValue, "filter": args[4], "total": urls.count, "elapsed_s": elapsed, "source_hashes_unchanged": unchanged, "peak_process_rss_bytes": usage.ru_maxrss, "physical_footprint": footprint(), "rows": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        guard unchanged, jobs.allSatisfy({ $0.state == .optimized || $0.state == .unchanged }) else { throw NSError(domain: "Probe result failed", code: 1) }
        // Give the external monitor time to record post-batch allocator/cache retention.
        try await Task.sleep(for: .seconds(5))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func footprint() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return ["available": false] }
        return ["available": true, "current_bytes": info.phys_footprint,
                "lifetime_peak_bytes": max(0, info.ledger_phys_footprint_peak),
                "method": "Own-process TASK_VM_INFO; lifetime peak includes startup and hash verification, excludes helper processes."]
    }
}
