import Foundation

/// Recognises a Claude run that ended because it was blocked at the permission
/// approval gate, so the runner can report a *structured* `permissionDenied`
/// outcome instead of a generic failure.
///
/// Detection never triggers a retry with bypass: a denied session is reported
/// and left for the user to act on. There is deliberately no code path anywhere
/// that upgrades a safe run to `--dangerously-skip-permissions` on failure.
///
/// PRIVACY: the input is the bounded in-memory stdout/stderr capture from
/// `ManagedProcess.Result`. It is inspected here and nowhere else — never
/// logged, never persisted.
nonisolated enum PermissionDenialDetector {
    /// Conservative markers that indicate an approval gate stopped the run.
    /// Kept small and matched case-insensitively so unrelated failures are not
    /// misclassified as permission denials.
    private static let markers: [String] = [
        "permission denied",
        "requires permission",
        "requires approval",
        "needs approval",
        "permission to use",
        "permission_denied",
        "--dangerously-skip-permissions"
    ]

    /// Whether `output` (a bounded capture, never logged) reads as a permission
    /// denial.
    static func indicatesDenial(in output: String) -> Bool {
        guard !output.isEmpty else { return false }
        let haystack = output.lowercased()
        return markers.contains { haystack.contains($0) }
    }
}
