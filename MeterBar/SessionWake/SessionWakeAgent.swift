import Foundation

/// Long-lived worker executed by the managed launch agent through the bundled
/// `meterbar wake-agent` command. One process-lifetime lock excludes the GUI's
/// fallback watcher and every one-shot CLI run; each launch still revalidates
/// its cwd and proves fresh quota through the existing coordinator/runtime.
public enum SessionWakeAgent {
    public static func run(shouldCancel: @escaping @Sendable () -> Bool) async -> Int32 {
        let stateStore = SessionWakeAgentStateStore()
        let lock = WakeLock(holderKind: .agent)

        switch lock.acquire() {
        case .acquired:
            break
        case let .contended(holder):
            let suffix = holder.map { " (\($0.shortDescription))" } ?? ""
            stateStore.saveStatus(.init(state: .failed(reason: "Another Session Wake holder is active\(suffix).")))
            return 75
        case let .legacyHeld(guidance):
            stateStore.saveStatus(.init(state: .failed(reason: guidance)))
            return 75
        case let .unavailable(reason):
            stateStore.saveStatus(.init(state: .failed(reason: "Wake lock unavailable: \(reason)")))
            return 75
        }
        defer {
            stateStore.saveStatus(.init(state: .off))
            lock.release()
        }

        let hookDispatcher = WakeEventHookDispatcher()
        while !shouldCancel() {
            guard let configuration = stateStore.loadConfiguration(), configuration.canRun else {
                return 0
            }

            hookDispatcher.update(configuration: configuration.eventHooks)
            let runtime = makeRuntime(configuration: configuration)
            let coordinator = WakeCoordinator(
                runner: runtime.makeRunner(),
                bounds: configuration.bounds,
                onState: { state in
                    stateStore.saveStatus(.init(state: state))
                    hookDispatcher.observe(state, provider: configuration.provider)
                }
            )

            let completed = await runPass(
                coordinator: coordinator,
                runtime: runtime,
                configuration: configuration,
                hookDispatcher: hookDispatcher,
                stateStore: stateStore,
                shouldCancel: shouldCancel
            )
            if !completed {
                if !shouldCancel(), stateStore.loadConfiguration()?.canRun == true {
                    continue
                }
                return 0
            }

            if let latestConfiguration = stateStore.loadConfiguration(),
               let status = stateStore.loadStatus(),
               case let .completed(summary) = status.watcherState,
               latestConfiguration.notifyOnCompletion {
                postCompletionNotification(summary: summary, provider: latestConfiguration.provider)
            }

            guard await waitForRescan(
                seconds: 300,
                stateStore: stateStore,
                shouldCancel: shouldCancel
            ) else { return 0 }
        }
        return 0
    }

    private static func makeRuntime(configuration: SessionWakeAgentConfiguration) -> WakeProviderRuntime {
        switch configuration.provider {
        case .claude:
            let account = ClaudeCodeAccount(
                id: UUID(),
                name: "background",
                configDirectory: configuration.accountDirectory
            )
            return ClaudeWakeRuntime(account: account) { runnerAccount in
                WakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: configuration.permissionMode,
                    bypassAcknowledged: configuration.bypassAcknowledged,
                    prompt: configuration.prompt,
                    lockMode: .externallyOwned
                )
            }
        case .codex:
            let account = CodexAccount(
                id: UUID(),
                name: "background",
                homeDirectory: configuration.accountDirectory
            )
            return CodexWakeRuntime(account: account) { runnerAccount in
                CodexWakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: configuration.permissionMode,
                    bypassAcknowledged: configuration.bypassAcknowledged,
                    prompt: configuration.prompt,
                    lockMode: .externallyOwned
                )
            }
        }
    }

    /// Race one coordinator pass against disarm, app unregister, or SIGTERM.
    /// The monitor also refreshes the heartbeat so the reopened app can
    /// distinguish a live waiting worker from stale state after a crash.
    private static func runPass(
        coordinator: WakeCoordinator,
        runtime: WakeProviderRuntime,
        configuration: SessionWakeAgentConfiguration,
        hookDispatcher: WakeEventHookDispatcher,
        stateStore: SessionWakeAgentStateStore,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await coordinator.start(runtime: runtime)
                await coordinator.waitUntilFinished()
                return true
            }
            group.addTask {
                while !Task.isCancelled {
                    guard let latest = stateStore.loadConfiguration(), latest.canRun else {
                        return false
                    }
                    // Hook edits are deliberately live configuration, not a
                    // reason to restart a potentially hours-long wake pass.
                    // Refresh the dispatcher from the same durable snapshot
                    // before the coordinator can emit its next transition.
                    hookDispatcher.update(configuration: latest.eventHooks)
                    if shouldCancel() || latest.requiresRuntimeRestart(comparedTo: configuration) { return false }
                    stateStore.refreshHeartbeat()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                return false
            }

            let completed = await group.next() ?? false
            if !completed {
                await coordinator.stop()
                await coordinator.waitUntilFinished()
            }
            group.cancelAll()
            return completed
        }
    }

    private static func waitForRescan(
        seconds: TimeInterval,
        stateStore: SessionWakeAgentStateStore,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if shouldCancel() || stateStore.loadConfiguration()?.canRun != true { return false }
            stateStore.refreshHeartbeat()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return true
    }

    /// A launch-agent executable has no independent app UI. Use a direct
    /// `osascript` process (argument array, never a shell) for the completion
    /// banner so delivery still works while MeterBar itself is quit.
    private static func postCompletionNotification(summary: WakeRunSummary, provider: WakeProvider) {
        let attempted = summary.attempted
        guard attempted > 0 || summary.remaining > 0 else { return }

        var body = "Resumed \(summary.resumed) of \(attempted) \(provider.displayName) sessions."
        if summary.failed > 0 { body += " \(summary.failed) failed." }
        if summary.remaining > 0 { body += " \(summary.remaining) still queued." }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"\(appleScriptEscaped(body))\" with title \"Session Wake — Run Complete\""
        ]
        try? process.run()
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
