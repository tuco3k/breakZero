// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
#if canImport(WebKit) && canImport(UIKit)
import Core
import WebKit

/// Accounts: signed in/out per platform, and sign-out that clears only that platform's cookies.
/// Each platform has its own persistent data store (`LiteWebController.dataStoreID`), so clearing
/// one never touches another. Only cookie *names* and domains are read, never values.
@MainActor
public enum LiteSession {
    public static func dataStore(_ p: Platform) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: LiteWebController.dataStoreID(p))
    }

    public static func cookieNames(_ p: Platform) async -> [CookieName] {
        let cookies = await dataStore(p).httpCookieStore.allCookies()
        return cookies.map { CookieName(name: $0.name, domain: $0.domain) }
    }

    public static func isSignedIn(_ p: Platform, recipe: Recipe) async -> Bool {
        SessionDetector.isSignedIn(recipe, cookies: await cookieNames(p))
    }

    /// Deletes this platform's cookies (and nothing else: no other data types, no other stores).
    public static func signOut(_ p: Platform) async {
        await dataStore(p).removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }
}
#endif
