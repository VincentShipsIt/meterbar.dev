import XCTest
@testable import MeterBar

final class AdaptiveRefreshCadenceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testRecentQuotaMovementEscalatesToFastBound() {
        let decision = makeEngine().decision(
            signals: signals(lastQuotaMovementAt: now.addingTimeInterval(-30))
        )

        XCTAssertEqual(decision.interval, 60)
        XCTAssertEqual(decision.reason, .recentQuotaMovement)
    }

    func testRecentMeterBarInteractionEscalatesTowardFastBound() {
        let decision = makeEngine().decision(
            signals: signals(lastInteractionAt: now.addingTimeInterval(-30))
        )

        XCTAssertEqual(decision.interval, 120)
        XCTAssertEqual(decision.reason, .recentInteraction)
    }

    func testIdleSignalsBackOffToSlowBound() {
        let decision = makeEngine().decision(signals: signals())

        XCTAssertEqual(decision.interval, 1_800)
        XCTAssertEqual(decision.reason, .idle)
    }

    func testStaleActivitySignalsAreTreatedAsIdle() {
        let decision = makeEngine().decision(
            signals: signals(
                lastInteractionAt: now.addingTimeInterval(-601),
                lastQuotaMovementAt: now.addingTimeInterval(-601)
            )
        )

        XCTAssertEqual(decision.interval, 1_800)
        XCTAssertEqual(decision.reason, .idle)
    }

    func testBatteryPowerBiasesActiveCadenceTowardSlowBound() {
        let decision = makeEngine().decision(
            signals: signals(
                lastQuotaMovementAt: now,
                power: AdaptiveRefreshPowerState(
                    isOnBattery: true,
                    isLowPowerModeEnabled: false,
                    thermalState: .nominal
                )
            )
        )

        XCTAssertEqual(decision.interval, 600)
        XCTAssertEqual(decision.reason, .batteryPower)
    }

    func testLowPowerModeBiasesFurtherThanBatteryPower() {
        let decision = makeEngine().decision(
            signals: signals(
                lastQuotaMovementAt: now,
                power: AdaptiveRefreshPowerState(
                    isOnBattery: true,
                    isLowPowerModeEnabled: true,
                    thermalState: .nominal
                )
            )
        )

        XCTAssertEqual(decision.interval, 900)
        XCTAssertEqual(decision.reason, .lowPowerMode)
    }

    func testElevatedThermalStateBiasesTowardSlowBound() {
        let fair = makeEngine().decision(
            signals: signals(
                lastQuotaMovementAt: now,
                power: AdaptiveRefreshPowerState(
                    isOnBattery: false,
                    isLowPowerModeEnabled: false,
                    thermalState: .fair
                )
            )
        )
        let serious = makeEngine().decision(
            signals: signals(
                lastQuotaMovementAt: now,
                power: AdaptiveRefreshPowerState(
                    isOnBattery: false,
                    isLowPowerModeEnabled: false,
                    thermalState: .serious
                )
            )
        )

        XCTAssertEqual(fair.interval, 900)
        XCTAssertEqual(fair.reason, .thermalPressure)
        XCTAssertEqual(serious.interval, 1_800)
        XCTAssertEqual(serious.reason, .thermalPressure)
    }

    func testEverySignalCombinationIsClampedToInjectedBounds() {
        let engine = AdaptiveRefreshCadenceEngine(
            bounds: AdaptiveRefreshBounds(fastest: 90, slowest: 900),
            now: { self.now }
        )

        let active = engine.decision(signals: signals(lastQuotaMovementAt: now))
        let idle = engine.decision(signals: signals())

        XCTAssertEqual(active.interval, 90)
        XCTAssertEqual(idle.interval, 900)
    }

    func testPopoverOpenAndManualRefreshBypassCadence() {
        let engine = makeEngine()
        let idle = signals()

        let popover = engine.decision(signals: idle, trigger: .popoverOpened)
        let manual = engine.decision(signals: idle, trigger: .manualRefresh)

        XCTAssertEqual(popover.interval, 0)
        XCTAssertEqual(popover.reason, .popoverOpened)
        XCTAssertEqual(manual.interval, 0)
        XCTAssertEqual(manual.reason, .manualRefresh)
    }

    func testQuotaSnapshotDetectsOnlyMovementInExistingWindows() {
        let prior = AdaptiveQuotaSnapshot(values: ["cursor.weekly": 10])

        XCTAssertTrue(prior.hasMovement(comparedTo: AdaptiveQuotaSnapshot(values: ["cursor.weekly": 11])))
        XCTAssertFalse(prior.hasMovement(comparedTo: AdaptiveQuotaSnapshot(values: ["cursor.weekly": 10])))
        XCTAssertFalse(prior.hasMovement(comparedTo: AdaptiveQuotaSnapshot(values: ["new.window": 50])))
    }

    private func makeEngine() -> AdaptiveRefreshCadenceEngine {
        AdaptiveRefreshCadenceEngine(now: { self.now })
    }

    private func signals(
        lastInteractionAt: Date? = nil,
        lastQuotaMovementAt: Date? = nil,
        power: AdaptiveRefreshPowerState = .unconstrained
    ) -> AdaptiveRefreshSignals {
        AdaptiveRefreshSignals(
            lastInteractionAt: lastInteractionAt,
            lastQuotaMovementAt: lastQuotaMovementAt,
            power: power
        )
    }
}
