import XCTest
@testable import MeterBar

@MainActor
final class ApiUsageStoreTests: XCTestCase {
    private actor FetchProbe {
        private var slowContinuation: CheckedContinuation<ApiUsage, Never>?
        private(set) var requestedWindows: [ApiUsageWindow] = []

        func fetch(provider: ApiProvider, window: ApiUsageWindow) async -> ApiUsage {
            requestedWindows.append(window)
            if window == .last30Days {
                return await withCheckedContinuation { continuation in
                    slowContinuation = continuation
                }
            }
            return Self.usage(provider: provider, window: window, inputTokens: 1)
        }

        var hasPendingSlowRequest: Bool {
            slowContinuation != nil
        }

        func completeSlowRequest() {
            slowContinuation?.resume(
                returning: Self.usage(provider: .anthropic, window: .last30Days, inputTokens: 30)
            )
            slowContinuation = nil
        }

        private static func usage(
            provider: ApiProvider,
            window: ApiUsageWindow,
            inputTokens: Int
        ) -> ApiUsage {
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let range = window.dateRange(now: now)
            return ApiUsage(
                provider: provider,
                windowStart: range.start,
                windowEnd: range.end,
                inputTokens: inputTokens,
                outputTokens: 0,
                estimatedCostUSD: 0,
                models: []
            )
        }
    }

    func testSupersededWindowRefreshCannotPublishLateResult() async {
        let probe = FetchProbe()
        let store = makeStore { provider, window in
            await probe.fetch(provider: provider, window: window)
        }

        store.setWindow(.last30Days)
        for _ in 0..<100 {
            if await probe.hasPendingSlowRequest { break }
            await Task.yield()
        }
        let hasPendingSlowRequest = await probe.hasPendingSlowRequest
        guard hasPendingSlowRequest else {
            XCTFail("scheduled refresh did not reach the controlled fetcher")
            return
        }

        let custom = ApiUsageWindow.custom(
            start: Date(timeIntervalSince1970: 1_900_000_000),
            end: Date(timeIntervalSince1970: 1_900_086_400)
        )
        store.setWindow(custom)
        await store.waitForCurrentRefresh()

        XCTAssertEqual(store.window, custom)
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 1)
        XCTAssertFalse(store.isLoading)

