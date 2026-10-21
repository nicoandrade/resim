import Foundation

nonisolated enum JobState: String, Sendable {
    case queued, running, optimized, unchanged, unsupported, cancelled, failed

    var isFinished: Bool { self != .queued && self != .running }
    var canRetry: Bool { self == .failed || self == .cancelled || self == .unsupported }
}

nonisolated struct ImageJob: Identifiable, Sendable {
    let id: UUID
    var sourceURL: URL
    var filename: String { sourceURL.lastPathComponent }
    var originalBytes: Int64?
    var resultBytes: Int64?
    var resultURL: URL?
    var state: JobState = .queued
    var message: String?
    var settings: OptimizationSettings
    var savedBytes: Int64 {
        guard state == .optimized, let originalBytes, let resultBytes else { return 0 }
        return max(0, originalBytes - resultBytes)
    }
    var savingsPercent: Double? {
        guard let originalBytes, originalBytes > 0, resultBytes != nil else { return nil }
        return Double(savedBytes) / Double(originalBytes) * 100
    }
}
