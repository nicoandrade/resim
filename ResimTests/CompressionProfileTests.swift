import XCTest
@testable import Resim

final class CompressionProfileTests: XCTestCase {
    func testMaximumJPEGFindsIntermediateQualityWithoutRelaxingTheFloor() throws {
        XCTAssertEqual(rc_profile_min_ssim_db(3), 16)
        XCTAssertEqual(rc_profile_attempts(3), 10)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "icc-444.jpg", withExtension: nil, subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let output = try XCTUnwrap(NativeImageProcessor().optimize(source: source, workDirectory: work,
            settings: .init(profile: .maximum), cancellation: CancellationToken()))
        let candidate = try Data(contentsOf: output)
        // The old coarse search saves less than 25% on this pinned fixture.
        XCTAssertLessThan(candidate.count, original.count * 3 / 4)
        var scores = [Float](repeating: 0, count: 5)
        original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
            _ = rc_jpeg_ssim_rgb(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                 b.bindMemory(to: UInt8.self).baseAddress, b.count, &scores)
        }}
        XCTAssertTrue(scores.prefix(3).allSatisfy { $0.isFinite && $0 >= 16 }, "\(scores)")
        let before = try NativeImageProcessor().inspect(source), after = try NativeImageProcessor().inspect(output)
        XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(before.format, after.format)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMaximumJPEGLateCancellationDiscardsTheSmallerCandidate() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "icc-444.jpg", withExtension: nil, subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        // First observe callback count, then cancel just before completion. This
        // exercises an existing accepted candidate without wall-clock timing.
        let state = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        state.initialize(repeating: 0, count: 2)
        state[1] = Int.max
        defer { state.deinitialize(count: 2); state.deallocate() }
        let callback: RCShouldCancel = { context in
            let state = context!.assumingMemoryBound(to: Int.self)
            state[0] += 1
            return state[0] >= state[1] ? 1 : 0
        }
        for pass in 0..<2 {
            var output = RCBuffer(bytes: nil, size: 0)
            defer { rc_buffer_free(&output) }
            var error = [CChar](repeating: 0, count: 512)
            let status = original.withUnsafeBytes { bytes in
                rc_jpeg_optimize(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                    3, 0, callback, state, &output, &error, error.count)
            }
            XCTAssertEqual(status, 1)
            if pass == 0 {
                XCTAssertNotNil(output.bytes)
                XCTAssertLessThan(output.size, original.count * 3 / 4)
                XCTAssertGreaterThan(state[0], 2)
                state[1] = state[0] - 1
                state[0] = 0
            } else {
                XCTAssertGreaterThanOrEqual(state[0], state[1])
                XCTAssertNil(output.bytes)
                XCTAssertEqual(output.size, 0)
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDefaultAndLegacyPreferencesUseWebWithoutChangingExplicitLosslessOrSaveMode() throws {
        XCTAssertEqual(OptimizationSettings().profile, .web)
        for mode in OptimizationMode.allCases {
            let data = try JSONSerialization.data(withJSONObject: [
                "mode": mode.rawValue, "stripPersonalMetadata": true, "fileSaveMode": "copyBesideOriginal"
            ])
            let settings = try JSONDecoder().decode(OptimizationSettings.self, from: data)
            XCTAssertEqual(settings.profile, .web)
            XCTAssertEqual(settings.mode, mode)
            XCTAssertEqual(settings.fileSaveMode, .copyBesideOriginal)
            XCTAssertTrue(settings.stripPersonalMetadata)
        }
        for profile in CompressionProfile.allCases {
            let settings = OptimizationSettings(profile: profile)
            XCTAssertEqual(try JSONDecoder().decode(OptimizationSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
    }

    func testProfilesAcceptOnlySmallerValidatedOutputsAndStrongerProfilesDoNotGrow() throws {
        for name in ["photo-quality100.jpg", "icc-444.jpg", "already-compressed.jpg", "accepted-auto.jpg", "lossy.webp", "avif-auto.avif"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let original = try Data(contentsOf: source)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var previousBytes = original.count
            for profile in CompressionProfile.allCases {
                let processor = NativeImageProcessor()
                let output = try processor.optimize(source: source, workDirectory: work,
                    settings: .init(profile: profile), cancellation: CancellationToken())
                let result = try output.map { try Data(contentsOf: $0) } ?? original
                XCTAssertLessThanOrEqual(result.count, previousBytes, "\(name) / \(profile)")
                previousBytes = result.count
                if let output {
                    let before = try processor.inspect(source), after = try processor.inspect(output)
                    XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
                    XCTAssertEqual(before.format, after.format); XCTAssertEqual(before.hasAlpha, after.hasAlpha)
                    XCTAssertLessThan(result.count, original.count)
                }
                var scores = [Float](repeating: 0, count: 5)
                original.withUnsafeBytes { a in result.withUnsafeBytes { b in
                    let x = a.bindMemory(to: UInt8.self).baseAddress, y = b.bindMemory(to: UInt8.self).baseAddress
                    if name.hasSuffix("avif") {
                        XCTAssertEqual(rc_avif_quality_rgb(x, a.count, y, b.count, profile.codecValue), 1)
                    } else {
                        if name.hasSuffix("webp") { _ = rc_webp_ssim_rgb(x, a.count, y, b.count, &scores) }
                        else { _ = rc_jpeg_ssim_rgb(x, a.count, y, b.count, &scores) }
                        XCTAssertTrue(scores.prefix(3).allSatisfy { $0.isFinite && $0 >= rc_profile_min_ssim_db(profile.codecValue) }, "\(name) / \(profile): \(scores)")
                    }
                }}
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testLosslessOverridesEveryProfileAndTransparentWebPStaysExact() throws {
        for name in ["photo-quality100.jpg", "exact-alpha.webp", "avif-auto.avif", "rgba.png"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let original = try Data(contentsOf: source)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var baseline: Data?
            for profile in CompressionProfile.allCases {
                let resultURL = try NativeImageProcessor().optimize(source: source, workDirectory: work,
                    settings: .init(mode: .lossless, profile: profile), cancellation: CancellationToken())
                let data = try resultURL.map { try Data(contentsOf: $0) } ?? original
                if let baseline { XCTAssertEqual(data, baseline) }
                baseline = data
                if name.hasSuffix("webp") {
                    let automatic = try NativeImageProcessor().optimize(source: source, workDirectory: work,
                        settings: .init(profile: profile), cancellation: CancellationToken())
                    let candidate = try automatic.map { try Data(contentsOf: $0) } ?? original
                    original.withUnsafeBytes { a in candidate.withUnsafeBytes { b in
                        XCTAssertEqual(rc_webp_pixels_equal(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                            b.bindMemory(to: UInt8.self).baseAddress, b.count), 1)
                    }}
                }
            }
        }
    }

    func testQualityGateRejectsSevereDamageAndAlphaChangesForEveryProfile() {
        let original = [UInt8](repeating: 128, count: 64 * 64 * 4)
        var damaged = original, alphaChanged = original
        for i in stride(from: 0, to: damaged.count, by: 4) { damaged[i] = 0; alphaChanged[i + 3] = 255 }
        for profile in CompressionProfile.allCases {
            XCTAssertEqual(rc_rgba_quality_rgb(original, original, 64, 64, profile.codecValue), 1)
            XCTAssertEqual(rc_rgba_quality_rgb(original, damaged, 64, 64, profile.codecValue), 0)
            XCTAssertEqual(rc_rgba_quality_rgb(original, alphaChanged, 64, 64, profile.codecValue), 0)
        }
    }

    func testCancellationDuringNativeSearchDiscardsEarlierCandidates() throws {
        for name in ["accepted-auto.jpg", "lossy.webp", "avif-auto.avif"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let data = try Data(contentsOf: url)
            var output = RCBuffer(bytes: nil, size: 0)
            defer { rc_buffer_free(&output) }
            var error = [CChar](repeating: 0, count: 512)
            let calls = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            calls.initialize(to: 0)
            defer { calls.deinitialize(count: 1); calls.deallocate() }
            let callback: RCShouldCancel = { context in
                let calls = context!.assumingMemoryBound(to: Int.self)
                calls.pointee += 1
                return calls.pointee >= 5 ? 1 : 0
            }
            data.withUnsafeBytes { bytes in
                let source = bytes.bindMemory(to: UInt8.self).baseAddress
                if name.hasSuffix("jpg") { _ = rc_jpeg_optimize(source, data.count, 3, 0, callback, calls, &output, &error, error.count) }
                else if name.hasSuffix("webp") { _ = rc_webp_optimize(source, data.count, 3, 0, callback, calls, &output, &error, error.count) }
                else { _ = rc_avif_optimize(source, data.count, 3, 0, callback, calls, &output, &error, error.count) }
            }
            XCTAssertGreaterThanOrEqual(calls.pointee, 5)
            XCTAssertNil(output.bytes)
            XCTAssertEqual(output.size, 0)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
}
