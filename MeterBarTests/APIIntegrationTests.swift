import XCTest
import MeterBarShared
@testable import MeterBar

/// Integration tests to verify API access for Claude, OpenAI, Cursor, Claude Code, and Codex CLI services.
/// These tests make real API calls and require valid credentials to be set up.
final class APIIntegrationTests: XCTestCase {

    // MARK: - Test Configuration

    /// Timeout for API calls (30 seconds)
    let apiTimeout: TimeInterval = 30.0

    // MARK: - Claude (Anthropic Admin API) Tests

    func testClaudeAPIAccess() async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🔵 CLAUDE (Anthropic) API TEST")
        print(String(repeating: "=", count: 60))

        let authManager = AuthenticationManager.shared

        // Check if credentials exist
        guard authManager.isClaudeAuthenticated else {
            print("⚠️  SKIPPED: No Claude Admin API key configured")
            print("   To test: Add your Claude Admin API key in Settings")
            throw XCTSkip("Claude Admin API key not configured")
        }

        print("✓ Claude Admin API key found")

        // Attempt to fetch usage metrics
        let claudeService = ClaudeService.shared

        do {
            let metrics = try await claudeService.fetchUsageMetrics()

            print("✅ SUCCESS: Claude API access verified!")
            print("\nUsage Data Retrieved:")
            print("  Service: \(metrics.service.displayName)")

            if let weekly = metrics.weeklyLimit {
                print("  Weekly Usage:")
                print("    - Used: \(formatTokens(weekly.used)) tokens")
                print("    - Total: \(formatTokens(weekly.total)) tokens")
                print("    - Percentage: \(String(format: "%.1f", weekly.percentage))%")
                if let resetTime = weekly.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            XCTAssertEqual(metrics.service, .claude)
            XCTAssertNotNil(metrics.weeklyLimit)

        } catch {
            print("❌ FAILED: \(error.localizedDescription)")
            XCTFail("Claude API call failed: \(error)")
        }
    }

    // MARK: - OpenAI (Codex) Tests

    func testOpenAIAPIAccess() async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🟢 OPENAI (Codex) API TEST")
        print(String(repeating: "=", count: 60))

        let authManager = AuthenticationManager.shared

        // Check if credentials exist
        guard authManager.isOpenAIAuthenticated else {
            print("⚠️  SKIPPED: No OpenAI Admin API key configured")
            print("   To test: Add your OpenAI Admin API key in Settings")
            throw XCTSkip("OpenAI Admin API key not configured")
        }

        print("✓ OpenAI Admin API key found")

        // Attempt to fetch usage metrics
        let openaiService = OpenAIService.shared

        do {
            let metrics = try await openaiService.fetchUsageMetrics()

            print("✅ SUCCESS: OpenAI API access verified!")
            print("\nUsage Data Retrieved:")
            print("  Service: \(metrics.service.displayName)")

            if let weekly = metrics.weeklyLimit {
                print("  Weekly Usage:")
                print("    - Used: \(formatTokens(weekly.used)) tokens")
                print("    - Total: \(formatTokens(weekly.total)) tokens")
                print("    - Percentage: \(String(format: "%.1f", weekly.percentage))%")
                if let resetTime = weekly.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            XCTAssertEqual(metrics.service, .openai)
            XCTAssertNotNil(metrics.weeklyLimit)

        } catch {
            print("❌ FAILED: \(error.localizedDescription)")
            XCTFail("OpenAI API call failed: \(error)")
        }
    }

    // MARK: - Claude Code (OAuth) Tests

    func testClaudeCodeAPIAccess() async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🟣 CLAUDE CODE (OAuth) API TEST")
        print(String(repeating: "=", count: 60))

        let claudeCodeService = ClaudeCodeLocalService.shared

        // Check if Claude Code usage access is available
        guard claudeCodeService.hasAccess else {
            print("⚠️  SKIPPED: Claude Code usage access not available")
            print("   To test: Log into Claude Code CLI (claude login)")
            throw XCTSkip("Claude Code usage access not available")
        }

        print("✓ Claude Code usage access available: \(claudeCodeService.authState.statusText)")

        if let subType = claudeCodeService.subscriptionType {
            print("  Subscription: \(subType)")
        }
        if let tier = claudeCodeService.rateLimitTier {
            print("  Rate Limit Tier: \(tier)")
        }

