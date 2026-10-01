import Foundation

/// The user's per-platform choices. Part of `WallPolicy`, so changes go through the ratchet.
public struct PlatformSettings: Codable, Sendable, Equatable {
    /// Overrides of recipe toggle defaults. Missing = recipe default.
    public var toggles: [String: Bool]
    /// Landing option key (see `Recipe.Landing.options`). nil = recipe default.
    public var landing: String?
    /// User-added path regexes to block (advanced rules).
    public var customBlocks: [String]
    /// User-added CSS selectors to hide (advanced rules).
    public var customHides: [String]

    public init(toggles: [String: Bool] = [:], landing: String? = nil, customBlocks: [String] = [], customHides: [String] = []) {
        self.toggles = toggles
        self.landing = landing
        self.customBlocks = customBlocks
        self.customHides = customHides
    }

    // Missing keys default, so settings saved by an older build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toggles = try c.decodeIfPresent([String: Bool].self, forKey: .toggles) ?? [:]
        landing = try c.decodeIfPresent(String.self, forKey: .landing)
        customBlocks = try c.decodeIfPresent([String].self, forKey: .customBlocks) ?? []
        customHides = try c.decodeIfPresent([String].self, forKey: .customHides) ?? []
    }

    public static let `default` = PlatformSettings()

    public func isOn(_ toggle: String, in recipe: Recipe) -> Bool {
        toggles[toggle] ?? recipe.toggleDefault(toggle) ?? true
    }
}

/// A recipe with the user's settings applied: disabled rules removed, custom rules appended.
/// This is exactly what the native engine and the injected scripts both evaluate.
public struct ActiveRecipe: Codable, Sendable, Equatable {
    public static let customToggle = "custom"

    public var recipe: Recipe
    public var landingPath: String

    /// - signedIn: false picks the recipe's signed-out landing (YouTube: search).
    public init(recipe: Recipe, settings: PlatformSettings = .default, signedIn: Bool = true) throws {
        var r = recipe
        let on = { (toggle: String) in settings.isOn(toggle, in: recipe) }
        r.routes = recipe.routes.filter { on($0.toggle) }
        r.hide = recipe.hide.filter { on($0.toggle) }
        r.heuristics = recipe.heuristics.filter { on($0.toggle) }
        r.behaviors = recipe.behaviors.filter { on($0.toggle) }
        r.canaries = recipe.canaries.filter { on($0.toggle) }
        r.resourceBlocks = recipe.resourceBlocks.filter { on($0.toggle) }

        if !settings.customBlocks.isEmpty || !settings.customHides.isEmpty {
            r.toggles.append(.init(id: Self.customToggle, defaultOn: true))
        }
        // Custom blocks go first: a user's own block must not be shadowed by a recipe allow.
        let custom = settings.customBlocks.enumerated().map { i, pattern in
            Recipe.RouteRule(id: "custom.block.\(i)", toggle: Self.customToggle,
                             pattern: pattern.hasPrefix("^") ? pattern : "^" + pattern, action: .block)
        }
        r.routes = custom + r.routes
        r.hide += settings.customHides.enumerated().map { i, selector in
            Recipe.HideRule(id: "custom.hide.\(i)", toggle: Self.customToggle, selector: selector)
        }
        try RecipeValidator.validate(r)
        self.recipe = r
        self.landingPath = recipe.landingPath(for: settings.landing, signedIn: signedIn)
    }
}
