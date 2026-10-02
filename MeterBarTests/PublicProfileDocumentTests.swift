import MeterBarShared
import XCTest
@testable import MeterBar

/// The privacy contract of the public profile (#594): the document is built
/// from an allowlist, so what these tests pin is what can reach meterbar.dev.
final class PublicProfileDocumentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPublicRowsCollapseToWeeklyBlockAndDoNotPublishStaleReset() {
        let snapshot = ProviderSnapshotBuilder.snapshot(
            title: "private", service: .claudeCode,
            metrics: UsageMetrics(
                service: .claudeCode,
                sessionLimit: UsageLimit(
                    used: 20,
                    total: 100,
                    resetTime: now.addingTimeInterval(3600)
                ),
                weeklyLimit: UsageLimit(
                    used: 100,
                    total: 100,
                    resetTime: now.addingTimeInterval(-86400)
                ),
                codeReviewLimit: UsageLimit(used: 80, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            emptyDetail: ""
        )
        let provider = make(snapshots: [snapshot]).providers.first
        XCTAssertEqual(provider?.windows.map(\.label), ["Weekly"])
        XCTAssertEqual(provider?.primaryWindowIndex, 0)
        XCTAssertEqual(provider?.isBlocked, true)
        XCTAssertNil(provider?.windows.first?.resetsAt)
        XCTAssertNil(provider?.windows.first?.pace)
    }

    func testCursorSpilloverPrimaryAndSecondaryRolesReachPublicConsumers() {
        let cursor = ProviderSnapshotBuilder.snapshot(
            title: "private", service: .cursor,
            metrics: UsageMetrics(
                service: .cursor,
                sessionLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
                weeklyLimit: UsageLimit(used: 27, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            emptyDetail: ""
        )
        let provider = make(snapshots: [cursor]).providers.first
        XCTAssertEqual(provider?.windows.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(provider?.primaryWindowIndex, 1)
        XCTAssertEqual(provider?.isBlocked, false)

        let claude = ProviderSnapshotBuilder.snapshot(
            title: "private", service: .claudeCode,
            metrics: UsageMetrics(
                service: .claudeCode,
                weeklyLimit: UsageLimit(used: 20, total: 100, resetTime: nil),
                codeReviewLimit: UsageLimit(used: 100, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            emptyDetail: ""
        )
        let claudeProvider = make(snapshots: [claude]).providers.first
        XCTAssertEqual(claudeProvider?.primaryWindowIndex, 0)
        XCTAssertEqual(claudeProvider?.windows.map(\.role), ["provider", "secondary"])
        XCTAssertEqual(claudeProvider?.isBlocked, false)
    }

    func testCreditBalancesWithoutAnAllowanceDoNotInventAPublicPercentage() {
        for reading in [UsageLimit.Reading.remainder, .unlimited] {
            let snapshot = ProviderSnapshot(
                id: "credits", title: "private", service: .codexCli, updatedAt: now,
                limits: [SnapshotLimit(
                    id: "credits",
                    kind: .additional,
                    title: "Credits",
                    usageLimit: UsageLimit(used: 0, total: 400, resetTime: nil, reading: reading)
                )],
                emptyDetail: "", extraUsage: nil, resetCreditsAvailable: nil, accountID: nil
            )

            let doc = make(snapshots: [snapshot])

            XCTAssertTrue(doc.providers.isEmpty, "\(reading) has no public quota percentage")
        }
    }

    // MARK: - No personal data

    /// `ProviderSnapshot.title` is the user's own account label. It must never
    /// be read, however identifying it is.
    func testProviderIsNamedFromTheServiceNeverFromTheAccountTitle() {
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "vincent@acme-corp.com", service: .claudeCode),
        ])

        XCTAssertEqual(doc.providers.map(\.name), ["Claude Code"])
        XCTAssertFalse(doc.jsonString.contains("acme"))
        XCTAssertFalse(doc.jsonString.contains("vincent"))
    }

    func testSecondAccountOfOneProviderIsToldApartByOrdinalNotName() {
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "work", service: .codexCli),
            Self.snapshot(id: "b", title: "personal", service: .codexCli),
            Self.snapshot(id: "c", title: "me", service: .cursor),
        ])

        XCTAssertEqual(doc.providers.map(\.name), ["OpenAI Codex 1", "OpenAI Codex 2", "Cursor"])
        XCTAssertFalse(doc.jsonString.contains("work"))
        XCTAssertFalse(doc.jsonString.contains("personal"))
    }

