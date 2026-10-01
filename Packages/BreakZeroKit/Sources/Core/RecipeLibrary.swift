import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable, Identifiable {
    case instagram
    case youtube
    /// Draft (spike S8 pending): off by default; enable it in the Wall tab.
    case snapchat

    public var id: String { rawValue }
}

/// Bundled recipes (always shipped) plus an optional newer, verified downloaded copy.
public enum RecipeLibrary {
    public enum LoadError: Error {
        case missing(String)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }

    /// Load and validate a bundled recipe.
    public static func bundled(_ platform: Platform) throws -> Recipe {
        guard let url = Bundle.module.url(forResource: platform.rawValue, withExtension: "json", subdirectory: "Recipes") else {
            throw LoadError.missing(platform.rawValue)
        }
        let recipe = try decode(Data(contentsOf: url))
        try RecipeValidator.validate(recipe)
        return recipe
    }

    /// Prefer a downloaded recipe only if it is valid, for the same platform, newer, and
    /// understood by this engine. Otherwise the bundled one wins.
    public static func best(bundled: Recipe, downloaded: Recipe?) -> Recipe {
        guard let downloaded,
              downloaded.platform == bundled.platform,
              downloaded.version > bundled.version,
              (try? RecipeValidator.validate(downloaded)) != nil
        else { return bundled }
        return downloaded
    }
}

/// A cookie as the web view reports it: name and domain only. Values are never read.
public struct CookieName: Sendable, Equatable {
    public var name: String
    public var domain: String

    public init(name: String, domain: String) {
        self.name = name
        self.domain = domain
    }
}

/// Signed in/out from cookie names (Accounts rows, signed-out landing).
public enum SessionDetector {
    public static func isSignedIn(_ recipe: Recipe, cookies: [CookieName]) -> Bool {
        guard let session = recipe.session, !session.cookies.isEmpty else { return false }
        let names = Set(session.cookies)
        let hosts = (recipe.hosts + recipe.authHosts).map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
        return cookies.contains { c in
            guard names.contains(c.name) else { return false }
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            let domain = d.lowercased()
            return domain.contains(".") && hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }
    }
}
