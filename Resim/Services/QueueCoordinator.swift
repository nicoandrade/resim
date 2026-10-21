import Foundation
import Darwin

nonisolated enum QueueEvent: Sendable {
    case updated(ImageJob)
    case removed(UUID)
}

actor QueueCoordinator {
    private struct DeduplicationKey: Hashable {
        let identity: FileIdentity
        let settings: OptimizationSettings
    }
    private struct Entry {
        var job: ImageJob
        var token = CancellationToken()
        var generation = UUID()
        var fingerprint: FileFingerprint?
        var digest: Data?
        var info: ImageInfo?
        var key: DeduplicationKey?
    }
    private struct Prepared: Sendable {
        let candidate: URL?
        let directory: URL
        let info: ImageInfo
        let publication: SafeFiles.Publication?
    }
    private let processor: any ImageProcessing
    private let deliver: @Sendable (QueueEvent) async -> Void
    private let codecPool = BlockingCodecPool()
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var running: [UUID: UInt64] = [:]
    private var producedIdentities: Set<FileIdentity> = []
    private var producedPaths: Set<String> = []
    private var drainingAdmissions = false
    private var pendingEvents: [QueueEvent?] = []
    private var deliveringEvents = false

    init(processor: any ImageProcessing, deliver: @escaping @Sendable (QueueEvent) async -> Void) {
        self.processor = processor
        self.deliver = deliver
    }

    func addURLs(_ urls: [URL], settings: OptimizationSettings) async {
        let jobs = urls.map { ImageJob(id: UUID(), sourceURL: $0, settings: settings) }
        for job in jobs {
            entries[job.id] = Entry(job: job)
            order.append(job.id)
        }
        await send(jobs.map { .updated($0) })
        await drainAdmissions()
    }

    /// Queue each mutation's events before suspending. The receiver may yield;
    /// later transitions must not overtake an older update or resurrect a removed row.
    private func send(_ events: [QueueEvent]) async {
        pendingEvents.append(contentsOf: events.map(Optional.some))
        guard !deliveringEvents else { return }
        deliveringEvents = true
        defer {
            pendingEvents.removeAll(keepingCapacity: true)
            deliveringEvents = false
        }
        var next = 0
        while next < pendingEvents.count {
            let event = pendingEvents[next]!
            pendingEvents[next] = nil
            next += 1
            await deliver(event)
        }
    }

    func retry(_ id: UUID, settings: OptimizationSettings) async {
        guard let old = entries[id], old.job.state.canRetry, running[id] == nil else { return }
        var job = old.job
        job.settings = settings
        job.state = .queued
        job.message = nil
        job.resultURL = nil
        job.resultBytes = nil
        entries[id] = Entry(job: job)
        await send([.updated(job)])
        await drainAdmissions()
    }

    private func drainAdmissions() async {
        guard !drainingAdmissions else { return }
        drainingAdmissions = true
        defer { drainingAdmissions = false }
        // Multiple drops share one admission worker as well as the bounded codec pool.
        while let id = order.first(where: { entries[$0]?.job.state == .queued && entries[$0]?.info == nil }) {
            await admit(id)
        }
    }

    private func admit(_ id: UUID) async {
        guard let entry = entries[id], entry.job.state == .queued else { return }
        let generation = entry.generation
        let input = entry.job.sourceURL
        let processor = processor
        let token = entry.token
        let admission = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                Result { () throws -> (URL, SafeFiles.SourceSignature) in
                    let url = try SafeFiles.resolve(input)
                    let signature = try SafeFiles.contentSignature(url, cancellation: token)
                    return (url, signature)
                }
            }
        }.value
        guard var current = entries[id], current.generation == generation, current.job.state == .queued else { return }
        switch admission {
        case .success(let (url, signature)):
            let fingerprint = signature.fingerprint
            let key = DeduplicationKey(identity: fingerprint.identity, settings: current.job.settings)
            if producedIdentities.contains(fingerprint.identity) || producedPaths.contains(url.path) ||
                entries.contains(where: { $0.key != id && $0.value.key == key }) {
                entries.removeValue(forKey: id)
                order.removeAll { $0 == id }
                await send([.removed(id)])
                return
            }
            current.job.sourceURL = url
            current.job.originalBytes = fingerprint.bytes
            current.fingerprint = fingerprint
            current.digest = signature.digest
            current.key = key
            entries[id] = current
            await send([.updated(current.job)])
            let inspection = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    Result { () throws -> (ImageInfo, FileFingerprint) in
                        try SafeFiles.validateSize(fingerprint)
                        guard FileManager.default.isReadableFile(atPath: url.path) else {
                            throw ProcessingError.unavailable(String(localized: "Cannot read the file. Check its permissions."))
                        }
                        let info = try processor.inspect(url)
                        try SafeFiles.validateInfo(info)
                        let verified = try SafeFiles.verifiedFingerprint(url, expected: fingerprint, digest: signature.digest, phase: "after inspection")
                        return (info, verified)
                    }
                }
            }.value
            guard var inspected = entries[id], inspected.generation == generation, inspected.job.state == .queued else { return }
            switch inspection {
            case .success(let (info, verified)):
                inspected.info = info
                inspected.fingerprint = verified
                entries[id] = inspected
                await schedule()
            case .failure(let error):
                inspected.job.state = Self.failureState(error)
                inspected.job.message = error.localizedDescription
                entries[id] = inspected
                await send([.updated(inspected.job)])
            }
        case .failure(let error):
            current.job.state = Self.failureState(error)
            current.job.message = error.localizedDescription
            entries[id] = current
            await send([.updated(current.job)])
        }
    }

    private func schedule() async {
        // Only started jobs enter the fixed codec pool; queued files do not allocate buffers or snapshots.
        for id in order {
            guard running.count < 2 else { break }
            guard var entry = entries[id], entry.job.state == .queued,
                  let fingerprint = entry.fingerprint, let digest = entry.digest, let info = entry.info else { continue }
            let reserved = max(1, info.estimatedMemory)
            let used = running.values.reduce(0, +)
            let budget = running.isEmpty ? SafeFiles.memoryBudget : SafeFiles.concurrentMemoryBudget
            // Drain active workers for the first ready image that does not fit.
            // Starting smaller images behind it could otherwise starve it forever.
            guard used <= budget, reserved <= budget - used else { break }
            entry.job.state = .running
            entries[id] = entry
            running[id] = reserved
            let generation = entry.generation
            let job = entry.job
            let token = entry.token
            let processor = processor
            codecPool.submit {
                // Drain ImageIO/Foundation temporaries before releasing the worker's
                // reservation or starting the next image on this executor thread.
                let outcome = autoreleasepool {
                    Result { try Self.prepare(job: job, processor: processor, fingerprint: fingerprint,
                                              digest: digest, info: info, token: token) }
                }
                if reserved >= 64 * 1_024 * 1_024 {
                    // Large codec allocations have just been freed. Return unused
                    // allocator pages before another image starts; active buffers
                    // (including another worker's) remain owned and untouched.
                    _ = malloc_zone_pressure_relief(nil, 0)
                }
                Task(priority: .userInitiated) {
                    await self.finished(id, generation: generation, outcome: outcome)
                }
            }
            await send([.updated(entry.job)])
        }
    }

    // Keep Swift-owned image buffers in a synchronous call frame. The blocking
    // worker must release them, as well as autoreleased objects, before handing
    // its reservation back to the scheduler.
    @inline(never)
    private nonisolated static func prepare(job: ImageJob, processor: any ImageProcessing,
                                           fingerprint: FileFingerprint, digest: Data,
                                           info: ImageInfo, token: CancellationToken) throws -> Prepared {
        try token.check()
        let directory = try SafeFiles.workDirectory()
        var transferred = false
        var publication: SafeFiles.Publication?
        defer {
            if !transferred {
                if let publication { try? FileManager.default.removeItem(at: publication.stage) }
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let snapshot = try SafeFiles.snapshot(source: job.sourceURL, expected: fingerprint, directory: directory, expectedDigest: digest)
        try token.check()
        let stableInfo = try processor.inspect(snapshot)
        try SafeFiles.validateInfo(stableInfo)
        guard stableInfo.format == info.format, stableInfo.width == info.width,
              stableInfo.height == info.height, stableInfo.hasAlpha == info.hasAlpha else {
            throw ProcessingError.changedSource
        }
        let candidate = try processor.optimize(source: snapshot, workDirectory: directory,
                                               settings: job.settings, cancellation: token)
        try token.check()
        if let candidate {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(directory.path + "/"), resolved != snapshot,
                  try SafeFiles.fingerprint(resolved).bytes < fingerprint.bytes else {
                throw ProcessingError.invalid(String(localized: "The optimizer produced an invalid result."))
            }
            let candidateInfo = try processor.inspect(resolved)
            guard candidateInfo.format == info.format, candidateInfo.width == info.width,
                  candidateInfo.height == info.height,
                  // GIF delta frames may introduce transparent palette entries even
                  // when the composited animation stays opaque. GIFProcessor already
                  // validates every rendered pixel with gifdiff before returning it.
                  info.format == .gif || candidateInfo.hasAlpha == info.hasAlpha else {
                throw ProcessingError.invalid(String(localized: "The result does not preserve the image properties."))
            }
            publication = try SafeFiles.preparePublication(candidate: resolved, original: job.sourceURL,
                                                           settings: job.settings, workDirectory: directory,
                                                           cancellation: token)
        }
        try token.check()
        transferred = true
        return Prepared(candidate: candidate, directory: directory, info: stableInfo, publication: publication)
    }

    private func finished(_ id: UUID, generation: UUID, outcome: Result<Prepared, any Error>) async {
        let directory = try? outcome.get().directory
        let stage = try? outcome.get().publication?.stage
        let cleanup = {
            if let stage { try? FileManager.default.removeItem(at: stage) }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        running.removeValue(forKey: id)
        guard var entry = entries[id], entry.generation == generation else { cleanup(); await schedule(); return }
        if entry.token.isCancelled {
            entry.job.state = .cancelled
            entry.job.message = nil
        } else {
            do {
                let prepared = try outcome.get()
                if let publication = prepared.publication {
                    // There is deliberately no await between cancellation and atomic publication.
                    guard let fingerprint = entry.fingerprint, let digest = entry.digest else {
                        throw ProcessingError.changedSource
                    }
                    let output = try SafeFiles.publish(publication, original: entry.job.sourceURL, format: prepared.info.format,
                                                      expectedSource: .init(fingerprint: fingerprint, digest: digest))
                    entry.job.resultURL = output
                    entry.job.resultBytes = publication.fingerprint.bytes
                    entry.job.state = .optimized
                    producedPaths.insert(output.path)
                    producedIdentities.insert(publication.fingerprint.identity)
                } else {
                    entry.job.state = .unchanged
                    entry.job.resultBytes = entry.job.originalBytes
                }
            } catch {
                entry.job.state = Self.failureState(error)
                entry.job.message = error.localizedDescription
            }
        }
        cleanup()
        entries[id] = entry
        await send([.updated(entry.job)])
        await schedule()
    }

    func cancelAll() async {
        var changed: [ImageJob] = []
        for id in order {
            guard var entry = entries[id], !entry.job.state.isFinished else { continue }
            entry.token.cancel()
            // A running C operation may still be unwinding. Keep it active until cleanup finishes.
            if entry.job.state == .queued { entry.job.state = .cancelled }
            entries[id] = entry
            changed.append(entry.job)
        }
        await send(changed.map { .updated($0) })
    }

    func clearFinished() async {
        let finished = order.filter { entries[$0]?.job.state.isFinished == true && running[$0] == nil }
        let finishedIDs = Set(finished)
        for id in finished { entries.removeValue(forKey: id) }
        order.removeAll { finishedIDs.contains($0) }
        await send(finished.map { .removed($0) })
    }

    private nonisolated static func failureState(_ error: any Error) -> JobState {
        if error is CancellationError { return .cancelled }
        if case ProcessingError.unsupported = error { return .unsupported }
        if case ProcessingError.resourceLimit = error { return .unsupported }
        return .failed
    }
}
