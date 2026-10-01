import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable, Identifiable {
    case instagram
    case youtube

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