    func testSubPoolIsNamedWithItsParentAndCarriesNoPlan() {
        var pool = Self.snapshot(id: "p", title: "Grok Bot", service: .cursor)
        pool.cardRole = .subPool

        let doc = make(snapshots: [pool], plans: [.cursor: "Ultra"])

        XCTAssertEqual(doc.providers.first?.name, "Grok Bot on Cursor")
        XCTAssertNil(doc.providers.first?.plan)
    }

    func testMultiAccountProvidersDoNotShareAProviderWidePlan() {
        for service in [ServiceType.claudeCode, .codexCli, .grok, .cursor, .zaiCodingPlan] {
            let doc = make(
                snapshots: [
                    Self.snapshot(id: "a", title: "work", service: service),
                    Self.snapshot(id: "b", title: "personal", service: service),
                ],
                plans: [service: "Pro"]
            )
            XCTAssertEqual(doc.providers.count, 2)
            XCTAssertTrue(doc.providers.allSatisfy { $0.plan == nil }, service.rawValue)
        }
    }

    func testFilteredOrCappedAccountCannotMakeAProviderPlanUnambiguous() {
        let visible = Self.snapshot(
            id: "default",
            title: "private",
            service: .codexCli,
            accountID: CodexAccount.defaultID
        )
        let filtered = Self.snapshot(
            id: "filtered",
            title: "private",
            service: .codexCli,
            windows: [("me@example.com", 20)],
            accountID: UUID()
        )
        let capped = Self.snapshot(id: "capped", title: "private", service: .codexCli, accountID: UUID())
        let filler = (0 ..< (PublicProfileDocument.maxProviders - 1)).map { index in
            Self.snapshot(id: "cursor-\(index)", title: "private", service: .cursor)
        }
        for snapshots in [[visible, filtered], [visible] + filler + [capped]] {
            let doc = make(snapshots: snapshots, plans: [.codexCli: "Pro"])
            let codex = doc.providers.filter { $0.provider == ServiceType.codexCli.rawValue }
            XCTAssertEqual(codex.count, 1)
            XCTAssertNil(codex.first?.plan)
        }
    }

    func testCustomOnlyAccountsDoNotInheritTheDefaultAccountPlan() {
        for service in [ServiceType.claudeCode, .codexCli, .grok] {
            let doc = make(
                snapshots: [Self.snapshot(id: "custom", title: "private", service: service, accountID: UUID())],
                plans: [service: "Pro"]
            )
            XCTAssertEqual(doc.providers.count, 1)
            XCTAssertNil(doc.providers.first?.plan, service.rawValue)
        }
    }

    func testUnambiguousDefaultAndLegacyPlansAreRetained() {
        let defaults: [(ServiceType, UUID)] = [
            (.claudeCode, ClaudeCodeAccount.defaultID),
            (.codexCli, CodexAccount.defaultID),
            (.grok, GrokAccount.defaultID),
        ]
        for (service, accountID) in defaults {
            for identity in [accountID, nil] as [UUID?] {
                let doc = make(
                    snapshots: [Self.snapshot(id: "sole", title: "private", service: service, accountID: identity)],
                    plans: [service: "Pro"]
                )
                XCTAssertEqual(doc.providers.first?.plan, "Pro", service.rawValue)
            }
        }
        for service in [ServiceType.cursor, .zaiCodingPlan] {
            let doc = make(
                snapshots: [Self.snapshot(id: "sole", title: "private", service: service, accountID: UUID())],
                plans: [service: "Pro"]
            )
            XCTAssertEqual(doc.providers.first?.plan, "Pro", service.rawValue)
        }
    }

    func testSubPoolDoesNotInflateAccountCountOrReceiveAPlan() {
        let parent = Self.snapshot(id: "parent", title: "private", service: .cursor)
        var pool = Self.snapshot(id: "pool", title: "Grok Bot", service: .cursor)
        pool.cardRole = .subPool

        let doc = make(snapshots: [parent, pool], plans: [.cursor: "Ultra"])

        XCTAssertEqual(doc.providers.map(\.plan), ["Ultra", nil])
    }

    /// The only free-text fields are allowlisted by character set, so an email,
    /// a path or a URL that reached a label is dropped rather than published.
    func testPlanLabelsThatCouldCarryAnAccountAreDropped() {
        let doc = make(
            snapshots: [
                Self.snapshot(id: "a", title: "x", service: .claudeCode),
                Self.snapshot(id: "b", title: "x", service: .codexCli),
                Self.snapshot(id: "c", title: "x", service: .cursor),
                Self.snapshot(id: "d", title: "x", service: .grok),
            ],
            plans: [
                .claudeCode: "Max 20x",
                .codexCli: "me@example.com",
                .cursor: "/Users/me/.cursor",
                .grok: String(repeating: "a", count: 40),
            ]
        )

        XCTAssertEqual(doc.providers.map(\.plan), ["Max 20x", nil, nil, nil])
    }

