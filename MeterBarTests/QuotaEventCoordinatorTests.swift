import Combine
import Foundation
import MeterBarShared
import XCTest
@testable import MeterBar

/// Issue #547 part 4: `evaluateCurrentSnapshot()` used to spawn a bare `Task`
/// on every fire of 15 merged publishers, with no guard against a prior
/// evaluation still being in flight — unlike its sibling
/// `ICloudUsageAggregationCoordinator`, which guards the identical shape with
/// `syncTask == nil`. These tests drive two merged-publisher fires that
/// genuinely overlap a suspended evaluation, not two sequential ones.
@MainActor
final class QuotaEventCoordinatorTests: XCTestCase {
    func testOverlappingPublisherFiresRunAtMostOneEvaluationAtATime() async {
        let providerVisibility = ProviderVisibilityStore(userDefaults: isolatedDefaults())
        let entered = expectation(description: "evaluation entered observe")
        let gate = EvaluationGate(entered: entered)

        let coordinator = QuotaEventCoordinator(
            dataManager: .shared,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: isolatedDefaults()),
            codexAccounts: CodexAccountStore(userDefaults: isolatedDefaults()),
            grokAccounts: GrokAccountStore(userDefaults: isolatedDefaults()),
            openRouterKeys: OpenRouterAccountStore(userDefaults: isolatedDefaults()),
            providerVisibility: providerVisibility,
            settings: QuotaEventSettingsStore(userDefaults: isolatedDefaults()),
            diagnostics: QuotaEventDiagnosticStore(capacity: 20),
            observe: { _, _ in
                await gate.wait()
                return QuotaEventObservation(events: [], diagnostics: [])
            }
        )

        coordinator.start()
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertNotNil(coordinator.evaluationTask, "start() must leave an evaluation in flight")

        // Two more merged-publisher fires land on the same synchronous call
        // stack, while the first evaluation is still suspended inside
        // `observe` — a genuine overlap, not a sequential replay.
        providerVisibility.set(.codexCli, isEnabled: false)
        providerVisibility.set(.codexCli, isEnabled: true)
        await Task.yield()

        let entryCountWhileSuspended = await gate.entryCount
        XCTAssertEqual(
            entryCountWhileSuspended, 1,
            "overlapping publisher fires must not start a second evaluation while one is in flight"
        )

        await gate.resume()
        await Task.yield()
        await Task.yield()

        XCTAssertNil(coordinator.evaluationTask, "the guard must clear once the in-flight evaluation finishes")
    }

    func testANewEvaluationCanStartOnceThePriorOneFinishes() async {
        let providerVisibility = ProviderVisibilityStore(userDefaults: isolatedDefaults())
        var entryCount = 0
        let firstEntered = expectation(description: "first evaluation entered")
        let secondEntered = expectation(description: "second evaluation entered")

        let coordinator = QuotaEventCoordinator(
            dataManager: .shared,
            claudeAccounts: ClaudeCodeAccountStore(userDefaults: isolatedDefaults()),
            codexAccounts: CodexAccountStore(userDefaults: isolatedDefaults()),
            grokAccounts: GrokAccountStore(userDefaults: isolatedDefaults()),
            openRouterKeys: OpenRouterAccountStore(userDefaults: isolatedDefaults()),
            providerVisibility: providerVisibility,
            settings: QuotaEventSettingsStore(userDefaults: isolatedDefaults()),
            diagnostics: QuotaEventDiagnosticStore(capacity: 20),
            observe: { _, _ in
                entryCount += 1
                if entryCount == 1 { firstEntered.fulfill() } else { secondEntered.fulfill() }
                return QuotaEventObservation(events: [], diagnostics: [])
            }
        )

        coordinator.start()
        await fulfillment(of: [firstEntered], timeout: 1)
        await Task.yield()
        await Task.yield()
        XCTAssertNil(coordinator.evaluationTask)

        providerVisibility.set(.codexCli, isEnabled: false)
        await fulfillment(of: [secondEntered], timeout: 1)

        XCTAssertEqual(entryCount, 2, "a fire after the prior evaluation finished must start a new one")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "QuotaEventCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// Suspends every `wait()` call until `resume()` runs, counting how many
/// evaluations actually entered `observe` — the guard's real job is to keep
/// this count from growing while one call is still suspended here.
private actor EvaluationGate {
    private(set) var entryCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private let entered: XCTestExpectation

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        entryCount += 1
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
