import XCTest
import MeterBarShared
@testable import MeterBar

/// Codex serves requests from a reserve pool once a plan's own quota is spent,
/// and reports it in `additional_rate_limits` (issue #578). These tests pin the
/// gate — the row exists only while the reserve is actually serving — and the
/// naming, which is derived from provider fields rather than hardcoded.
///
/// The fixtures below are trimmed from a live `wham/usage` response captured on
/// a Pro account whose weekly window was exhausted.
final class CodexLunaReserveTests: XCTestCase {
    private func decode(_ json: String) throws -> CodexCliUsageResponse {
        try JSONDecoder().decode(CodexCliUsageResponse.self, from: Data(json.utf8))
    }

    /// The reserve entry as OpenAI reports it, at `usedPercent` consumed.
    private func reserveEntry(usedPercent: Double = 0, modelSlug: String = "gpt-5.6-luna") -> String {
        """
        {
            "limit_name": "gpt-reserve",
            "metered_feature": "base_model_inference",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": \(usedPercent),
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 603930,
                    "reset_at": 1789544684
                },
                "secondary_window": null
            },
            "normal_model_slug": "\(modelSlug)"
        }
        """
    }

    /// The deprecated Codex Spark pool, which shares the array with the reserve
    /// and must not be mistaken for it.
    private var sparkEntry: String {
        """
        {
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "codex_bengalfox",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 18000,
                    "reset_at": 1788958754
                },
                "secondary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 604800,
                    "reset_at": 1789545554
                }
            },
            "normal_model_slug": null
        }
        """
    }

    /// `limitReached` drives the weekly window; `upsell` is the banner OpenAI
    /// attaches while the reserve is serving.
    private func payload(
        limitReached: Bool,
        upsell: String?,
        additional: [String]
    ) -> String {
        let upsellField = upsell.map { ", \"rate_limit_upsell\": { \"banner_type\": \"\($0)\" }" } ?? ""
        return """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": \(limitReached ? "false" : "true"),
                "limit_reached": \(limitReached),
                "primary_window": {
                    "used_percent": \(limitReached ? 100 : 40),
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 506362,
                    "reset_at": 1789447116
                },
                "secondary_window": null
            },
            "additional_rate_limits": [\(additional.joined(separator: ","))]\(upsellField)
        }
        """
    }

    // MARK: - The gate

