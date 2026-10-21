import XCTest
import AppKit
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin
@testable import Resim

/// Deliberately opt-in: hundreds of full-resolution codec operations belong in
/// Release QA, rather than in the ordinary correctness suite.
final class ReleaseQATests: XCTestCase {
    private struct Sample: Sendable {
        let url: URL
        let info: ImageInfo
        let bytes: Int
        let sha256: String
        let content: String
        var json: [String: Any] {
            ["file": url.lastPathComponent, "format": info.format.rawValue, "width": info.width,
             "height": info.height, "bytes": bytes, "sha256": sha256, "content": content,
             "estimated_memory_bytes": info.estimatedMemory]
        }
    }

    private final class TimedProcessor: ImageProcessing, @unchecked Sendable {
        private let native = NativeImageProcessor()
        private let lock = NSLock()
        private var records: [[String: Any]] = []
        func inspect(_ source: URL) throws -> ImageInfo { try native.inspect(source) }
        func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                      cancellation: CancellationToken) throws -> URL? {
            let began = ContinuousClock.now
            var outcome = "error"
            defer {
                let elapsed = ReleaseQATests.milliseconds(began.duration(to: .now))
                let record: [String: Any] = ["format": source.pathExtension.lowercased(),
                    "mode": settings.mode.rawValue, "elapsed_ms": elapsed, "outcome": outcome]
                lock.withLock { records.append(record) }
            }
            do {
                let output = try native.optimize(source: source, workDirectory: workDirectory,
                    settings: settings, cancellation: cancellation)
                outcome = output == nil ? "unchanged" : "optimized"
                return output
            } catch {
                outcome = error is CancellationError ? "cancelled" : "error"
                throw error
            }
        }
        func snapshot() -> [[String: Any]] { lock.withLock { records } }
    }

    @MainActor
    func testSevenFormatsAndLargeBatchesInRelease() async throws {
        let repository = Self.repository
        guard Bundle.main.bundleIdentifier == "com.resim.qa.releasehost",
              FileManager.default.fileExists(atPath: repository.appendingPathComponent(".build/run-release-qa").path) else {
            throw XCTSkip("Run scripts/qa-release.sh for seven-format Release and large-batch QA")
        }
        #if DEBUG
        XCTFail("Release QA must be compiled with the Release configuration")
        return
        #else
        let started = ContinuousClock.now
        let idleRSS = Self.residentMemory()
        var report: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()), "configuration": "Release",
            "host_bundle_identifier": Bundle.main.bundleIdentifier ?? "unknown",
            "host_isolated_from_distributed_app": true,
            "host_derived_data_directory": ".build/xcode-release-qa",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "status": "in_progress", "idle_host_rss_bytes": idleRSS,
            "method": "Real AppModel and QueueCoordinator with a timing-only NativeImageProcessor wrapper. Hosted XCTest on the current Mac. Host RSS includes the app, tests, fixture generation, independent output verification and allocator retention; child helpers are excluded. It is not standalone app RSS. Polling and MainActor heartbeat use 10 ms intervals. Codec timings exclude admission, snapshot and publication; batch timings include them, but exclude post-completion verification. JPEG lossless uses exact DCT coefficients. Other outputs are decoded independently with Apple Image I/O (SVG with AppKit); exact canonical RGBA for lossless, PNG and GIF, or Web 20 dB per-RGB SSIM for actual automatic raster recompression.",
            "jpeg_decoder_note": "Apple Image I/O can round baseline and progressive JPEG IDCT differently despite identical coefficients (observed max 4/255 on the local corpus). DCT-exact JPEG outputs are reported as such, without claiming identical Apple-rendered RGBA. Actual JPEG recompression must still pass both native and independently decoded per-RGB SSIM gates.",
            "scope": "20 inputs per format, 140 per mode, seven formats, both modes. Raster dimensions vary from 1600x1200 to 3000x2000. Original patterns plus a redistributable IJG photograph and, when provided locally, an external photograph. IJG resizing exercises decoded dimensions, not additional photographic detail. GIF has three independently generated frames with 70/130/250 ms delays and infinite loop. SVG has 800 shapes, references, styles, metadata, title and text. No artificial padding is added to the large corpus.",
            "fixture_generation_in_performance_measurements": false
        ]
        var batches: [[String: Any]] = []
        defer {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            report["peak_host_rss_bytes"] = usage.ru_maxrss
            report["final_host_rss_bytes"] = Self.residentMemory()
            report["elapsed_ms"] = Self.milliseconds(started.duration(to: .now))
            report["batches"] = batches
            if report["status"] as? String == "in_progress" { report["status"] = "incomplete" }
            try? Self.write(report)
        }
        let generationStart = ContinuousClock.now
        let samples = try makeCorpus()
        XCTAssertEqual(samples.count, 140)
        XCTAssertEqual(Set(samples.map { $0.info.format.rawValue }).count, 7)
        for format in ["png", "jpeg", "webp", "heic", "avif", "gif", "svg"] {
            XCTAssertEqual(samples.filter { $0.info.format.rawValue == format }.count, 20, format)
        }
        report["corpus_generation_ms"] = Self.milliseconds(generationStart.duration(to: .now))
        report["corpus"] = samples.map(\.json)
        report["after_fixture_generation_host_rss_bytes"] = Self.residentMemory()
        try Self.write(report)
        for mode in OptimizationMode.allCases {
            let batch = try await runBatch(samples, name: "large_140_\(mode.rawValue)", mode: mode)
            batches.append(batch)
            report["batches"] = batches
            try Self.write(report)
        }
        batches.append(try await runBatch(samples, name: "cancel_and_recover", mode: .automatic, cancel: true))
        for mode in OptimizationMode.allCases {
            batches.append(try await runBatch(Array(samples.prefix(7)), name: "strip_metadata_policy_\(mode.rawValue)", mode: mode, strip: true))
        }
        let originalsUnchanged = try samples.map { try Self.hash($0.url) } == samples.map(\.sha256)
        XCTAssertTrue(originalsUnchanged, "Every original must stay byte-identical across all scenarios")
        report["original_hashes_unchanged"] = originalsUnchanged
        report["status"] = (testRun?.failureCount ?? 0) == 0 ? "passed" : "failed"
        print("RELEASE_QA_REPORT \(repository.appendingPathComponent(".build/release-qa.json").path)")
        #endif
    }

    @MainActor
    private func runBatch(_ samples: [Sample], name: String, mode: OptimizationMode,
                          cancel: Bool = false, strip: Bool = false) async throws -> [String: Any] {
        let directory = Self.repository.appendingPathComponent(".build/release-qa-results/\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preexistingWork = Self.currentProcessWorkDirectories()
        let processor = TimedProcessor()
        let defaultsName = "resim-release-qa-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(processor: processor, defaults: defaults)
        model.settings = .init(mode: mode, destination: directory, stripPersonalMetadata: strip)
        // Reserve every first-choice filename, not just one easy PNG case.
        var sentinels: [URL: Data] = [:]
        for sample in samples {
            let url = directory.appendingPathComponent(sample.url.deletingPathExtension().lastPathComponent + "-optimized." + sample.url.pathExtension)
            if sentinels[url] == nil {
                let bytes = Data("Pre-existing file must not be replaced: \(url.lastPathComponent)".utf8)
                try bytes.write(to: url)
                sentinels[url] = bytes
            }
        }
        let began = ContinuousClock.now
        let firstCount = min(14, samples.count)
        model.addURLs(Array(samples.prefix(firstCount)).map(\.url))
        var firstRowsMS: Double?, allRowsMS: Double?, addWhileRunning = false, cancelRequested: ContinuousClock.Instant?
        var heartbeatGaps: [Double] = [], rss: [UInt64] = [], maxRunning = 0, maxReserved: UInt64 = 0
        var lastBeat = ContinuousClock.now
        var admittedRemainder = firstCount == samples.count
        var firstResultMS: Double?
        while model.hasActiveJobs || !admittedRemainder {
            let now = ContinuousClock.now
            heartbeatGaps.append(Self.milliseconds(lastBeat.duration(to: now))); lastBeat = now
            rss.append(Self.residentMemory())
            let running = model.jobs.filter { $0.state == .running }
            maxRunning = max(maxRunning, running.count)
            let reservation = running.reduce(UInt64(0)) { count, job in
                count + (samples.first { $0.url == job.sourceURL }?.info.estimatedMemory ?? 0)
            }
            maxReserved = max(maxReserved, reservation)
            let elapsed = Self.milliseconds(began.duration(to: now))
            if firstRowsMS == nil, model.jobs.count >= firstCount { firstRowsMS = elapsed }
            if !admittedRemainder, !running.isEmpty {
                addWhileRunning = true
                model.addURLs(Array(samples.dropFirst(firstCount)).map(\.url))
                admittedRemainder = true
            }
            if allRowsMS == nil, model.jobs.count == samples.count { allRowsMS = elapsed }
            if firstResultMS == nil, model.completedCount > 0 { firstResultMS = elapsed }
            if cancel, admittedRemainder, model.jobs.count == samples.count, !running.isEmpty, cancelRequested == nil {
                cancelRequested = now
                model.cancelAll()
            }
            if began.duration(to: now) > .seconds(1200) {
                model.cancelAll()
                throw NSError(domain: "Release QA timed out: \(name)", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = Self.milliseconds(began.duration(to: .now))
        let cancellationMS = cancelRequested.map { Self.milliseconds($0.duration(to: .now)) }
        XCTAssertEqual(model.jobs.count, samples.count, name)
        XCTAssertEqual(model.failedCount, 0, "\(name): \(model.jobs.filter { $0.state == .failed }.map { $0.filename + ": " + ($0.message ?? "") })")
        XCTAssertEqual(model.finishedCount, samples.count)
        XCTAssertEqual(model.progress, 1)
        XCTAssertLessThanOrEqual(maxRunning, 2)
        XCTAssertLessThanOrEqual(maxReserved, SafeFiles.memoryBudget)
        XCTAssertLessThan(firstRowsMS ?? .infinity, 5000, "Rows should appear before codec completion")
        XCTAssertLessThan(heartbeatGaps.max() ?? .infinity, 2000, "MainActor stalled for two seconds")
        if firstCount < samples.count { XCTAssertTrue(addWhileRunning, "Additional files must be admitted while a codec is active") }
        if cancel {
            XCTAssertNotNil(cancelRequested)
            XCTAssertGreaterThan(model.cancelledCount, 0)
            XCTAssertEqual(model.excludedCount, 0)
            XCTAssertLessThan(cancellationMS ?? .infinity, 120_000)
        } else if strip {
            XCTAssertEqual(model.excludedCount, 2, "HEIC and SVG explicitly reject metadata removal")
            XCTAssertEqual(model.completedCount, samples.count - 2)
            XCTAssertEqual(Set(model.jobs.filter { $0.state == .unsupported }.compactMap { job in samples.first { $0.url == job.sourceURL }?.info.format.rawValue }), Set(["heic", "svg"]))
        } else {
            XCTAssertEqual(model.completedCount, samples.count)
            XCTAssertEqual(model.excludedCount + model.cancelledCount, 0)
        }
        var rows: [[String: Any]] = []
        for job in model.jobs {
            let sample = try XCTUnwrap(samples.first { $0.url == job.sourceURL })
            var row: [String: Any] = ["input": sample.url.lastPathComponent, "format": sample.info.format.rawValue,
                "state": job.state.rawValue, "original_bytes": sample.bytes, "saved_bytes": job.savedBytes]
            if let message = job.message { row["message"] = message }
            if let output = job.resultURL {
                XCTAssertEqual(job.state, .optimized)
                XCTAssertEqual(output.deletingLastPathComponent(), directory)
                XCTAssertFalse(sentinels.keys.contains(output), "Collisions must choose a new filename")
                let info = try NativeImageProcessor().inspect(output)
                XCTAssertEqual(info.format, sample.info.format)
                XCTAssertEqual(info.width, sample.info.width); XCTAssertEqual(info.height, sample.info.height)
                // GIF can introduce transparent delta encodings while retaining
                // the exact fully composited pixels (verified below).
                if info.format != .gif { XCTAssertEqual(info.hasAlpha, sample.info.hasAlpha) }
                let bytes = try Data(contentsOf: output)
                XCTAssertLessThan(bytes.count, sample.bytes)
                XCTAssertEqual(job.resultBytes, Int64(bytes.count))
                row["output"] = output.lastPathComponent; row["result_bytes"] = bytes.count
                row["sha256"] = Self.hash(bytes)
                row["independent_visual_check"] = try verifyVisual(sample, output: output, mode: mode)
            } else {
                XCTAssertNotEqual(job.state, .optimized)
                if job.state == .unchanged { XCTAssertEqual(job.resultBytes, Int64(sample.bytes)) }
            }
            rows.append(row)
        }
        let originalsUnchanged = try samples.map { try Self.hash($0.url) } == samples.map(\.sha256)
        XCTAssertTrue(originalsUnchanged)
        var sentinelsUnchanged = true
        for (url, data) in sentinels {
            let actual = try Data(contentsOf: url)
            XCTAssertEqual(actual, data)
            if actual != data { sentinelsUnchanged = false }
        }
        let outputs = Set(model.jobs.compactMap(\.resultURL))
        XCTAssertEqual(outputs.count, model.jobs.filter { $0.state == .optimized }.count)
        XCTAssertEqual(model.savedBytes, model.jobs.reduce(0) { $0 + $1.savedBytes })
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let noOrphans = Set(files) == outputs.union(sentinels.keys) && Self.currentProcessWorkDirectories() == preexistingWork
        XCTAssertEqual(Set(files), outputs.union(sentinels.keys), "No orphan output, log or publication stage is allowed")
        XCTAssertEqual(Self.currentProcessWorkDirectories(), preexistingWork, "Every private work directory must be removed after completion/cancellation")
        let timings = processor.snapshot()
        var grouped: [[String: Any]] = []
        for format in Set(samples.map { $0.url.pathExtension.lowercased() }).sorted() {
            let records = timings.filter { $0["format"] as? String == format }
            let values = records.compactMap { $0["elapsed_ms"] as? Double }.sorted()
            if !values.isEmpty {
                grouped.append(["format": format, "count": values.count, "median_ms": values[values.count / 2],
                    "p95_ms": values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)],
                    "total_ms": values.reduce(0, +), "samples_ms": values])
            }
        }
        var result: [String: Any] = ["case": name, "mode": mode.rawValue, "strip_metadata": strip,
            "total": model.jobs.count, "optimized": model.jobs.filter { $0.state == .optimized }.count,
            "unchanged": model.jobs.filter { $0.state == .unchanged }.count, "unsupported": model.excludedCount,
            "cancelled": model.cancelledCount, "failed": model.failedCount, "saved_bytes": model.savedBytes,
            "elapsed_ms": elapsed, "add_while_running": addWhileRunning, "max_running_jobs_observed": maxRunning,
            "max_reserved_bytes_observed": maxReserved, "max_sampled_host_rss_bytes": rss.max() ?? 0,
            "main_actor_heartbeat_interval_ms": 10, "heartbeat_samples": heartbeatGaps.count,
            "max_main_actor_heartbeat_gap_ms": heartbeatGaps.max() ?? 0, "codec_timings": grouped, "rows": rows,
            "original_hashes_unchanged": originalsUnchanged, "collision_sentinels_unchanged": sentinelsUnchanged,
            "no_orphan_outputs_or_work": noOrphans]
        if let firstRowsMS { result["first_14_rows_ms"] = firstRowsMS }
        if let allRowsMS { result["all_rows_ms"] = allRowsMS }
        if let firstResultMS { result["first_result_ms"] = firstResultMS }
        if let cancellationMS { result["cancellation_to_quiescence_ms"] = cancellationMS }
        print("RELEASE_QA_BATCH \(name) \(elapsed / 1000)s optimized=\(model.jobs.filter { $0.state == .optimized }.count) unchanged=\(model.jobs.filter { $0.state == .unchanged }.count) cancelled=\(model.cancelledCount)")
        if cancel {
            // The same real model must remain usable after codecs unwind.
            model.clearFinished()
            let clearStart = ContinuousClock.now
            while !model.jobs.isEmpty && clearStart.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(model.jobs.isEmpty)
            let retrySource = try XCTUnwrap(samples.first { $0.info.format == .svg })
            model.addURLs([retrySource.url])
            let retryStart = ContinuousClock.now
            while model.hasActiveJobs && retryStart.duration(to: .now) < .seconds(30) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.hasActiveJobs)
            XCTAssertEqual(model.completedCount, 1)
            XCTAssertEqual(model.failedCount + model.cancelledCount + model.excludedCount, 0)
            XCTAssertEqual(Self.currentProcessWorkDirectories(), preexistingWork)
            let recoveredOutputs = Set(model.jobs.compactMap(\.resultURL))
            let afterRecovery = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(Set(afterRecovery), outputs.union(recoveredOutputs).union(sentinels.keys))
            result["new_admission_after_cancellation_completed"] = true
            result["recovery_outputs"] = recoveredOutputs.map(\.lastPathComponent)
        }
        return result
    }

    @MainActor
    private func verifyVisual(_ sample: Sample, output: URL, mode: OptimizationMode) throws -> String {
        if sample.info.format == .jpeg {
            let original = try Data(contentsOf: sample.url), candidate = try Data(contentsOf: output)
            let exact = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                    b.bindMemory(to: UInt8.self).baseAddress, b.count)
            }}
            // Coefficient identity is the JPEG lossless contract. Apple's
            // baseline/progressive decoder paths may round the same IDCT by a
            // few code values, so identical RGBA from those paths is not required.
            if exact == 1 { return "JPEG DCT coefficients exact; Apple baseline/progressive rounding may differ" }
            XCTAssertEqual(mode, .automatic, "Lossless JPEG must preserve every DCT coefficient")
            var scores = [Float](repeating: 0, count: 5)
            let _ = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                    b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
            }}
            XCTAssertTrue(scores.prefix(3).allSatisfy { $0.isFinite && $0 >= rc_profile_min_ssim_db(2) })
        }
        if sample.info.format == .svg {
            func render(_ url: URL) throws -> Data {
                let image = try XCTUnwrap(NSImage(contentsOf: url))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 256 * 4, bitsPerPixel: 32))
                memset(try XCTUnwrap(bitmap.bitmapData), 0, 256 * 256 * 4)
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: .zero, operation: .copy, fraction: 1)
                return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: 256 * 256 * 4)
            }
            XCTAssertTrue(try render(sample.url) == render(output), sample.url.lastPathComponent)
            return "AppKit 256x256 RGBA exact"
        }
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(sample.url as CFURL, nil))
        let candidate = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(original), CGImageSourceGetCount(candidate))
        var exact = true
        for frame in 0..<CGImageSourceGetCount(original) {
            func render(_ source: CGImageSource) throws -> Data {
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, frame, nil))
                XCTAssertEqual(image.width, sample.info.width); XCTAssertEqual(image.height, sample.info.height)
                let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
            }
            let a = try render(original), b = try render(candidate)
            if a != b {
                exact = false
                if sample.info.format == .png || sample.info.format == .gif || mode == .lossless {
                    XCTFail("Independent full-resolution RGBA must remain exact: \(sample.url.lastPathComponent), frame \(frame)")
                } else {
                    let pass = a.withUnsafeBytes { x in b.withUnsafeBytes { y in
                        rc_rgba_quality_rgb(x.bindMemory(to: UInt8.self).baseAddress, y.bindMemory(to: UInt8.self).baseAddress,
                            Int32(sample.info.width), Int32(sample.info.height), 2)
                    }}
                    XCTAssertEqual(pass, 1, "Independent Image I/O decode failed per-RGB quality: \(sample.url.lastPathComponent)")
                }
            }
        }
        return exact ? "Image I/O full-resolution RGBA exact, all frames" : "Image I/O full-resolution RGBA, Web 20 dB per-RGB SSIM"
    }

    private func makeCorpus() throws -> [Sample] {
        let root = Self.repository.appendingPathComponent(".build/release-qa-corpus", isDirectory: true)
        let encoder = Self.repository.appendingPathComponent(".build/qa-encode-rgba")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: encoder.path), "Run scripts/qa-release.sh")
        let photoURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "photo-ijg.jpg", withExtension: nil, subdirectory: "Fixtures"))
        let optionalPhotoURL = [Self.repository.appendingPathComponent(".build/release-qa-source.jpg"),
            Self.repository.appendingPathComponent(".build/qa-final/external/nasa-earth.jpg")].first { FileManager.default.fileExists(atPath: $0.path) }
        let manifestURL = Self.repository.appendingPathComponent(".build/release-qa-corpus.json")
        let recipeFiles = [URL(fileURLWithPath: #filePath), Self.repository.appendingPathComponent("scripts/qa-encode-rgba.c"), photoURL] + (optionalPhotoURL.map { [$0] } ?? [])
        let recipe = Self.hash(Data(try recipeFiles.map(Self.hash).joined(separator: ":").utf8))
        if let data = try? Data(contentsOf: manifestURL),
           let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           cached["recipe_sha256"] as? String == recipe,
           let rows = cached["samples"] as? [[String: Any]], rows.count == 140 {
            var restored: [Sample] = []
            for row in rows {
                guard let name = row["file"] as? String, URL(fileURLWithPath: name).lastPathComponent == name,
                      let expected = row["sha256"] as? String,
                      let data = try? Data(contentsOf: root.appendingPathComponent(name)), Self.hash(data) == expected else { restored = []; break }
                let url = root.appendingPathComponent(name)
                restored.append(.init(url: url, info: try NativeImageProcessor().inspect(url), bytes: data.count,
                    sha256: expected, content: row["content"] as? String ?? "Cached corpus"))
            }
            if restored.count == 140 {
                print("RELEASE_QA_CORPUS reused 140 hash-verified files with matching generation recipe")
                return restored
            }
        }
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ijg = try decode(photoURL)
        let external = try optionalPhotoURL.map(decode)
        let sizes = [(1600,1200), (1920,1080), (2048,1536), (2560,1920), (3000,2000)]
        var samples: [Sample] = []
        for index in 0..<20 {
            let (width, height) = sizes[index % sizes.count]
            let photo = index % 4 == 0 ? (external ?? ijg) : index % 4 == 1 ? ijg : nil
            let content = index % 4 == 0 ? (external == nil ? "IJG photograph, resized" : "Local external photograph, resized/cropped") : index % 4 == 1 ? "IJG photograph, resized" : "Original deterministic pattern, variant \(index)"
            let pixels = try raster(width: width, height: height, variant: index, photograph: photo)
            let image = try cgImage(pixels, width: width, height: height)
            // Filenames deliberately include Unicode; the extension remains truthful.
            let base = root.appendingPathComponent(String(format: "qa-%02d Fóto Ñ 试", index))
            for (ext, type) in [("png", "public.png"), ("jpg", "public.jpeg"), ("heic", "public.heic")] {
                let output = base.appendingPathExtension(ext)
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil))
                let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0,
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Original Release QA fixture \(index)"]]
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination), ext)
            }
            let raw = root.appendingPathComponent("qa-pixels.rgba")
            try pixels.write(to: raw)
            let process = Process(); process.executableURL = encoder
            process.arguments = [raw.path, String(width), String(height), base.path, String(index)]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            try FileManager.default.removeItem(at: raw)
            try animatedGIF(base.appendingPathExtension("gif"), width: width, height: height, variant: index)
            try svg(width: width, height: height, variant: index).write(to: base.appendingPathExtension("svg"), atomically: true, encoding: .utf8)
            for ext in ["png", "jpg", "webp", "heic", "avif", "gif", "svg"] {
                let url = base.appendingPathExtension(ext), data = try Data(contentsOf: url)
                let info = try NativeImageProcessor().inspect(url)
                XCTAssertEqual(info.width, width); XCTAssertEqual(info.height, height)
                XCTAssertLessThanOrEqual(info.estimatedMemory, SafeFiles.memoryBudget)
                samples.append(.init(url: url, info: info, bytes: data.count, sha256: Self.hash(data),
                    content: ext == "svg" ? "Original vector composition, 800 shapes" : ext == "gif" ? "Original three-frame animation" : content))
            }
            print("RELEASE_QA_CORPUS \(index + 1)/20 \(width)x\(height)")
        }
        var manifest: [String: Any] = ["samples": samples.map(\.json), "count": samples.count,
            "directory": ".build/release-qa-corpus", "photograph_license": "Fixtures/IJG-README.txt applies to the IJG-derived inputs",
            "original_artwork_license": "Original deterministic Resim test artwork; redistributable", "recipe_sha256": recipe]
        if let optionalPhotoURL, let external {
            manifest["optional_external_source"] = ["file": optionalPhotoURL.lastPathComponent,
                "sha256": try Self.hash(optionalPhotoURL), "width": external.width, "height": external.height]
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        return samples
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func cgImage(_ data: Data, width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func raster(width: Int, height: Int, variant: Int, photograph: CGImage? = nil) throws -> Data {
        var pixels = Data(repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            if let photograph {
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.interpolationQuality = .high
                let scale = max(Double(width) / Double(photograph.width), Double(height) / Double(photograph.height))
                context.draw(photograph, in: CGRect(x: 0, y: 0, width: Double(photograph.width) * scale, height: Double(photograph.height) * scale))
                // A small original variation keeps differently named inputs distinct.
                for x in 0..<min(width, 30 + variant) { bytes[x * 4] = UInt8(variant * 7) }
            } else {
                for y in 0..<height { for x in 0..<width {
                    let p = (y * width + x) * 4
                    if variant % 4 == 2 {
                        let value = 80 + (x * 512 / width + y * 384 / height) / 12
                        bytes[p] = UInt8(value + variant); bytes[p + 1] = UInt8(value); bytes[p + 2] = UInt8(value - variant)
                    } else {
                        let edge = x % (53 + variant) < 2 || y % (61 + variant) < 2
                        bytes[p] = edge ? 230 : UInt8(30 + x * 180 / width)
                        bytes[p + 1] = edge ? 55 : UInt8(30 + y * 180 / height)
                        bytes[p + 2] = UInt8((x / 9 + y / 11 + variant * 7) % 256)
                    }
                }}
            }
        }
        return pixels
    }
    private func animatedGIF(_ url: URL, width: Int, height: Int, variant: Int) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frame, delay) in [0.07, 0.13, 0.25].enumerated() {
            let pixels = try raster(width: width, height: height, variant: variant * 4 + frame + 2)
            let image = try cgImage(pixels, width: width, height: height)
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func svg(width: Int, height: Int, variant: Int) -> String {
        let shapes = (0..<800).map { i in
            "    <rect id=\"shape-\(i)\" class=\"tile\" fill=\"url(#sunset)\" x=\"\((i * 53 + variant) % width)\" y=\"\((i * 71) % height)\" width=\"37.125\" height=\"21.625\" />"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <!--  Original Resim Release QA fixture; preserve this license comment.  -->
          <title>Resim QA \(variant)</title>
          <metadata>Original vector fixture; unknown metadata is significant. </metadata>
          <style>.tile { stroke: #192343; stroke-width: 0.125; }</style>
          <defs><linearGradient id="sunset"><stop offset="0" stop-color="#ffb957"/><stop offset="1" stop-color="#ef6689"/></linearGradient></defs>
        \(shapes)
          <use href="#shape-0" x="42" y="17"/>
          <text x="20" y="40">SVG QA Ñ \(variant)</text>
        </svg>
        """
    }

    private static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private static func write(_ report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: repository.appendingPathComponent(".build/release-qa.json"), options: .atomic)
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hash(_ url: URL) throws -> String { hash(try Data(contentsOf: url)) }
    private static func currentProcessWorkDirectories() -> Set<URL> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work")
        let prefix = "resim-\(ProcessInfo.processInfo.processIdentifier)-"
        return Set(((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) })
    }
    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}
