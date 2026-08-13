import Foundation

/// How much a single refresh is allowed to read.
///
/// The listing is already windowed (mtime + 36h slack), so a typical refresh
/// is hundreds of megabytes, not the multi-gigabyte archive. The budget still
/// exists so one pathological transcript cannot freeze the popover.
nonisolated struct CostScanBudgetOptions: Sendable {
    /// 256 MiB. Caps the damage one pathological transcript can do: without it a
    /// single multi-gigabyte `.jsonl` would consume an entire refresh and starve
    /// every other file behind it, so the newest-first ordering would stop
    /// buying anything.
    var maxBytesPerFile: Int

    /// 512 MiB. The whole-refresh ceiling, and the knob that actually sets the
    /// slice length — roughly a second of warm sequential reads on an internal
    /// SSD. Raising it makes a cold start converge in fewer passes at the cost
    /// of a longer stretch with the scan queue busy.
    var maxNewBytesPerRefresh: Int

    /// Wall-clock ceiling, in seconds. Bytes are a poor proxy for time on a
    /// spinning disk, an encrypted external volume, or a machine under memory
    /// pressure, so this bounds the slice even when the byte budget is nowhere
    /// near spent. `nil` disables it.
    var wallClock: TimeInterval?

    init(maxBytesPerFile: Int, maxNewBytesPerRefresh: Int, wallClock: TimeInterval?) {
        self.maxBytesPerFile = maxBytesPerFile
        self.maxNewBytesPerRefresh = maxNewBytesPerRefresh
        self.wallClock = wallClock
    }

    /// The only options production uses. The scan is never unbounded in the app.
    static let `default` = CostScanBudgetOptions(
        maxBytesPerFile: 256 * 1024 * 1024,
        maxNewBytesPerRefresh: 512 * 1024 * 1024,
        wallClock: 15
    )

    /// Tests only — fixtures are a few hundred bytes, and a test that asserts on
    /// a whole corpus must not depend on how the production slice happens to
    /// fall. Never use this from app code.
    static let unlimited = CostScanBudgetOptions(
        maxBytesPerFile: .max,
        maxNewBytesPerRefresh: .max,
        wallClock: nil
    )

    var isUnbounded: Bool {
        maxBytesPerFile == .max && maxNewBytesPerRefresh == .max && wallClock == nil
    }
}

/// Tracks one refresh's spend against `CostScanBudgetOptions`.
///
/// A reference type because the scan threads it through per-file helpers that
/// are already at SwiftLint's `function_parameter_count` limit; passing it
/// `inout` alongside the accumulators would push several of them over.
nonisolated final class CostScanBudget: @unchecked Sendable {
    let options: CostScanBudgetOptions
    private let token: CostScanCancellationToken
    private let deadline: Date?
    private let lock = NSLock()
    private var spent = 0

    init(
        options: CostScanBudgetOptions,
        token: CostScanCancellationToken = .never,
        startedAt: Date = Date()
    ) {
        self.options = options
        self.token = token
        self.deadline = options.wallClock.map { startedAt.addingTimeInterval($0) }
    }

    /// Bytes actually pulled off disk this refresh — cached files contribute
    /// nothing, which is the whole point of the per-file offsets.
    var bytesRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return spent
    }

    var isCancelled: Bool { token.isCancelled }

    var isExhausted: Bool { allowance == 0 }

    /// The most the next file may read: whichever of the per-file cap and the
    /// refresh remainder is smaller, and zero once time is up or the refresh was
    /// cancelled.
    var allowance: Int {
        guard !token.isCancelled else { return 0 }
        if let deadline, Date() >= deadline { return 0 }
        guard options.maxNewBytesPerRefresh != .max else { return options.maxBytesPerFile }

        lock.lock()
        let remaining = max(0, options.maxNewBytesPerRefresh - spent)
        lock.unlock()
        return min(options.maxBytesPerFile, remaining)
    }

    func consume(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        // Saturating: an unbounded refresh reading a huge corpus must not trap
        // on overflow just because nothing was ever going to check the total.
        spent = spent.addingReportingOverflow(bytes).overflow ? .max : spent + bytes
        lock.unlock()
    }
}
