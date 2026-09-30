import Foundation

/// Words and links for the Public profile panel, kept out of the view so they
/// can be pinned by tests without hosting SwiftUI.
enum PublicProfilePresentation {
    static let title = "Public profile"

    private static let publishedFields = "each provider's quota windows (used, reset, pace), "
        + "its plan when its account is unambiguous, your 30-day token and session totals, "
        + "top models, and daily tokens for the last 7 days"

    static let offSummary = "Off by default. Turn it on to publish " + publishedFields
        + " to a link you can share. MeterBar sends nothing until you do."

    static let onSummary = "Anyone with this link can see it. Turn it off to delete the published copy."

    static func summary(isEnabled: Bool) -> String {
        isEnabled ? onSummary : offSummary
    }

    static let neverPublished = "Never published: your name, email, account names, folders, "
        + "project names, or credentials."

    static let publishedSummary = "Published: " + publishedFields + "."

    static func statusText(
        status: PublicProfileStore.Status,
        lastPublishedAt: Date?,
        pendingDeletions: Int,
        now: Date = Date()
    ) -> String? {
        switch status {
        case .off:
            return pendingDeletions > 0
                ? "Couldn't remove your published copy yet. MeterBar will keep retrying."
                : nil
        case .waiting:
            return "Waiting for usage data to publish."
        case .syncing:
            return "Publishing…"
        case .live:
            guard let lastPublishedAt else { return "Live" }
            return "Live · updated \(UsageFormat.relative(lastPublishedAt, to: now))"
        case let .error(message):
            return message
        }
    }

    /// The X compose link for sharing the profile. Built from the profile URL
    /// alone: nothing about the user rides along in the text.
    static func xShareURL(profileURL: URL) -> URL? {
        var components = URLComponents(string: "https://x.com/intent/post")
        components?.queryItems = [
            URLQueryItem(name: "text", value: "My AI coding limits, live on MeterBar"),
            URLQueryItem(name: "url", value: profileURL.absoluteString),
        ]
        return components?.url
    }

    static let resetConfirmation = "Reset link? The current link stops working and its published data is deleted. "
        + "You get a new link that is not connected to the old one."
}
