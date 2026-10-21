import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var jobs: [ImageJob] = []
    private(set) var pendingAdmissions = 0
    private(set) var completedCount = 0
    private(set) var excludedCount = 0
    private(set) var cancelledCount = 0
    private(set) var failedCount = 0
    private(set) var finishedCount = 0
    private(set) var savedBytes: Int64 = 0
    @ObservationIgnored private var jobIndices: [UUID: Int] = [:]
    private var pendingDrops: [UUID: OptimizationSettings] = [:]
    @ObservationIgnored private var admissionGeneration = UUID()
    @ObservationIgnored private var pendingCancellation: Task<Void, Never>?
    var settings: OptimizationSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let processor: any ImageProcessing
    @ObservationIgnored private lazy var coordinator = QueueCoordinator(processor: processor) { [weak self] event in
        await self?.receive(event)
    }
    private static let settingsKey = "Resim.optimizationSettings.v1"

    init(processor: any ImageProcessing = NativeImageProcessor(), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.processor = processor
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(OptimizationSettings.self, from: data) {
            settings = saved
        } else {
            settings = OptimizationSettings()
        }
        Task.detached(priority: .utility) { SafeFiles.cleanAbandonedWork() }
    }

    var totalCount: Int { jobs.count }
    var hasActiveJobs: Bool { !pendingDrops.isEmpty || pendingAdmissions > 0 || finishedCount < jobs.count }
    var progress: Double { jobs.isEmpty ? 0 : Double(finishedCount) / Double(jobs.count) }

    func addURLs(_ urls: [URL]) {
        addURLs(urls, settings: settings)
    }

    /// A Finder gesture owns its pending providers and its admission preferences.
    /// Cancelling invalidates the gesture without waiting for an external provider.
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let id = UUID()
        pendingDrops[id] = settings
        let accepted = FileURLDropReader.receive(providers, onReceive: { [weak self] url in
            guard let self, let captured = self.pendingDrops[id] else { return }
            self.addURLs([url], settings: captured)
        }, onComplete: { [weak self] in
            self?.pendingDrops.removeValue(forKey: id)
        })
        if !accepted { pendingDrops.removeValue(forKey: id) }
        return accepted
    }

    private func addURLs(_ urls: [URL], settings captured: OptimizationSettings) {
        guard !urls.isEmpty else { return }
        let generation = admissionGeneration
        let cancellation = pendingCancellation
        pendingAdmissions += 1
        Task {
            defer { pendingAdmissions -= 1 }
            await cancellation?.value
            guard generation == admissionGeneration else { return }
            await coordinator.addURLs(urls, settings: captured)
        }
    }

    func cancelAll() {
        pendingDrops.removeAll()
        admissionGeneration = UUID()
        let previous = pendingCancellation
        let coordinator = coordinator
        pendingCancellation = Task {
            await previous?.value
            await coordinator.cancelAll()
        }
    }

    /// A retry is a new admission and captures current preferences, including a corrected destination.
    func retry(_ id: UUID) {
        let captured = settings
        let generation = admissionGeneration
        let cancellation = pendingCancellation
        pendingAdmissions += 1
        Task {
            defer { pendingAdmissions -= 1 }
            await cancellation?.value
            guard generation == admissionGeneration else { return }
            await coordinator.retry(id, settings: captured)
        }
    }

    func clearFinished() { Task { await coordinator.clearFinished() } }

    private func receive(_ event: QueueEvent) {
        switch event {
        case .updated(let job):
            if let index = jobIndices[job.id] {
                updateTotals(for: jobs[index], direction: -1)
                jobs[index] = job
            } else {
                jobIndices[job.id] = jobs.count
                jobs.append(job)
            }
            updateTotals(for: job, direction: 1)
        case .removed(let id):
            guard let index = jobIndices.removeValue(forKey: id) else { return }
            updateTotals(for: jobs[index], direction: -1)
            jobs.remove(at: index)
            for position in index..<jobs.count { jobIndices[jobs[position].id] = position }
        }
    }

    /// Each queue event replaces one contribution; reads never scan the batch.
    private func updateTotals(for job: ImageJob, direction: Int) {
        switch job.state {
        case .optimized, .unchanged: completedCount += direction
        case .unsupported: excludedCount += direction
        case .cancelled: cancelledCount += direction
        case .failed: failedCount += direction
        case .queued, .running: break
        }
        if job.state.isFinished { finishedCount += direction }
        savedBytes += Int64(direction) * job.savedBytes
    }
}