        // Attempt to fetch usage metrics
        do {
            let metrics = try await claudeCodeService.fetchUsageMetrics()

            print("✅ SUCCESS: Claude Code API access verified!")
            print("\nUsage Data Retrieved:")
            print("  Service: \(metrics.service.displayName)")

            if let session = metrics.sessionLimit {
                print("  5-Hour Session:")
                print("    - Utilization: \(String(format: "%.1f", session.used))%")
                if let resetTime = session.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            if let weekly = metrics.weeklyLimit {
                print("  7-Day Weekly:")
                print("    - Utilization: \(String(format: "%.1f", weekly.used))%")
                if let resetTime = weekly.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            if let sonnet = metrics.codeReviewLimit {
                print("  7-Day Sonnet:")
                print("    - Utilization: \(String(format: "%.1f", sonnet.used))%")
                if let resetTime = sonnet.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            XCTAssertEqual(metrics.service, .claudeCode)
            XCTAssertNotNil(metrics.sessionLimit)
            XCTAssertNotNil(metrics.weeklyLimit)

        } catch {
            print("❌ FAILED: \(error.localizedDescription)")

            // Check for specific error types
            if let serviceError = error as? ServiceError {
                switch serviceError {
                case .notAuthenticated:
                    print("   OAuth token may be expired or invalid")
                case .apiError(let msg):
                    print("   API Error: \(msg)")
                    if msg.contains("404") {
                        print("   Note: The OAuth usage endpoint may not be publicly available yet")
                    }
                default:
                    break
                }
            }

            XCTFail("Claude Code API call failed: \(error)")
        }
    }

    // MARK: - Codex CLI Tests

    func testCodexCliAPIAccess() async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🟠 CODEX CLI API TEST")
        print(String(repeating: "=", count: 60))

        let codexCliService = CodexCliLocalService.shared

        // Check if auth token exists
        guard codexCliService.hasAccess else {
            print("⚠️  SKIPPED: No Codex CLI auth token found")
            print("   To test: Log into Codex CLI (codex login)")
            throw XCTSkip("Codex CLI auth token not found")
        }

        print("✓ Codex CLI auth token found")

        if let subType = codexCliService.subscriptionType {
            print("  Subscription: \(subType)")
        }

        // Attempt to fetch usage metrics
        do {
            let metrics = try await codexCliService.fetchUsageMetrics()

            print("✅ SUCCESS: Codex CLI API access verified!")
            print("\nUsage Data Retrieved:")
            print("  Service: \(metrics.service.displayName)")

            if let session = metrics.sessionLimit {
                print("  5-Hour Session:")
                print("    - Utilization: \(String(format: "%.1f", session.used))%")
                if let resetTime = session.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            if let weekly = metrics.weeklyLimit {
                print("  7-Day Weekly:")
                print("    - Utilization: \(String(format: "%.1f", weekly.used))%")
                if let resetTime = weekly.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            if let codeReview = metrics.codeReviewLimit {
                print("  Code Review:")
                print("    - Utilization: \(String(format: "%.1f", codeReview.used))%")
                if let resetTime = codeReview.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            XCTAssertEqual(metrics.service, .codexCli)
            // Note: sessionLimit may be nil for free accounts
            // XCTAssertNotNil(metrics.sessionLimit)

        } catch {
            print("❌ FAILED: \(error.localizedDescription)")

            // Check for specific error types
            if let serviceError = error as? ServiceError {
                switch serviceError {
                case .notAuthenticated:
                    print("   Auth token may be expired or invalid")
                case .apiError(let msg):
                    print("   API Error: \(msg)")
                default:
                    break
                }
            }

            XCTFail("Codex CLI API call failed: \(error)")
        }
    }

    // MARK: - Cursor Tests

    func testCursorAPIAccess() async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("🟡 CURSOR API TEST")
        print(String(repeating: "=", count: 60))

        let cursorService = CursorLocalService.shared

        // Check if access token exists
        guard cursorService.hasAccess else {
            print("⚠️  SKIPPED: No Cursor access token found")
            print("   To test: Ensure Cursor is installed and logged in")
            throw XCTSkip("Cursor access token not found")
        }

        print("✓ Cursor access token found")

        // Attempt to fetch usage metrics
        do {
            let metrics = try await cursorService.fetchUsageMetrics()

            print("✅ SUCCESS: Cursor API access verified!")
            print("\nUsage Data Retrieved:")
            print("  Service: \(metrics.service.displayName)")

            if let session = metrics.sessionLimit {
                print("  Session Usage:")
                print("    - Used: \(String(format: "%.0f", session.used))")
                print("    - Limit: \(String(format: "%.0f", session.total))")
                print("    - Percentage: \(String(format: "%.1f", session.percentage))%")
            }

            if let monthly = metrics.weeklyLimit {
                print("  Monthly Usage:")
                print("    - Used: \(String(format: "%.0f", monthly.used))")
                print("    - Limit: \(String(format: "%.0f", monthly.total))")
                print("    - Percentage: \(String(format: "%.1f", monthly.percentage))%")
                if let resetTime = monthly.resetTime {
                    print("    - Resets: \(formatDate(resetTime))")
                }
            }

            XCTAssertEqual(metrics.service, .cursor)

        } catch {
            print("❌ FAILED: \(error.localizedDescription)")

            // Check for specific error types
            if let serviceError = error as? ServiceError {
                switch serviceError {
                case .notAuthenticated:
                    print("   Access token may be expired or invalid")
                case .apiError(let msg):
                    print("   API Error: \(msg)")
                    if msg.contains("404") || msg.contains("not found") {
                        print("   Note: Cursor may not have a public usage API")
                    }
                default:
                    break
                }
            }

            XCTFail("Cursor API call failed: \(error)")
        }
    }

    // MARK: - Combined Summary Test

    func testAllServicesStatus() async {
        print("\n" + String(repeating: "=", count: 60))
        print("📊 ALL SERVICES STATUS SUMMARY")
        print(String(repeating: "=", count: 60))

        let authManager = AuthenticationManager.shared
        let claudeCodeService = ClaudeCodeLocalService.shared
        let codexCliService = CodexCliLocalService.shared
        let cursorService = CursorLocalService.shared

        var results: [(String, String, String)] = []

        // Claude
        if authManager.isClaudeAuthenticated {
            do {
                let metrics = try await ClaudeService.shared.fetchUsageMetrics()
                let usage = metrics.weeklyLimit.map { "\(String(format: "%.1f", $0.percentage))% used" } ?? "N/A"
                results.append(("Claude", "✅ Connected", usage))
            } catch {
                results.append(("Claude", "❌ Error", error.localizedDescription))
            }
        } else {
            results.append(("Claude", "⚪ Not Configured", "Add Admin API key"))
        }

        // OpenAI
        if authManager.isOpenAIAuthenticated {
            do {
                let metrics = try await OpenAIService.shared.fetchUsageMetrics()
                let usage = metrics.weeklyLimit.map { "\(String(format: "%.1f", $0.percentage))% used" } ?? "N/A"
                results.append(("OpenAI", "✅ Connected", usage))
            } catch {
                results.append(("OpenAI", "❌ Error", error.localizedDescription))
            }
        } else {
            results.append(("OpenAI", "⚪ Not Configured", "Add Admin API key"))
        }

        // Claude Code
        if claudeCodeService.hasAccess {
            do {
                let metrics = try await claudeCodeService.fetchUsageMetrics()
                let usage = metrics.weeklyLimit.map { "\(String(format: "%.1f", $0.percentage))% used" } ?? "N/A"
                results.append(("Claude Code", "✅ Connected", usage))
            } catch {
                results.append(("Claude Code", "❌ Error", "\(error.localizedDescription.prefix(40))..."))
            }
        } else {
            results.append(("Claude Code", "⚪ Not Configured", "Run 'claude login'"))
        }

        // Codex CLI
        if codexCliService.hasAccess {
            do {
                let metrics = try await codexCliService.fetchUsageMetrics()
                let usage = metrics.sessionLimit.map { "\(String(format: "%.1f", $0.percentage))% (5h)" } ?? "N/A"
                results.append(("Codex CLI", "✅ Connected", usage))
            } catch {
                results.append(("Codex CLI", "❌ Error", "\(error.localizedDescription.prefix(40))..."))
            }
        } else {
            results.append(("Codex CLI", "⚪ Not Configured", "Run 'codex login'"))
        }

        // Cursor
        if cursorService.hasAccess {
            do {
                let metrics = try await cursorService.fetchUsageMetrics()
                let usage = metrics.weeklyLimit.map { "\(String(format: "%.1f", $0.percentage))% used" } ?? "N/A"
                results.append(("Cursor", "✅ Connected", usage))
            } catch {
                results.append(("Cursor", "❌ Error", "\(error.localizedDescription.prefix(40))..."))
            }
        } else {
            results.append(("Cursor", "⚪ Not Configured", "Login to Cursor app"))
        }

        // Print summary table
        print("\n  Service       | Status           | Details")
        print("  " + String(repeating: "-", count: 55))
        for (service, status, details) in results {
            let paddedService = service.padding(toLength: 12, withPad: " ", startingAt: 0)
            let paddedStatus = status.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("  \(paddedService) | \(paddedStatus) | \(details)")
        }
        print("")
    }

    // MARK: - Helper Methods

    private func formatTokens(_ count: Double) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", count / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", count / 1_000)
        } else {
            return String(format: "%.0f", count)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
