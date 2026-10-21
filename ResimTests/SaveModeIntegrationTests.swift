import XCTest
import AppKit
import ImageIO
import CryptoKit
@testable import Resim

final class SaveModeIntegrationTests: XCTestCase {
    @MainActor
    func testSevenRealFormatsReplaceOnlyDisposableCopiesInBothModes() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = repository.appendingPathComponent(".build/release-qa-corpus.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Run scripts/qa-release.sh first to generate the local seven-format corpus")
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let records = try XCTUnwrap(manifest["samples"] as? [[String: Any]])
        XCTAssertEqual(records.count, 140)
        let corpus = repository.appendingPathComponent(".build/release-qa-corpus", isDirectory: true)
        let originalURLs = try records.map { row -> URL in
            let name = try XCTUnwrap(row["file"] as? String)
            XCTAssertEqual(URL(fileURLWithPath: name).lastPathComponent, name)
            return corpus.appendingPathComponent(name)
        }
        let expectedHashes = try records.map { try XCTUnwrap($0["sha256"] as? String) }
        XCTAssertEqual(try originalURLs.map(hash), expectedHashes)
        var chosen = Array(originalURLs.prefix(7))
        let gifIndex = try XCTUnwrap(chosen.firstIndex { $0.pathExtension.lowercased() == "gif" })
        // Image I/O already optimizes the large corpus GIFs well. This authored
        // opaque fixture guarantees a real, smaller transparent delta result.
        chosen[gifIndex] = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "gif-opaque-delta.gif", withExtension: nil, subdirectory: "Fixtures"))
        let originalData = try chosen.map { try Data(contentsOf: $0) }
        let information = try chosen.map { try NativeImageProcessor().inspect($0) }
        XCTAssertEqual(Set(information.map { $0.format.rawValue }), Set(["png", "jpeg", "webp", "heic", "avif", "gif", "svg"]))
        var batches: [[String: Any]] = []
        for mode in OptimizationMode.allCases {
            // This is the only directory whose files may be replaced by this test.
            let directory = repository.appendingPathComponent(".build/qa-final/replace-\(mode.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sources = try chosen.map { original -> URL in
                let disposable = directory.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.copyItem(at: original, to: disposable)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: disposable.path)
                return disposable
            }
            let baselineWork = currentProcessWorkDirectories()
            let suite = "resim-real-replacement-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: defaults)
            model.settings = .init(mode: mode, destination: directory.appendingPathComponent("missing-folder"),
                fileSaveMode: .replaceOriginal)
            let start = ContinuousClock.now
            model.addURLs(sources)
            while model.hasActiveJobs && start.duration(to: .now) < .seconds(180) {
                try await Task.sleep(for: .milliseconds(10))
            }
            if model.hasActiveJobs {
                model.cancelAll()
                XCTFail("Seven-format replacement batch timed out")
                throw NSError(domain: "Replacement QA timeout", code: 1)
            }
            XCTAssertEqual(model.jobs.count, 7)
            XCTAssertEqual(model.completedCount, 7)
            XCTAssertEqual(model.failedCount + model.excludedCount + model.cancelledCount, 0,
                model.jobs.compactMap(\.message).joined(separator: "; "))
            XCTAssertGreaterThan(model.jobs.filter { $0.state == .optimized }.count, 0, "Exercise actual atomic replacement")
            for format in [ImageFormat.jpeg, .gif, .svg] {
                let index = try XCTUnwrap(information.firstIndex { $0.format == format })
                XCTAssertEqual(model.jobs.first { $0.sourceURL == sources[index] }?.state, .optimized,
                    "\(format.rawValue) must exercise actual replacement in \(mode.rawValue)")
            }
            var rows: [[String: Any]] = []
            for (index, source) in sources.enumerated() {
                let job = try XCTUnwrap(model.jobs.first { $0.sourceURL == source })
                let data = try Data(contentsOf: source)
                let before = originalData[index], info = information[index]
                let after = try NativeImageProcessor().inspect(source)
                XCTAssertEqual(after.format, info.format)
                XCTAssertEqual(after.width, info.width); XCTAssertEqual(after.height, info.height)
                if info.format != .gif { XCTAssertEqual(after.hasAlpha, info.hasAlpha) }
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
                var row: [String: Any] = ["file": source.lastPathComponent, "format": info.format.rawValue,
                    "state": job.state.rawValue, "original_bytes": before.count, "result_bytes": data.count,
                    "original_sha256": hash(before), "result_sha256": hash(data)]
                if job.state == .optimized {
                    XCTAssertEqual(job.resultURL, source)
                    XCTAssertLessThan(data.count, before.count)
                    XCTAssertEqual(job.originalBytes, Int64(before.count))
                    XCTAssertEqual(job.resultBytes, Int64(data.count))
                    row["quality_check"] = try verify(before, data, info: info, mode: mode)
                } else {
                    XCTAssertEqual(job.state, .unchanged)
                    XCTAssertNil(job.resultURL)
                    XCTAssertEqual(hash(data), hash(before), "No-reduction must leave the disposable source byte-identical")
                    row["quality_check"] = "Original bytes unchanged"
                }
                rows.append(row)
            }
            let actualFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(Set(actualFiles), Set(sources), "Replacement must leave exactly seven input paths, with no copies, stages or logs")
            XCTAssertEqual(currentProcessWorkDirectories(), baselineWork, "No private work directory may remain")
            XCTAssertEqual(try originalURLs.map(hash), expectedHashes, "The 140-file reference corpus is never a replacement input")
            XCTAssertEqual(model.savedBytes, model.jobs.reduce(0) { $0 + $1.savedBytes })
            let elapsed = start.duration(to: .now).components
            batches.append(["mode": mode.rawValue, "total": model.jobs.count,
                "optimized": model.jobs.filter { $0.state == .optimized }.count, "unchanged": model.jobs.filter { $0.state == .unchanged }.count,
                "failed": model.failedCount, "elapsed_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                "rows": rows])
        }
        let report: [String: Any] = ["status": (testRun?.failureCount ?? 0) == 0 ? "passed" : "failed",
            "scope": "Seven formats in both modes: six large corpus inputs plus the redistributable opaque GIF delta fixture that guarantees a real GIF reduction. replaceOriginal explicitly selected; only disposable files under .build/qa-final/replace-<mode> may change.",
            "batches": batches, "reference_corpus_sha256_unchanged": try originalURLs.map(hash) == expectedHashes]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: repository.appendingPathComponent(".build/qa-final/replacement-seven-formats.json"), options: .atomic)
    }

    @MainActor
    private func verify(_ original: Data, _ candidate: Data, info: ImageInfo, mode: OptimizationMode) throws -> String {
        if info.format == .jpeg {
            let exact = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                rc_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                    b.bindMemory(to: UInt8.self).baseAddress, b.count)
            }}
            if exact == 1 { return "JPEG DCT coefficients exact (Apple baseline/progressive IDCT can round differently)" }
            XCTAssertEqual(mode, .automatic)
            var scores = [Float](repeating: 0, count: 5)
            let _ = original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                    b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
            }}
            XCTAssertTrue(scores.prefix(3).allSatisfy { $0.isFinite && $0 >= rc_profile_min_ssim_db(2) })
        }
        if info.format == .svg {
            XCTAssertTrue(SVGProcessor().semanticsPreserved(original: original, candidate: candidate))
            XCTAssertTrue(try renderSVG(original) == renderSVG(candidate))
            return "SVG XML semantics and independent AppKit rendering exact"
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateWithData(candidate as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), CGImageSourceGetCount(output))
        if info.format == .gif {
            XCTAssertTrue(GIFProcessor().metadataAndTimingPreserved(original: original, candidate: candidate, stripping: false))
        }
        var exact = true
        for index in 0..<CGImageSourceGetCount(source) {
            let a = try renderRaster(source, index: index), b = try renderRaster(output, index: index)
            if a != b {
                exact = false
                if mode == .lossless || info.format == .png || info.format == .gif {
                    XCTFail("Lossless full-resolution Image I/O pixels differ for \(info.format.rawValue)")
                } else {
                    let pass = a.withUnsafeBytes { x in b.withUnsafeBytes { y in
                        rc_rgba_quality_rgb(x.bindMemory(to: UInt8.self).baseAddress,
                            y.bindMemory(to: UInt8.self).baseAddress, Int32(info.width), Int32(info.height), 2)
                    }}
                    XCTAssertEqual(pass, 1)
                }
            }
        }
        return exact ? "Independent Image I/O full-resolution RGBA exact" : "Independent Image I/O Web 20 dB per-RGB SSIM"
    }

    private func renderRaster(_ source: CGImageSource, index: Int) throws -> Data {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    @MainActor
    private func renderSVG(_ data: Data) throws -> Data {
        let image = try XCTUnwrap(NSImage(data: data))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 1024, bitsPerPixel: 32))
        memset(try XCTUnwrap(bitmap.bitmapData), 0, 256 * 256 * 4)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: .zero, operation: .copy, fraction: 1)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: 256 * 256 * 4)
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func hash(_ url: URL) throws -> String { hash(try Data(contentsOf: url)) }
    private func currentProcessWorkDirectories() -> Set<URL> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("com.resim.work")
        let prefix = "resim-\(ProcessInfo.processInfo.processIdentifier)-"
        return Set(((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) })
    }
}
