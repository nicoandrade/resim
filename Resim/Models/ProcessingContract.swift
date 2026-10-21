import Foundation

nonisolated enum OptimizationMode: String, Codable, CaseIterable, Sendable {
    case automatic, lossless
}

nonisolated enum CompressionProfile: String, Codable, CaseIterable, Sendable {
    case conservative, web, maximum

    var title: String {
        switch self {
        case .conservative: String(localized: "Conservative")
        case .web: String(localized: "Web")
        case .maximum: String(localized: "Maximum compression")
        }
    }

    var description: String {
        switch self {
        case .conservative: String(localized: "Prioritizes image fidelity with gentle compression.")
        case .web: String(localized: "Adapts compression to each image to reduce size while keeping visual changes small. Recommended.")
        case .maximum: String(localized: "Prioritizes smaller files. Some loss of detail may be visible.")
        }
    }

    // Native policy values are stable; 0 remains the separate lossless mode.
    var codecValue: Int32 {
        switch self {
        case .conservative: 1
        case .web: 2
        case .maximum: 3
        }
    }
}

nonisolated enum FileSaveMode: String, Codable, CaseIterable, Sendable {
    case replaceOriginal, copyBesideOriginal, copyToFolder
}

nonisolated struct OptimizationSettings: Hashable, Codable, Sendable {
    var mode: OptimizationMode = .automatic
    var profile: CompressionProfile = .web
    var destination: URL? = nil
    var stripPersonalMetadata: Bool = false
    var fileSaveMode: FileSaveMode = .replaceOriginal

    init(mode: OptimizationMode = .automatic, destination: URL? = nil,
         stripPersonalMetadata: Bool = false, fileSaveMode: FileSaveMode? = nil,
         profile: CompressionProfile = .web) {
        self.mode = mode
        self.profile = profile
        self.destination = destination
        self.stripPersonalMetadata = stripPersonalMetadata
        self.fileSaveMode = fileSaveMode ?? (destination == nil ? .replaceOriginal : .copyToFolder)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, profile, destination, stripPersonalMetadata, fileSaveMode
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(OptimizationMode.self, forKey: .mode)
        profile = try values.decodeIfPresent(CompressionProfile.self, forKey: .profile) ?? .web
        destination = try values.decodeIfPresent(URL.self, forKey: .destination)
        stripPersonalMetadata = try values.decode(Bool.self, forKey: .stripPersonalMetadata)
        // Existing saved preferences retain their copy behavior when upgrading.
        fileSaveMode = try values.decodeIfPresent(FileSaveMode.self, forKey: .fileSaveMode)
            ?? (destination == nil ? .copyBesideOriginal : .copyToFolder)
    }

    var codecProfile: Int32 { mode == .lossless ? 0 : profile.codecValue }
}

nonisolated enum ImageFormat: String, Sendable {
    case png, jpeg, webp, heic, avif, gif, svg
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

nonisolated struct ImageInfo: Sendable {
    let format: ImageFormat
    let width: Int
    let height: Int
    let hasAlpha: Bool
    let estimatedMemory: UInt64
}

nonisolated final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

nonisolated enum ProcessingError: LocalizedError, Sendable {
    case unsupported(String), invalid(String), resourceLimit(String), changedSource, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .invalid(let message), .resourceLimit(let message), .unavailable(let message): message
        case .changedSource: String(localized: "The original changed while being read. Try again.")
        }
    }
}

nonisolated protocol ImageProcessing: Sendable {
    func inspect(_ source: URL) throws -> ImageInfo
    /// Returns a validated, smaller candidate in workDirectory, or nil for no reduction.
    /// All reads, encodes and comparisons use the same stable source snapshot.
    func optimize(source: URL, workDirectory: URL, settings: OptimizationSettings,
                  cancellation: CancellationToken) throws -> URL?
}