    func testSurfacesReserveWhileTheUpsellBannerIsPresent() throws {
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [sparkEntry, reserveEntry()]
        )).toUsageMetrics()

        let reserve = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(metrics.additionalLimits.count, 1, "Only the reserve maps; Spark is deprecated.")
        XCTAssertEqual(reserve.label, "Luna Reserve")
        XCTAssertEqual(reserve.used, 0)
        XCTAssertEqual(reserve.total, 100)
        XCTAssertEqual(reserve.windowSeconds, 604_800)
        XCTAssertEqual(reserve.periodKind, .weekly)
        XCTAssertEqual(reserve.resetTime, Date(timeIntervalSince1970: 1_789_544_684))
        XCTAssertFalse(reserve.isEstimated)
    }

    /// The banner is marketing copy and can be withdrawn; the exhausted window
    /// is the condition the reserve exists for, so it stands on its own.
    func testSurfacesReserveOnAnExhaustedWindowWithNoBanner() throws {
        let metrics = try decode(payload(
            limitReached: true,
            upsell: nil,
            additional: [reserveEntry()]
        )).toUsageMetrics()

        XCTAssertEqual(metrics.additionalLimits.first?.label, "Luna Reserve")
    }

    /// The reserve is reported whether or not it is serving. A full bar next to
    /// a healthy weekly one is noise, so it stays hidden until the plan's own
    /// quota is gone — the behaviour this feature was asked for.
    func testHidesReserveWhileThePlanWindowStillHasQuota() throws {
        let metrics = try decode(payload(
            limitReached: false,
            upsell: nil,
            additional: [sparkEntry, reserveEntry()]
        )).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertEqual(metrics.weeklyLimit?.used, 40, "The plan's own window is unaffected.")
    }

    func testReportsPartiallyConsumedReserve() throws {
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [reserveEntry(usedPercent: 37.5)]
        )).toUsageMetrics()

        let reserve = try XCTUnwrap(metrics.additionalLimits.first)
        XCTAssertEqual(reserve.used, 37.5)
        XCTAssertEqual(QuotaMath.percentLeft(for: reserve), 63)
    }

    // MARK: - Payload tolerance

    /// The array is undocumented. A shape MeterBar cannot read costs it the
    /// row, never the rest of the usage decode.
    func testOmittedAdditionalRateLimitsLeaveTheRestOfTheDecodeIntact() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 506362,
                    "reset_at": 1789447116
                },
                "secondary_window": null
            }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
        XCTAssertEqual(metrics.weeklyLimit?.used, 100)
    }

    func testIgnoresAnAdditionalLimitThatIsNotTheReserve() throws {
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [sparkEntry]
        )).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    /// A reserve reported without a usable window is dropped rather than drawn
    /// as an empty bar.
    func testIgnoresAReserveWithNoRateLimit() throws {
        let entry = """
        {
            "limit_name": "gpt-reserve",
            "metered_feature": "base_model_inference",
            "rate_limit": null,
            "normal_model_slug": "gpt-5.6-luna"
        }
        """
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [entry]
        )).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    /// A pool MeterBar ignores must not be able to blank the Codex card. Before
    /// `additional_rate_limits` was read at all, a Spark shape change was
    /// harmless; reading the array must not make things worse.
    func testAMalformedNeighbouringPoolDoesNotCostTheReserveOrTheDecode() throws {
        let brokenSpark = """
        {
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "codex_bengalfox",
            "rate_limit": { "allowed": "yes", "primary_window": "gone" }
        }
        """
        // A pool that is not even an object is the shape a per-element decode
        // has to survive: a throw mid-array leaves the container index put.
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [brokenSpark, "\"not-a-pool\"", reserveEntry()]
        )).toUsageMetrics()

        XCTAssertEqual(metrics.weeklyLimit?.used, 100)
        XCTAssertEqual(metrics.additionalLimits.first?.label, "Luna Reserve")
    }

    /// A retyped field on the reserve itself costs only that field. The pool is
    /// still identified by `metered_feature` and still named by its slug.
    func testARetypedFieldOnTheReserveDoesNotDropIt() throws {
        let entry = """
        {
            "limit_name": 42,
            "metered_feature": "base_model_inference",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 603930,
                    "reset_at": 1789544684
                }
            },
            "normal_model_slug": "gpt-5.6-luna"
        }
        """
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [entry]
        )).toUsageMetrics()

        XCTAssertEqual(metrics.additionalLimits.first?.label, "Luna Reserve")
    }

    /// The whole field changing shape — an object where an array was — costs
    /// the row and nothing else.
    func testAnAdditionalRateLimitsFieldThatIsNotAnArrayIsIgnored() throws {
        let json = """
        {
            "plan_type": "pro",
            "rate_limit": {
                "allowed": false,
                "limit_reached": true,
                "primary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 506362,
                    "reset_at": 1789447116
                }
            },
            "additional_rate_limits": { "unexpected": true },
            "rate_limit_upsell": { "banner_type": 7 }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertEqual(metrics.weeklyLimit?.used, 100)
        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    /// Free accounts carry a null `rate_limit`, and the upsell banner is then
    /// the only signal that a reserve is serving.
    func testSurfacesReserveOnAnAccountWithNoPlanWindows() throws {
        let json = """
        {
            "plan_type": "free",
            "rate_limit": null,
            "additional_rate_limits": [\(reserveEntry())],
            "rate_limit_upsell": { "banner_type": "luna_reserve" }
        }
        """

        let metrics = try decode(json).toUsageMetrics()

        XCTAssertNil(metrics.weeklyLimit)
        XCTAssertEqual(metrics.additionalLimits.first?.label, "Luna Reserve")
    }

    /// A short reserve window is reported as a session cadence, so pace copy
    /// and CLI `kind` do not call a five-hour pool weekly.
    func testDerivesCadenceFromTheReportedWindowLength() throws {
        let entry = """
        {
            "limit_name": "gpt-reserve",
            "metered_feature": "base_model_inference",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 10,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 1000,
                    "reset_at": 1789544684
                }
            },
            "normal_model_slug": "gpt-5.6-luna"
        }
        """
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [entry]
        )).toUsageMetrics()

        XCTAssertEqual(metrics.additionalLimits.first?.periodKind, .session)
    }

    // MARK: - Naming

    /// The name follows the provider. "Luna Reserve" is not a literal in the
    /// payload, so a model swap must rename the row without a MeterBar release.
    func testNamesTheReserveAfterTheModelItServes() {
        XCTAssertEqual(
            CodexReserveLabel.make(modelSlug: "gpt-5.6-luna", limitName: "gpt-reserve"),
            "Luna Reserve"
        )
        XCTAssertEqual(
            CodexReserveLabel.make(modelSlug: "gpt-7-terra", limitName: "gpt-reserve"),
            "Terra Reserve"
        )
    }

    /// A slug with no family word falls back to the provider's internal name
    /// rather than inventing one.
    func testFallsBackToTheLimitNameWhenTheSlugNamesNoFamily() {
        XCTAssertEqual(CodexReserveLabel.make(modelSlug: "gpt-5.6", limitName: "gpt-reserve"), "GPT Reserve")
        XCTAssertEqual(CodexReserveLabel.make(modelSlug: nil, limitName: "gpt-reserve"), "GPT Reserve")
        XCTAssertEqual(CodexReserveLabel.make(modelSlug: nil, limitName: "backup-pool"), "Backup Pool Reserve")
    }

    func testYieldsNoNameWhenNeitherFieldNamesThePool() {
        XCTAssertNil(CodexReserveLabel.make(modelSlug: nil, limitName: nil))
        XCTAssertNil(CodexReserveLabel.make(modelSlug: "5.6", limitName: nil))
    }

    /// An unnameable reserve is dropped: a bar titled "Weekly" beside the
    /// plan's own weekly bar tells the user nothing about which pool is serving.
    func testDropsAReserveThatCannotBeNamed() throws {
        let entry = """
        {
            "metered_feature": "base_model_inference",
            "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                    "used_percent": 0,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 603930,
                    "reset_at": 1789544684
                }
            }
        }
        """
        let metrics = try decode(payload(
            limitReached: true,
            upsell: "luna_reserve",
            additional: [entry]
        )).toUsageMetrics()

        XCTAssertTrue(metrics.additionalLimits.isEmpty)
    }

    // MARK: - Presentation

    func testTitlesTheRowFromTheProviderLabelInEveryLocale() {
        let reserve = UsageLimit(
            used: 0,
            total: 100,
            resetTime: nil,
            windowSeconds: 604_800,
            periodKind: .weekly,
            label: "Luna Reserve"
        )

        let key = ServiceType.codexCli.additionalQuotaTitleKey(for: reserve)

        XCTAssertEqual(key, .model(label: "Luna Reserve"))
        XCTAssertEqual(key.englishTitle, "Luna Reserve")
        XCTAssertEqual(LocalizedUsageFormat.quotaTitle(for: key), "Luna Reserve")
    }

    /// Without the label the same weekly window would title as "Weekly" — the
    /// duplicate this routing exists to prevent.
    func testAnUnlabelledWeeklyWindowStillTitlesByCadence() {
        let plain = UsageLimit(used: 0, total: 100, resetTime: nil, periodKind: .weekly)

        XCTAssertEqual(ServiceType.codexCli.additionalQuotaTitleKey(for: plain), .weekly)
    }

    /// Pin keys are compared by exact string equality, and the reserve row comes
    /// and goes with the plan's quota. A positional id would strand a pin the
    /// user set while the row was showing.
    func testGivesTheReserveRowAnIdThatDoesNotDependOnItsPosition() {
        let reserve = UsageLimit(
            used: 0,
            total: 100,
            resetTime: nil,
            windowSeconds: 604_800,
            periodKind: .weekly,
            label: "Luna Reserve"
        )
        let metrics = UsageMetrics(
            service: .codexCli,
            weeklyLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
            additionalLimits: [reserve]
        )

        let limits = ProviderSnapshotBuilder.limits(for: metrics, service: .codexCli)
        let row = limits.first { $0.kind == .additional }

        XCTAssertEqual(row?.id, "luna-reserve")
        XCTAssertEqual(row?.title, "Luna Reserve")
    }

    // MARK: - Persistence

    /// The label rides the shared cache, the widget payload and CloudKit
    /// records. Older payloads predate the field and must still decode.
    func testLabelSurvivesARoundTripAndOlderPayloadsStillDecode() throws {
        let reserve = UsageLimit(
            used: 12,
            total: 100,
            resetTime: Date(timeIntervalSince1970: 1_789_544_684),
            windowSeconds: 604_800,
            periodKind: .weekly,
            label: "Luna Reserve"
        )

        let encoded = try JSONEncoder().encode(reserve)
        let decoded = try JSONDecoder().decode(UsageLimit.self, from: encoded)
        XCTAssertEqual(decoded, reserve)
        XCTAssertEqual(decoded.label, "Luna Reserve")

        let legacy = #"{"used":12,"total":100,"isEstimated":false}"#
        let legacyDecoded = try JSONDecoder().decode(UsageLimit.self, from: Data(legacy.utf8))
        XCTAssertNil(legacyDecoded.label)
    }
}
