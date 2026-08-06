import Foundation

/// The one thread every cost scan runs on.
///
/// ## Why one serial queue and not a fan-out
///
/// The obvious "make the scan faster" change is to parallelize it — a
/// `TaskGroup` or `concurrentPerform` over the transcript files, one worker per
/// core. That is the wrong fix here, for two independent reasons:
///
/// 1. **The scan is disk-bound, not CPU-bound.** A working corpus is roughly
///    10 GB across ~10k `.jsonl` transcripts. Fanning reads out across cores
///    multiplies I/O contention — more seeks, more page-cache churn, more
///    read-ahead thrash — and buys no wall time back, because no core was ever
///    waiting on arithmetic.
/// 2. **It starves everything else.** Swift's cooperative pool has one thread
///    per core. A fan-out of blocking `read(2)` calls occupies all of them, so
///    every other `async` task in the app — menu rendering, provider polling,
///    status refreshes — queues behind a scan that is itself just waiting on the
///    disk. The symptom is the menu freezing while the main thread sits idle.
///
/// steipete/CodexBar hit exactly this and went the other way: its
/// `CostUsageScanExecutor` pins all cost scans to a single serial
/// `DispatchQueue` at `.utility` off the cooperative pool. This is the same
/// shape, for the same reason.
///
/// Wall time comes from `CostScanBudget` and the resumable byte offsets on
/// `CostScanFileCache` instead: a refresh reads only what was appended since the
/// last one, newest transcript first, and stops at a byte ceiling. That turns a
/// 70-second cold scan into bounded slices without touching a second core.
nonisolated enum CostScanExecutor {
    /// Serial, `.utility`, and deliberately *not* on the cooperative pool: a
    /// `DispatchQueue` thread is allowed to block in `read(2)` without costing
    /// the rest of the app a concurrency slot.
    private static let queue = DispatchQueue(label: "dev.meterbar.app.CostScan.io", qos: .utility)

    /// Runs `work` on the scan queue and bridges Swift task cancellation into it.
    ///
    /// Cancellation has two shapes, and both matter:
    /// - **Before the work starts** (still queued behind an in-flight scan) it
    ///   resumes immediately with `CancellationError` rather than waiting out the
    ///   scan ahead of it, and the closure never runs at all.
    /// - **While the work runs**, the token flips and the scan notices at its
    ///   next file boundary: it persists what it has read and returns. The caller
    ///   still sees `CancellationError`; the progress is already on disk.
    static func run<Value: Sendable>(
        _ work: @escaping @Sendable (CostScanCancellationToken) -> Value
    ) async throws -> Value {
        let handoff = CostScanHandoff<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.store(continuation)
                queue.async {
                    guard handoff.beginWork() else { return }
                    handoff.finish(work(handoff.token))
                }
            }
        } onCancel: {
            handoff.cancel()
        }
    }
}

/// A cancellation flag the scan can poll from a non-`async` context.
///
/// `Task.isCancelled` is meaningless inside a `DispatchQueue` block, so the
/// executor hands the work an explicit token instead.
nonisolated final class CostScanCancellationToken: @unchecked Sendable {
    /// For call sites that scan outside the executor — tests, and the unbounded
    /// convenience paths — where nothing can ever cancel.
    static let never = CostScanCancellationToken()

    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Guarantees the continuation handed to `CostScanExecutor.run` is resumed
/// exactly once, whichever of "cancelled" and "work finished" happens first.
private final class CostScanHandoff<Value: Sendable>: @unchecked Sendable {
    let token = CostScanCancellationToken()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settled = false

    /// Parks the continuation, or resumes it straight away when cancellation
    /// already arrived.
    ///
    /// The `isCancelled` check may not be qualified with `!settled`: `cancel()`
    /// running before `store()` finds no continuation to resume, so if `store()`
    /// then treated the call as already settled the continuation would be parked
    /// forever and the caller would hang.
    func store(_ continuation: CheckedContinuation<Value, Error>) {
        if token.isCancelled {
            continuation.resume(throwing: CancellationError())
            lock.lock()
            settled = true
            lock.unlock()
            return
        }
        lock.lock()
        if settled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// - Returns: `false` when the caller already gave up, so the queue can drop
    ///   the block instead of reading the corpus for a result nobody wants.
    func beginWork() -> Bool {
        !token.isCancelled
    }

    func finish(_ value: Value) {
        guard let continuation = take() else { return }
        continuation.resume(returning: value)
    }

    func cancel() {
        token.cancel()
        guard let continuation = take() else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return nil }
        settled = true
        let pending = continuation
        continuation = nil
        return pending
    }
}