        await probe.completeSlowRequest()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.window, custom)
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 1, "a superseded request must never publish late")
        let requestedWindows = await probe.requestedWindows
        XCTAssertEqual(requestedWindows, [.last30Days, custom])
    }

    func testMatchingRefreshCoalescesWithScheduledWindowRequest() async {
        let probe = FetchProbe()
        let store = makeStore { provider, window in
            await probe.fetch(provider: provider, window: window)
        }

        store.setWindow(.last30Days)
        for _ in 0..<100 {
            if await probe.hasPendingSlowRequest { break }
            await Task.yield()
        }
        let hasPendingSlowRequest = await probe.hasPendingSlowRequest
        guard hasPendingSlowRequest else {
            XCTFail("scheduled refresh did not reach the controlled fetcher")
            return
        }

        let overlappingRefresh = Task { await store.refresh() }
        for _ in 0..<10 { await Task.yield() }
        let requestedBeforeCompletion = await probe.requestedWindows
        XCTAssertEqual(requestedBeforeCompletion, [.last30Days])

        await probe.completeSlowRequest()
        await overlappingRefresh.value

        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 30)
        XCTAssertFalse(store.isLoading)
    }

    func testFailedSameWindowRefreshPreservesCachedUsageAndSanitizesError() async {
        actor ResponseSequence {
            private var callCount = 0

            func fetch(provider: ApiProvider, window: ApiUsageWindow) throws -> ApiUsage {
                callCount += 1
                if callCount > 1 {
                    throw ServiceError.apiError("HTTP 500: account@example.test")
                }
                let range = window.dateRange(now: Date(timeIntervalSince1970: 2_000_000_000))
                return ApiUsage(
                    provider: provider,
                    windowStart: range.start,
                    windowEnd: range.end,
                    inputTokens: 7,
                    outputTokens: 0,
                    estimatedCostUSD: 0,
                    models: []
                )
            }
        }

        let responses = ResponseSequence()
        let store = makeStore { provider, window in
            try await responses.fetch(provider: provider, window: window)
        }

        await store.refresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 7)

        await store.refresh()

        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 7)
        XCTAssertEqual(store.lastError, "HTTP 500")
        XCTAssertFalse(store.lastError?.contains("account@example.test") ?? true)
        XCTAssertFalse(store.isLoading)
    }

    func testFailedDifferentWindowDoesNotReusePriorWindowCache() async {
        actor ResponseSequence {
            func fetch(provider: ApiProvider, window: ApiUsageWindow) throws -> ApiUsage {
                if window == .last30Days {
                    throw ServiceError.apiError("HTTP 500: account@example.test")
                }
                return ApiUsageStoreTests.usage(provider: provider, window: window, inputTokens: 7)
            }
        }

        let responses = ResponseSequence()
        let store = makeStore { provider, window in
            try await responses.fetch(provider: provider, window: window)
        }

        await store.refresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 7)

        store.setWindow(.last30Days)
        XCTAssertNil(store.usage[.anthropic], "changing windows must synchronously stop showing 7-day data")
        await store.waitForCurrentRefresh()

        XCTAssertNil(store.usage[.anthropic])
        XCTAssertEqual(store.lastError, "HTTP 500")
        XCTAssertFalse(store.lastError?.contains("account@example.test") ?? true)
        XCTAssertFalse(store.isLoading)
    }

    func testEquivalentCustomWindowsShareNormalizedCacheBucket() async {
        actor ResponseSequence {
            private var callCount = 0

            func fetch(provider: ApiProvider, window: ApiUsageWindow) throws -> ApiUsage {
                callCount += 1
                if callCount > 1 {
                    throw ServiceError.apiError("HTTP 503")
                }
                return ApiUsageStoreTests.usage(provider: provider, window: window, inputTokens: 12)
            }
        }

        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_900_000_000))
        guard let lastDay = calendar.date(byAdding: .day, value: 2, to: firstDay) else {
            XCTFail("could not construct custom test window")
            return
        }
        let firstWindow = ApiUsageWindow.custom(
            start: firstDay.addingTimeInterval(3_600),
            end: lastDay.addingTimeInterval(7_200)
        )
        let equivalentReversedWindow = ApiUsageWindow.custom(
            start: lastDay.addingTimeInterval(18_000),
            end: firstDay.addingTimeInterval(10_800)
        )

        let responses = ResponseSequence()
        let store = makeStore { provider, window in
            try await responses.fetch(provider: provider, window: window)
        }

        store.setWindow(firstWindow)
        await store.waitForCurrentRefresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 12)

        store.setWindow(equivalentReversedWindow)
        XCTAssertEqual(
            store.usage[.anthropic]?.inputTokens,
            12,
            "semantically identical date selections should use the same cache bucket"
        )
        await store.waitForCurrentRefresh()

        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 12)
        XCTAssertEqual(store.lastError, "HTTP 503")
    }

    func testReplacingCredentialCannotReusePreviousOrganizationCache() async {
        actor CredentialResponses {
            func fetch(provider: ApiProvider, key: String, window: ApiUsageWindow) throws -> ApiUsage {
                if key == "organization-a" {
                    return ApiUsageStoreTests.usage(provider: provider, window: window, inputTokens: 17)
                }
                throw ServiceError.apiError("HTTP 401")
            }
        }

        var adminKey = "organization-a"
        let responses = CredentialResponses()
        let store = makeCredentialStore(
            authenticatedProviders: { [.anthropic] },
            adminKey: { _ in adminKey },
            fetch: { provider, key, window in
                try await responses.fetch(provider: provider, key: key, window: window)
            }
        )

        await store.refresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 17)

        adminKey = "organization-b"
        await store.refresh()

        XCTAssertNil(store.usage[.anthropic])
        XCTAssertEqual(store.lastError, "HTTP 401")
    }

    func testRemovingCredentialsClearsCacheBeforeSameKeyIsAddedAgain() async {
        actor ResponseSequence {
            private var callCount = 0

            func fetch(provider: ApiProvider, window: ApiUsageWindow) throws -> ApiUsage {
                callCount += 1
                if callCount > 1 {
                    throw ServiceError.apiError("HTTP 503")
                }
                return ApiUsageStoreTests.usage(provider: provider, window: window, inputTokens: 23)
            }
        }

        var providers: [ApiProvider] = [.anthropic]
        var adminKey: String? = "organization-a"
        let responses = ResponseSequence()
        let store = makeCredentialStore(
            authenticatedProviders: { providers },
            adminKey: { _ in adminKey },
            fetch: { provider, _, window in
                try await responses.fetch(provider: provider, window: window)
            }
        )

        await store.refresh()
        XCTAssertEqual(store.usage[.anthropic]?.inputTokens, 23)

        providers = []
        adminKey = nil
        await store.refresh()
        XCTAssertTrue(store.usage.isEmpty)

        providers = [.anthropic]
        adminKey = "organization-a"
        await store.refresh()

        XCTAssertNil(store.usage[.anthropic])
        XCTAssertEqual(store.lastError, "HTTP 503")
    }

    private func makeStore(
        fetch: @escaping (ApiProvider, ApiUsageWindow) async throws -> ApiUsage
    ) -> ApiUsageStore {
        ApiUsageStore(
            authenticatedProviders: { [.anthropic] },
            adminKey: { _ in "test-admin-key" },
            fetchUsage: { provider, _, window in
                try await fetch(provider, window)
            }
        )
    }

    private func makeCredentialStore(
        authenticatedProviders: @escaping () -> [ApiProvider],
        adminKey: @escaping (ApiProvider) -> String?,
        fetch: @escaping ApiUsageStore.UsageFetcher
    ) -> ApiUsageStore {
        ApiUsageStore(
            authenticatedProviders: authenticatedProviders,
            adminKey: adminKey,
            fetchUsage: fetch
        )
    }

    nonisolated private static func usage(
        provider: ApiProvider,
        window: ApiUsageWindow,
        inputTokens: Int
    ) -> ApiUsage {
        let range = window.dateRange(now: Date(timeIntervalSince1970: 2_000_000_000))
        return ApiUsage(
            provider: provider,
            windowStart: range.start,
            windowEnd: range.end,
            inputTokens: inputTokens,
            outputTokens: 0,
            estimatedCostUSD: 0,
            models: []
        )
    }
}
