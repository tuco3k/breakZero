import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The single choke point for network access (BRIEF §2). This file is the only place in the
/// codebase allowed to mention URLSession; `NetworkPolicyTests` scans the source tree for it.
///
/// Allowed traffic:
/// 1. Web views: top-level navigation to the hosts of enabled platform recipes. (Subresources
///    those sites load are theirs; we never add our own requests to pages.)
/// 2. Exactly one optional static URL prefix for signed recipe updates, only when the user
///    turned updates on. Ephemeral session: no cookies, no cache, no identifiers.
/// 3. YouTube's public channel feeds (`https://www.youtube.com/feeds/videos.xml?channel_id=UC…`),
///    only while YouTube is enabled, for the login-free Subscriptions list (BRIEF §6 S2). Same
///    ephemeral, cookie-less session; exact host, path and one validated query item.
public struct NetworkPolicy: Sendable {
    /// Where signed recipe bundles live when updates are on. Static hosting, no server code.
    public static let defaultRecipeUpdateBase = URL(string: "https://tuco3k.github.io/breakZero/recipes/")!

    public enum Purpose: Sendable {
        case webNavigation
        case recipeUpdate
        case youtubeFeed
    }

    public enum Denied: Error, Equatable {
        case notAllowed(String)
    }

    public let webHosts: [String]
    public let recipeUpdateBase: URL?
    public let youtubeFeedsAllowed: Bool

    public init(recipes: [Recipe], recipeUpdatesEnabled: Bool, recipeUpdateBase: URL = NetworkPolicy.defaultRecipeUpdateBase) {
        self.webHosts = recipes.flatMap { $0.hosts + $0.authHosts }
        self.recipeUpdateBase = recipeUpdatesEnabled ? recipeUpdateBase : nil
        self.youtubeFeedsAllowed = recipes.contains { $0.platform == Platform.youtube.rawValue }
    }

    public func allows(_ url: URL, for purpose: Purpose) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        switch purpose {
        case .webNavigation:
            return HostPattern.matchesAny(webHosts, host: url.host)
        case .recipeUpdate:
            guard let base = recipeUpdateBase, url.host?.lowercased() == base.host?.lowercased(),
                  url.user == nil, url.password == nil, url.port == base.port else { return false }
            let path = url.path
            return path.hasPrefix(base.path) && !path.contains("..")
        case .youtubeFeed:
            guard youtubeFeedsAllowed, url.host == "www.youtube.com", url.port == nil, url.user == nil,
                  url.password == nil, url.fragment == nil,
                  let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  c.percentEncodedPath == "/feeds/videos.xml",
                  let items = c.queryItems, items.count == 1, items[0].name == "channel_id",
                  let id = items[0].value else { return false }
            return YouTubeChannel.isValidID(id)
        }
    }

    /// Fetch a recipe-update resource.
    public func fetchRecipeData(from url: URL, timeout: TimeInterval = 20) async throws -> Data {
        try await fetch(url, purpose: .recipeUpdate, timeout: timeout)
    }

    /// Fetch one channel's public feed for the login-free Subscriptions list.
    public func fetchYouTubeFeed(_ channel: YouTubeChannel, timeout: TimeInterval = 15) async throws -> Data {
        guard let url = channel.feedURL else { throw Denied.notAllowed("invalid channel id") }
        return try await fetch(url, purpose: .youtubeFeed, timeout: timeout)
    }

    /// The only URLSession use in the app.
    private func fetch(_ url: URL, purpose: Purpose, timeout: TimeInterval) async throws -> Data {
        guard allows(url, for: purpose) else { throw Denied.notAllowed(url.absoluteString) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        // Redirects could leave the allowed prefix; refuse the result if so.
        if let final = response.url, !allows(final, for: purpose) {
            throw Denied.notAllowed(final.absoluteString)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Denied.notAllowed("HTTP status for \(url.absoluteString)")
        }
        return data
    }
}
