import Foundation

/// Bounded, order-preserving fan-out for the per-file half of a cost scan.
///
/// Both scanners walk thousands of transcripts and parse each one in complete
/// isolation, so the *parse* is embarrassingly parallel. The *fold* is not:
/// `ClaudeSessionTotals` sums `Double` costs (floating-point addition is not
/// associative) and `CodexScanContext` deduplicates first-event-wins, so a
/// different arrival order is a different answer. Parsing concurrently while
/// handing results back strictly in input order keeps the output identical to
/// the sequential scan, bit for bit.
///
/// The scanners stay synchronous rather than becoming `async`:
/// `CostSummaryBuilder.makeSummary` calls them straight through, already off the
/// main actor inside `CostTracker`'s `Task.detached`, and an `async` signature
/// would push that hop up into every caller.
nonisolated enum CostScanParallel {
    /// One worker per core. The scan is file I/O plus JSON parsing, so
    /// oversubscribing buys nothing, and every in-flight file holds a
    /// `FileLineReader` chunk resident.
    static var defaultWidth: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// How far ahead of the fold the workers may run, as a multiple of the
    /// width. Peak memory is `width × lookaheadMultiplier` parsed results plus
    /// `width` reader chunks — bounded, rather than "one parsed result per file
    /// in the tree".
    private static let lookaheadMultiplier = 4

    /// Runs `parse` over `inputs` — at most `width` at a time — and calls
    /// `fold` once per input, on the calling thread, in input order.
    ///
    /// `parse` escapes onto the worker queue, so it must be `@Sendable`.
    /// `fold` is deliberately neither: it runs serially on the caller's thread,
    /// which is what lets it capture and mutate an `inout` accumulator.
    static func parseInOrder<Input: Sendable, Parsed: Sendable>(
        _ inputs: [Input],
        width: Int,
        parse: @escaping @Sendable (Input) -> Parsed,
        fold: (Parsed) -> Void
    ) {
        let width = max(1, width)
        guard width > 1, inputs.count > 1 else {
            for input in inputs {
                fold(parse(input))
            }
            return
        }

        // A pipeline rather than parse-a-batch/fold-a-batch. Transcript sizes
        // are wildly skewed — a handful carry base64 payloads orders of
        // magnitude larger than the median — so any batch barrier parks the
        // whole pool behind one giant file. Here a straggler only stalls the
        // fold; the other workers keep pulling files until they are
        // `lookahead` results ahead, which is also what bounds memory.
        let pipeline = ParsePipeline<Parsed>(
            count: inputs.count,
            lookahead: width * Self.lookaheadMultiplier
        )
        let queue = DispatchQueue(
            label: "dev.meterbar.cost-scan.parse",
            qos: .utility,
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for _ in 0..<min(width, inputs.count) {
            queue.async(group: group) {
                while let index = pipeline.claim() {
                    pipeline.deliver(parse(inputs[index]), at: index)
                }
            }
        }

        for index in 0..<inputs.count {
            // `take` blocks until index `index` has been parsed, so the fold
            // sees exactly the sequential order. The optional is a formality —
            // it only returns after the slot is filled — but it keeps this
            // free of a force-unwrap.
            guard let parsed = pipeline.take(index) else { continue }
            fold(parsed)
        }
        group.wait()
    }
}

/// Work queue and ordered hand-off between the parsing workers and the folding
/// caller.
///
/// `@unchecked Sendable` over a lock matches the existing pattern in `WakeLock`,
/// `ManagedProcess.BoundedSink`, and `ServeRateLimiter`; this one uses
/// `NSCondition` because both sides need to block — workers on the lookahead
/// limit, the folder on the next result.
nonisolated private final class ParsePipeline<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [Value?]
    private var nextClaim = 0
    private var nextFold = 0
    private let lookahead: Int

    init(count: Int, lookahead: Int) {
        values = Array(repeating: nil, count: count)
        self.lookahead = max(1, lookahead)
    }

    /// The next unclaimed index, or `nil` once every input has been handed out.
    ///
    /// Blocks while the workers are already `lookahead` results ahead of the
    /// fold, which is what keeps parsed results from piling up faster than they
    /// are consumed.
    func claim() -> Int? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            guard nextClaim < values.count else { return nil }
            if nextClaim < nextFold + lookahead {
                let index = nextClaim
                nextClaim += 1
                return index
            }
            condition.wait()
        }
    }

    func deliver(_ value: Value, at index: Int) {
        condition.lock()
        defer { condition.unlock() }
        values[index] = value
        condition.broadcast()
    }

    /// Waits for index `index` to be parsed, then removes it.
    ///
    /// Dropping the reference here rather than at the end of the scan is what
    /// makes the lookahead a real memory bound: a folded result is released
    /// immediately instead of being retained until the last file is done.
    ///
    /// Cannot deadlock: the folder only waits on the index it is folding, and
    /// that index is always inside the lookahead window (`nextFold + lookahead`
    /// is strictly greater than `nextFold`), so a worker is always free to
    /// claim it.
    func take(_ index: Int) -> Value? {
        condition.lock()
        defer { condition.unlock() }

        while values[index] == nil {
            condition.wait()
        }
        let value = values[index]
        values[index] = nil
        nextFold = index + 1
        condition.broadcast()
        return value
    }
}
