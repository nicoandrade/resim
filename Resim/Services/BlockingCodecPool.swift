import Foundation

/// Keep blocking codecs and their thread-local Image I/O caches on two fixed
/// operating-system threads rather than Swift's shared cooperative executor.
nonisolated final class BlockingCodecPool: @unchecked Sendable {
    typealias Job = @Sendable () -> Void

    private let state: State
    private let workers: [Thread]

    init() {
        let state = State()
        self.state = state
        workers = (1...2).map { number in
            // Capture only State: retaining the pool here would prevent deinit
            // from waking idle workers and allowing them to terminate.
            let thread = Thread { state.run() }
            thread.name = "com.resim.codec.\(number)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 4 * 1_024 * 1_024
            return thread
        }
        workers.forEach { $0.start() }
    }

    func submit(_ job: @escaping Job) { state.enqueue(job) }

    deinit {
        // No join: a codec may still be unwinding. State stays alive through its
        // worker closures until every accepted job is drained and both exit.
        state.stopAfterDraining()
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job?] = []
        private var first = 0
        private var stopping = false

        func enqueue(_ job: @escaping Job) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func stopAfterDraining() {
            condition.lock()
            stopping = true
            condition.broadcast()
            condition.unlock()
        }

        func run() {
            while runNextJob() {}
        }

        // A separate synchronous frame releases the Swift closure and all its
        // captures before the worker blocks waiting for another job.
        @inline(never)
        private func runNextJob() -> Bool {
            autoreleasepool {
                guard let job = nextJob() else { return false }
                job()
                return true
            }
        }

        private func nextJob() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while first == jobs.count && !stopping { condition.wait() }
            guard first < jobs.count else { return nil }
            let job = jobs[first]
            jobs[first] = nil
            first += 1
            if first == jobs.count {
                jobs.removeAll(keepingCapacity: true)
                first = 0
            } else if first >= 256 && first >= jobs.count / 2 {
                jobs.removeFirst(first)
                first = 0
            }
            return job
        }
    }
}
