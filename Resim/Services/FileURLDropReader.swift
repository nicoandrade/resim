import Foundation
import UniformTypeIdentifiers
import OSLog

/// Finder supplies real file URLs as NSURL or serialized URL data. File promises and
/// remote URLs deliberately remain outside the v1 drop contract.
nonisolated enum FileURLDropReader {
    static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        let url: URL?
        if let value = item as? URL { url = value }
        else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
        else if let value = item as? String { url = URL(string: value) }
        else { url = nil }
        return url?.isFileURL == true ? url : nil
    }

    /// Item-provider callbacks are external asynchronous work. Complete each provider
    /// exactly once, including failures, after its incremental URL delivery runs.
    @MainActor
    static func receive(_ providers: [NSItemProvider],
                        onReceive: @escaping @MainActor @Sendable (URL) -> Void,
                        onComplete: @escaping @MainActor @Sendable () -> Void = {}) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let reception = Reception(remaining: files.count, onReceive: onReceive, onComplete: onComplete)
        for provider in files {
            let delivery = SingleDelivery()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard delivery.claim() else { return }
                let url = error == nil ? fileURL(from: item) : nil
                if url == nil {
                    Logger(subsystem: "com.resim.app", category: "Drop").error("Could not receive a local URL: \(error != nil)")
                }
                Task { @MainActor in reception.finish(url) }
            }
        }
        return true
    }

    @MainActor
    private final class Reception {
        private var remaining: Int
        private let onReceive: @MainActor @Sendable (URL) -> Void
        private let onComplete: @MainActor @Sendable () -> Void

        init(remaining: Int, onReceive: @escaping @MainActor @Sendable (URL) -> Void,
             onComplete: @escaping @MainActor @Sendable () -> Void) {
            self.remaining = remaining
            self.onReceive = onReceive
            self.onComplete = onComplete
        }

        func finish(_ url: URL?) {
            if let url { onReceive(url) }
            remaining -= 1
            if remaining == 0 { onComplete() }
        }
    }

    private final class SingleDelivery: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = false
        func claim() -> Bool {
            lock.withLock {
                guard !delivered else { return false }
                delivered = true
                return true
            }
        }
    }
}
