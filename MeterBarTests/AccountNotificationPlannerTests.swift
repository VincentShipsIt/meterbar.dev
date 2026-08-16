import MeterBarShared
import XCTest
@testable import MeterBar

final class AccountNotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let claudeAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10))
    private let secondClaudeAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11))
    private let codexAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12))
    private let grokAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 13))
    private let secondGrokAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 14))

    private var planner: AccountNotificationPlanner {
        AccountNotificationPlanner(preferences: .default)
    }

    private func account(
        id: UUID,
        name: String,
        isEnabled: Bool = true
    ) -> AccountNotificationIdentity {
        AccountNotificationIdentity(id: id, name: name, isEnabled: isEnabled)
    }

    private func metrics(
        service: ServiceType,
        used: Double,
        weeklyUsed: Double? = nil,
        lastUpdated: Date? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil),
            weeklyLimit: weeklyUsed.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            lastUpdated: lastUpdated ?? now
        )
    }

    private func input(
        service: ServiceType = .claudeCode,
        providerEnabled: Bool = true,
        accounts: [AccountNotificationIdentity],
        accountMetrics: [UUID: UsageMetrics] = [:],
        fallbackMetrics: UsageMetrics? = nil
    ) -> AccountNotificationPlanInput {
        AccountNotificationPlanInput(
            service: service,
            providerEnabled: providerEnabled,
            accounts: accounts,
            accountMetrics: accountMetrics,
            fallbackMetrics: fallbackMetrics
        )
    }

    func testPlansPerAccountKeysAndDisplayNames() {
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work"),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 2)
        XCTAssertEqual(Set(result.notifications.map(\.key)), [
            "Claude Code-\(claudeAccountID.uuidString)-session-critical",
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])
        XCTAssertEqual(Set(result.notifications.map(\.serviceDisplayName)), [
            "Work (Claude Code)",
            "Personal (Claude Code)"
        ])
    }

    func testUsesProviderFallbackWhenEveryEnabledAccountIsUnavailable() {
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work"),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.map(\.key), ["Claude Code-session-critical"])
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-critical"))
    }

    func testUsesProviderFallbackWhenNoAccountsAreConfigured() {
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.map(\.key), ["Claude Code-session-critical"])
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-critical"))
    }

    func testFallbackToAccountTransitionPrimesNewNamespaceWithoutDuplicate() {
        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(fallbackResult.notifications.map(\.key), ["Claude Code-session-critical"])

        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
                )
            ],
            alreadyNotified: fallbackResult.notifiedKeys,
            now: now
        )

        XCTAssertTrue(accountResult.notifications.isEmpty)
        XCTAssertFalse(accountResult.notifiedKeys.contains("Claude Code-session-critical"))
        XCTAssertTrue(
            accountResult.notifiedKeys.contains(
                "Claude Code-\(claudeAccountID.uuidString)-session-critical"
            )
        )
    }

    func testFallbackToAccountTransitionStillDeliversEscalationsAndNewQuotaKinds() {
        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 90)
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(fallbackResult.notifications.map(\.level), [.warning])

        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [
                        claudeAccountID: metrics(
                            service: .claudeCode,
                            used: 100,
                            weeklyUsed: 100
                        )
                    ]
                )
            ],
            alreadyNotified: fallbackResult.notifiedKeys,
            now: now
        )

        XCTAssertEqual(accountResult.notifications.map(\.level), [.critical, .critical])
        XCTAssertEqual(
            accountResult.notifications.map(\.quotaDisplayName),
            ["Session", "Weekly"]
        )
    }

    func testTemporaryFullDataGapPreservesAccountDedupState() {
        let available = input(
            accounts: [account(id: claudeAccountID, name: "Work")],
            accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
        )
        let first = planner.plan(inputs: [available], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 1)

        let unavailable = planner.plan(
            inputs: [input(accounts: [account(id: claudeAccountID, name: "Work")])],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [available],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertEqual(unavailable.notifiedKeys, first.notifiedKeys)
        XCTAssertTrue(recovered.notifications.isEmpty)
    }

    func testAccountToFallbackTransitionPrimesNewNamespaceWithoutDuplicate() {
        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(accountResult.notifications.count, 1)

        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: accountResult.notifiedKeys,
            now: now
        )

        XCTAssertTrue(fallbackResult.notifications.isEmpty)
        XCTAssertEqual(
            fallbackResult.notifiedKeys,
            Set([
                "Claude Code-\(claudeAccountID.uuidString)-session-warn",
                "Claude Code-\(claudeAccountID.uuidString)-session-critical",
                "Claude Code-session-warn",
                "Claude Code-session-critical"
            ])
        )
    }

    func testCachedHealthyFallbackDoesNotLoseExhaustedAccountDedupState() {
        let accounts = [
            account(id: claudeAccountID, name: "Healthy"),
            account(id: secondClaudeAccountID, name: "Exhausted")
        ]
        let available = input(
            accounts: accounts,
            accountMetrics: [
                claudeAccountID: metrics(service: .claudeCode, used: 0),
                secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
            ]
        )
        let first = planner.plan(inputs: [available], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.map(\.key), [
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])

        let unavailable = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 0)
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [available],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertTrue(unavailable.notifications.isEmpty)
        XCTAssertTrue(recovered.notifications.isEmpty)
        XCTAssertTrue(
            recovered.notifiedKeys.contains(
                "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
            )
        )
    }

    func testCachedExhaustedFallbackDoesNotMaskAnotherAccountsFirstCrossing() {
        let accounts = [
            account(id: claudeAccountID, name: "Exhausted"),
            account(id: secondClaudeAccountID, name: "Healthy")
        ]
        let first = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 0)
                    ]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(first.notifications.map(\.key), [
            "Claude Code-\(claudeAccountID.uuidString)-session-critical"
        ])

        let unavailable = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertTrue(unavailable.notifications.isEmpty)
        XCTAssertEqual(recovered.notifications.map(\.key), [
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])
    }

    func testFallbackRearmsDuringExtendedAccountDataGap() {
        let accounts = [account(id: claudeAccountID, name: "Work")]
        let first = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(first.notifications.count, 1)

        let initialFallback = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let resetFallback = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 0)
                )
            ],
            alreadyNotified: initialFallback.notifiedKeys,
            now: now
        )
        let crossedFallback = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: resetFallback.notifiedKeys,
            now: now
        )

        XCTAssertTrue(initialFallback.notifications.isEmpty)
        XCTAssertTrue(resetFallback.notifications.isEmpty)
        XCTAssertEqual(crossedFallback.notifications.map(\.key), ["Claude Code-session-critical"])
    }

    func testDisabledAccountCleanupRearmsLaterCrossing() {
        let enabledInput = input(
            accounts: [
                account(id: claudeAccountID, name: "Work"),
                account(id: secondClaudeAccountID, name: "Personal")
            ],
            accountMetrics: [
                claudeAccountID: metrics(service: .claudeCode, used: 100),
                secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
            ]
        )
        let first = planner.plan(inputs: [enabledInput], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 2)

        let disabled = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work", isEnabled: false),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        XCTAssertTrue(disabled.notifications.isEmpty)
        XCTAssertFalse(disabled.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(claudeAccountID.uuidString)")
        })
        XCTAssertTrue(disabled.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(secondClaudeAccountID.uuidString)")
        })

        let reenabled = planner.plan(
            inputs: [enabledInput],
            alreadyNotified: disabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(reenabled.notifications.count, 1)
        XCTAssertTrue(
            reenabled.notifications[0].key.hasPrefix(
                "Claude Code-\(claudeAccountID.uuidString)"
            )
        )
    }

    func testDisabledProviderCleanupRearmsLaterCrossing() {
        let enabledInput = input(
            service: .codexCli,
            accounts: [account(id: codexAccountID, name: "Work")],
            accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
        )
        let first = planner.plan(inputs: [enabledInput], alreadyNotified: [], now: now)

        let disabled = planner.plan(
            inputs: [
                input(
                    service: .codexCli,
                    providerEnabled: false,
                    accounts: [account(id: codexAccountID, name: "Work")],
                    accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        XCTAssertTrue(disabled.notifications.isEmpty)
        XCTAssertTrue(disabled.notifiedKeys.isEmpty)

        let reenabled = planner.plan(
            inputs: [enabledInput],
            alreadyNotified: disabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(reenabled.notifications.count, 1)
    }

    func testThreadsKeysSequentiallyAcrossClaudeThenCodex() {
        let inputs = [
            input(
                accounts: [account(id: claudeAccountID, name: "Claude Work")],
                accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
            ),
            input(
                service: .codexCli,
                accounts: [account(id: codexAccountID, name: "Codex Work")],
                accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
            )
        ]

        let first = planner.plan(inputs: inputs, alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 2)
        XCTAssertTrue(first.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(claudeAccountID.uuidString)")
        })
        XCTAssertTrue(first.notifiedKeys.contains {
            $0.hasPrefix("Codex CLI-\(codexAccountID.uuidString)")
        })

        let repeated = planner.plan(inputs: inputs, alreadyNotified: first.notifiedKeys, now: now)
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.notifiedKeys, first.notifiedKeys)
    }

    func testStaleAndUnavailableAccountsDoNotBlockFreshAccountPlanning() {
        let unavailableKey = "Claude Code-\(secondClaudeAccountID.uuidString)-session-warn"
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Stale"),
                        account(id: secondClaudeAccountID, name: "Unavailable"),
                        account(id: codexAccountID, name: "Fresh")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(
                            service: .claudeCode,
                            used: 100,
                            lastUpdated: now.addingTimeInterval(
                                -NotificationDecider.defaultStalenessThreshold - 1
                            )
                        ),
                        codexAccountID: metrics(service: .claudeCode, used: 100)
                    ],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [unavailableKey],
            now: now
        )

        XCTAssertEqual(
            result.notifications.map(\.key),
            ["Claude Code-\(codexAccountID.uuidString)-session-critical"]
        )
        XCTAssertTrue(result.notifiedKeys.contains(unavailableKey))
        XCTAssertTrue(
            result.notifiedKeys.contains(
                "Claude Code-\(claudeAccountID.uuidString)-session-critical"
            )
        )
        XCTAssertFalse(result.notifiedKeys.contains("Claude Code-session-critical"))
    }

    // MARK: - Grok per-account

    func testTwoGrokProfilesCrossWarningCriticalExhaustedAndRecoverIndependently() {
        let personal = account(id: grokAccountID, name: "Personal")
        let work = account(id: secondGrokAccountID, name: "Work")
        let accounts = [personal, work]

        let personalWarns = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: accounts,
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 95),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10)
                    ]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(personalWarns.notifications.map(\.key), [
            "Grok-\(grokAccountID.uuidString)-weekly-warn"
        ])
        XCTAssertEqual(personalWarns.notifications.map(\.serviceDisplayName), [
            "Personal (Grok)"
        ])
        XCTAssertFalse(personalWarns.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(secondGrokAccountID.uuidString)-weekly")
        })

        let workExhausts = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: accounts,
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 95),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: personalWarns.notifiedKeys,
            now: now
        )
        XCTAssertEqual(workExhausts.notifications.map(\.key), [
            "Grok-\(secondGrokAccountID.uuidString)-weekly-critical"
        ])
        XCTAssertEqual(workExhausts.notifications.map(\.level), [.critical])
        XCTAssertTrue(workExhausts.notifiedKeys.contains(
            "Grok-\(grokAccountID.uuidString)-weekly-warn"
        ))

        let personalExhausts = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: accounts,
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: workExhausts.notifiedKeys,
            now: now
        )
        XCTAssertEqual(personalExhausts.notifications.map(\.key), [
            "Grok-\(grokAccountID.uuidString)-weekly-critical"
        ])

        let personalRecovers = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: accounts,
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: personalExhausts.notifiedKeys,
            now: now
        )
        XCTAssertTrue(personalRecovers.notifications.isEmpty)
        XCTAssertFalse(personalRecovers.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(grokAccountID.uuidString)-weekly")
        })
        XCTAssertTrue(personalRecovers.notifiedKeys.contains(
            "Grok-\(secondGrokAccountID.uuidString)-weekly-critical"
        ))

        let workRecovers = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: accounts,
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10)
                    ]
                )
            ],
            alreadyNotified: personalRecovers.notifiedKeys,
            now: now
        )
        XCTAssertTrue(workRecovers.notifications.isEmpty)
        XCTAssertFalse(workRecovers.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(secondGrokAccountID.uuidString)-weekly")
        })
    }

    func testGrokEnableDisableDeleteAndRenameReconcilesNotificationState() {
        let enabledInput = input(
            service: .grok,
            accounts: [
                account(id: grokAccountID, name: "Personal"),
                account(id: secondGrokAccountID, name: "Work")
            ],
            accountMetrics: [
                grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100),
                secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
            ]
        )
        let first = planner.plan(inputs: [enabledInput], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 2)

        let disabled = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [
                        account(id: grokAccountID, name: "Personal", isEnabled: false),
                        account(id: secondGrokAccountID, name: "Work")
                    ],
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        XCTAssertTrue(disabled.notifications.isEmpty)
        XCTAssertFalse(disabled.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(grokAccountID.uuidString)")
        })
        XCTAssertTrue(disabled.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(secondGrokAccountID.uuidString)")
        })

        let reenabled = planner.plan(
            inputs: [enabledInput],
            alreadyNotified: disabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(reenabled.notifications.map(\.key), [
            "Grok-\(grokAccountID.uuidString)-weekly-critical"
        ])

        let deleted = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [account(id: secondGrokAccountID, name: "Work")],
                    accountMetrics: [
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: reenabled.notifiedKeys,
            now: now
        )
        XCTAssertTrue(deleted.notifications.isEmpty)
        XCTAssertTrue(deleted.notifiedKeys.contains(
            "Grok-\(secondGrokAccountID.uuidString)-weekly-critical"
        ))

        let renamed = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [account(id: secondGrokAccountID, name: "Studio")],
                    accountMetrics: [
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: deleted.notifiedKeys,
            now: now
        )
        XCTAssertTrue(renamed.notifications.isEmpty)

        let recoveredThenCrossed = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [account(id: secondGrokAccountID, name: "Studio")],
                    accountMetrics: [
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10)
                    ]
                )
            ],
            alreadyNotified: renamed.notifiedKeys,
            now: now
        )
        let renamedCrossing = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [account(id: secondGrokAccountID, name: "Studio")],
                    accountMetrics: [
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: recoveredThenCrossed.notifiedKeys,
            now: now
        )
        XCTAssertEqual(renamedCrossing.notifications.map(\.serviceDisplayName), [
            "Studio (Grok)"
        ])
        XCTAssertEqual(renamedCrossing.notifications.map(\.key), [
            "Grok-\(secondGrokAccountID.uuidString)-weekly-critical"
        ])
    }

    func testLegacyGrokProviderWideStateDoesNotRefireUnchangedAlert() {
        let defaultAccount = account(id: grokAccountID, name: GrokAccount.defaultName)
        let work = account(id: secondGrokAccountID, name: "Work")
        let legacyKeys: Set<String> = [
            "Grok-weekly-warn",
            "Grok-weekly-critical"
        ]

        let migrated = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [defaultAccount, work],
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 10)
                    ],
                    fallbackMetrics: metrics(service: .grok, used: 0, weeklyUsed: 100)
                )
            ],
            alreadyNotified: legacyKeys,
            now: now
        )

        XCTAssertTrue(
            migrated.notifications.isEmpty,
            "The representative profile must inherit the legacy Grok band without a duplicate banner."
        )
        XCTAssertFalse(migrated.notifiedKeys.contains("Grok-weekly-warn"))
        XCTAssertFalse(migrated.notifiedKeys.contains("Grok-weekly-critical"))
        XCTAssertTrue(migrated.notifiedKeys.contains(
            "Grok-\(grokAccountID.uuidString)-weekly-critical"
        ))
        XCTAssertFalse(migrated.notifiedKeys.contains {
            $0.hasPrefix("Grok-\(secondGrokAccountID.uuidString)-weekly")
        })

        let workCrosses = planner.plan(
            inputs: [
                input(
                    service: .grok,
                    accounts: [defaultAccount, work],
                    accountMetrics: [
                        grokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100),
                        secondGrokAccountID: metrics(service: .grok, used: 0, weeklyUsed: 100)
                    ]
                )
            ],
            alreadyNotified: migrated.notifiedKeys,
            now: now
        )
        XCTAssertEqual(workCrosses.notifications.map(\.key), [
            "Grok-\(secondGrokAccountID.uuidString)-weekly-critical"
        ])
    }
}