    func testWindowLabelsThatAreNotPlainWordsAreDropped() {
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "x", service: .claudeCode, windows: [
                ("Weekly", 20), ("https://evil.example/x", 10), ("me@example.com", 5), ("Sonnet only", 40),
            ]),
        ])

        XCTAssertEqual(doc.providers.first?.windows.map(\.label), ["Weekly", "Sonnet only"])
    }

    func testProviderWithOnlyRejectedWindowLabelsIsOmitted() {
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "private", service: .claudeCode, windows: [
                ("me@example.com", 20), ("/Users/me/session", 40),
            ]),
        ])
        XCTAssertTrue(doc.providers.isEmpty)
        XCTAssertTrue(doc.isEmpty)
    }

    func testRejectedProvidersDoNotConsumeTheCapOrChangeAccountOrdinals() {
        let rejected = (0..<PublicProfileDocument.maxProviders).map { index in
            Self.snapshot(id: "bad-\(index)", title: "private", service: .claudeCode,
                          windows: [("me@example.com", 20)])
        }
        let valid = Self.snapshot(id: "valid", title: "private", service: .claudeCode)
        let doc = make(snapshots: rejected + [valid])

        XCTAssertEqual(doc.providers.map(\.name), ["Claude Code"])
        XCTAssertTrue(doc.providers.allSatisfy { !$0.windows.isEmpty })
    }

    func testSanitizedWireDocumentMatchesTheSiteAcceptedFixture() throws {
        var doc = make(snapshots: [
            Self.snapshot(id: "bad", title: "private", service: .claudeCode, windows: [("me@example.com", 10)]),
            Self.snapshot(id: "good", title: "private", service: .claudeCode, windows: [
                ("/Users/me/session", 40), ("Weekly", 23),
            ]),
        ])
        doc.updatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T08:00:00Z"))
        let expected = """
        {
          "schema": 1,
          "updatedAt": "2026-09-30T08:00:00Z",
          "providers": [{
            "provider": "Claude Code", "name": "Claude Code", "isBlocked": false,
            "windows": [{
              "label": "Weekly", "usedPercent": 23,
              "pace": "60% in reserve", "resetsAt": "2027-01-16T11:47:00Z",
              "role": "provider", "isEstimated": false
            }]
          }]
        }
        """
        let actual = try JSONSerialization.jsonObject(with: doc.encoded()) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary
        XCTAssertEqual(try XCTUnwrap(actual), try XCTUnwrap(fixture))
        XCTAssertTrue(doc.providers.allSatisfy { !$0.windows.isEmpty })
    }

    func testFineTuneModelIdsAreDroppedBecauseTheyCarryAnOrganization() {
        XCTAssertNil(PublicProfileDocument.sanitizedModelName("ft:gpt-4o:acme-corp::abc123"))
        XCTAssertNil(PublicProfileDocument.sanitizedModelName("/Users/me/models/local"))
        XCTAssertEqual(PublicProfileDocument.sanitizedModelName("claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(PublicProfileDocument.sanitizedModelName("gpt-5.6-sol"), "gpt-5.6-sol")
    }

    /// The whole document may only ever contain these keys. A new field has to
    /// be added here on purpose, which is the point.
    func testDocumentContainsOnlyAllowlistedKeys() throws {
        var pool = Self.snapshot(id: "p", title: "Grok Bot", service: .cursor)
        pool.cardRole = .subPool
        let doc = make(
            snapshots: [Self.snapshot(id: "a", title: "me@example.com", service: .claudeCode), pool],
            plans: [.claudeCode: "Pro"],
            cost: Self.costSummary(models: ["claude-opus-5-5"])
        )

        let object = try JSONSerialization.jsonObject(with: doc.encoded())
        let keys = Self.allKeys(in: object)

        let allowed: Set<String> = [
            "schema", "updatedAt", "providers", "receipt",
            "provider", "name", "plan", "windows", "label", "usedPercent", "resetsAt", "pace",
            "primaryWindowIndex", "isBlocked", "role", "isEstimated",
            "tokens30d", "sessions", "models", "dailyTokens", "tokens",
        ]
        XCTAssertEqual(keys.subtracting(allowed), [], "unexpected keys would leave the Mac")
        XCTAssertTrue(keys.contains("receipt"))
    }

    // MARK: - Content

    func testUsedPercentMatchesWhatTheCardShows() {
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "x", service: .claudeCode, windows: [("Weekly", 23)]),
        ])

        XCTAssertEqual(doc.providers.first?.windows.first?.usedPercent, 23)
    }

    /// The pace label ("27% in reserve") carries a percent sign; a label
    /// allowlist that forgot it would silently strip the pace from every profile.
    func testPaceLabelSurvivesTheAllowlist() {
        let halfway = now.addingTimeInterval(302_400)
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "x", service: .claudeCode, windows: [("Weekly", 23)], reset: halfway),
        ])

        XCTAssertEqual(doc.providers.first?.windows.first?.pace, "27% in reserve")
    }

    func testBuiltCopilotBudgetNeverPublishesBillingOrPrivateSnapshotFields() throws {
        let accountID = UUID()
        let privateName = "private-account@example.invalid"
        let privateNote = "fixture-credential-marker private-subject private-provenance private-support-note"
        let budget = UsageMetrics(
            service: .githubCopilot,
            weeklyLimit: UsageLimit(used: 12345.67, total: 98765.43, resetTime: nil, periodKind: .monthly),
            lastUpdated: now
        )
        let copilot = ProviderSnapshotBuilder.snapshot(
            title: privateName,
            service: .githubCopilot,
            metrics: budget,
            emptyDetail: privateNote,
            accountID: accountID
        )
        XCTAssertEqual(try XCTUnwrap(copilot.limits.first).valueStyle, .currency)
        XCTAssertTrue(make(snapshots: [copilot]).providers.isEmpty)

        let quota = ProviderSnapshotBuilder.snapshot(
            title: privateName,
            service: .claudeCode,
            metrics: UsageMetrics(
                service: .claudeCode,
                weeklyLimit: UsageLimit(used: 23, total: 100, resetTime: nil),
                lastUpdated: now
            ),
            emptyDetail: privateNote,
            accountID: accountID
        )
        let rejected = Self.snapshot(
            id: "private-subject", title: privateName, service: .zaiCodingPlan,
            windows: [("/private/provenance", 10)]
        )
        let doc = make(snapshots: [copilot, rejected, quota], plans: [.githubCopilot: "Private billing plan"])
        XCTAssertEqual(doc.providers.map(\.provider), [ServiceType.claudeCode.rawValue])
        XCTAssertEqual(doc.providers.map(\.name), [ServiceType.claudeCode.displayName])
        XCTAssertTrue(doc.providers.allSatisfy { !$0.windows.isEmpty })
        for privateValue in [
            privateName, accountID.uuidString, "12345.67", "98765.43", "Private billing plan",
            "fixture-credential-marker", "private-subject", "private-provenance", "private-support-note",
        ] {
            XCTAssertFalse(doc.jsonString.contains(privateValue), privateValue)
        }
        let keys = try Self.allKeys(in: JSONSerialization.jsonObject(with: doc.encoded()))
        XCTAssertTrue(keys.isDisjoint(with: ["accountID", "subject", "credentials", "provenance", "supportNote"]))
    }

    func testCurrencyWindowsAreNotPublished() {
        let snapshot = ProviderSnapshot(
            id: "a", title: "x", service: .openRouter, updatedAt: now,
            limits: [
                SnapshotLimit(
                    id: "spend", kind: .additional, title: "Credits",
                    usageLimit: UsageLimit(used: 5, total: 10, resetTime: nil),
                    valueStyle: .currency
                ),
            ],
            emptyDetail: "", extraUsage: nil, resetCreditsAvailable: nil, accountID: nil
        )

        XCTAssertTrue(make(snapshots: [snapshot]).providers.isEmpty)
    }

    func testProvidersWithoutMetricsAreOmitted() {
        let silent = ProviderSnapshot(
            id: "a", title: "x", service: .claudeCode, updatedAt: nil, limits: [],
            emptyDetail: "", extraUsage: nil, resetCreditsAvailable: nil, accountID: nil
        )

        let doc = make(snapshots: [silent])

        XCTAssertTrue(doc.providers.isEmpty)
        XCTAssertTrue(doc.isEmpty)
    }

    func testResetTimeIsRoundedToTheMinuteSoAnUnchangedWindowIsUnchanged() {
        let reset = Date(timeIntervalSince1970: 1_800_003_599.4)
        let doc = make(snapshots: [
            Self.snapshot(id: "a", title: "x", service: .claudeCode, reset: reset),
        ])

        let published = doc.providers.first?.windows.first?.resetsAt?.timeIntervalSince1970
        XCTAssertEqual(published?.truncatingRemainder(dividingBy: 60), 0)
    }

    func testReceiptPadsDailyTokensToTheChartWeekAndKeepsTopModels() {
        let doc = make(cost: Self.costSummary(models: ["claude-opus-5-5", "ft:gpt-4o:acme::x", "claude-haiku-4-5"]))

        let receipt = doc.receipt
        XCTAssertEqual(receipt?.dailyTokens.count, PublicProfileDocument.receiptDayCount)
        XCTAssertEqual(receipt?.tokens30d, 3_000_000)
        XCTAssertEqual(receipt?.models.map(\.name), ["claude-opus-5-5", "claude-haiku-4-5"])
        XCTAssertFalse(doc.jsonString.contains("acme"))
    }

    func testNoReceiptWithoutTokens() {
        XCTAssertNil(make(cost: nil).receipt)
        XCTAssertNil(make(cost: Self.costSummary(models: [], total: 0)).receipt)
    }

    func testCapsTrackTheShareCardsSoTheProfileNeverOutgrowsIt() {
        XCTAssertEqual(PublicProfileDocument.receiptDayCount, SocialShareCardContent.chartDayCount)
        XCTAssertEqual(PublicProfileDocument.maxModels, SocialShareCardContent.modelRowCount)
    }

    func testSameContentIgnoresTheTimestampOnly() {
        let snapshots = [Self.snapshot(id: "a", title: "x", service: .claudeCode)]
        let first = make(snapshots: snapshots)
        var later = first
        later.updatedAt = first.updatedAt.addingTimeInterval(900)
        XCTAssertTrue(first.hasSameContent(as: later))

        let changed = make(snapshots: [
            Self.snapshot(id: "a", title: "x", service: .claudeCode, windows: [("Weekly", 61)]),
        ])
        XCTAssertFalse(first.hasSameContent(as: changed))
    }

    func testRoundTripsThroughJSON() throws {
        let doc = make(
            snapshots: [Self.snapshot(id: "a", title: "x", service: .claudeCode)],
            plans: [.claudeCode: "Max 5x"],
            cost: Self.costSummary(models: ["claude-opus-5-5"])
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(PublicProfileDocument.self, from: doc.encoded()), doc)
        XCTAssertEqual(doc.schema, PublicProfileDocument.schemaVersion)
    }

    // MARK: - Helpers

    private func make(
        snapshots: [ProviderSnapshot] = [],
        plans: [ServiceType: String] = [:],
        cost: CostSummary? = nil
    ) -> PublicProfileDocument {
        PublicProfileDocument.make(snapshots: snapshots, plans: plans, costSummary: cost, now: now)
    }

    private static func allKeys(in object: Any) -> Set<String> {
        if let dict = object as? [String: Any] {
            return dict.reduce(into: Set(dict.keys)) { $0.formUnion(allKeys(in: $1.value)) }
        }
        if let array = object as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(allKeys(in: $1)) }
        }
        return []
    }

    private static func snapshot(
        id: String,
        title: String,
        service: ServiceType,
        windows: [(String, Double)] = [("Weekly", 23)],
        reset: Date? = Date(timeIntervalSince1970: 1_800_100_000),
        accountID: UUID? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            title: title,
            service: service,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            limits: windows.enumerated().map { index, window in
                SnapshotLimit(
                    id: "\(id)-\(index)",
                    kind: .weekly,
                    title: window.0,
                    usageLimit: UsageLimit(used: window.1, total: 100, resetTime: reset, windowSeconds: 604_800)
                )
            },
            emptyDetail: "",
            extraUsage: nil,
            resetCreditsAvailable: nil,
            accountID: accountID
        )
    }

    private static func costSummary(models: [String], total: Int = 3_000_000) -> CostSummary {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let breakdowns = models.enumerated().map { index, name in
            TokenUsageBreakdown(
                provider: .claudeCode,
                name: name,
                inputTokens: 1_000_000 - index * 100_000,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                estimatedCostUSD: 1,
                sessionCount: 1
            )
        }
        let cost = TokenCost(
            provider: .claudeCode,
            inputTokens: total,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 3,
            sessionCount: 4,
            periodStart: now.addingTimeInterval(-30 * 86_400),
            periodEnd: now,
            modelBreakdowns: breakdowns,
            originBreakdowns: []
        )
        return CostSummary(costs: [cost], totalCostUSD: 3, totalTokens: total, periodDays: 30, dailyUsage: [])
    }
}
