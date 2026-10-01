import Foundation

/// A compiled recipe regex. Recipes use the subset of syntax that ICU (NSRegularExpression)
/// and JavaScript `RegExp` agree on, because the same patterns run natively (navigation
/// delegate) and in the injected route guard. `RecipeValidator` enforces the subset.
public final class PathRegex: @unchecked Sendable {
    // @unchecked: NSRegularExpression is immutable and documented thread-safe.
    public let pattern: String
    private let regex: NSRegularExpression
    private let groupNames: [String]

    public init(_ pattern: String) throws {
        self.pattern = pattern
        self.regex = try NSRegularExpression(pattern: pattern, options: [])
        self.groupNames = PathRegex.namedGroups(in: pattern)
    }

    public func matches(_ string: String) -> Bool {
        firstMatch(string) != nil
    }

    /// Named captures of the first match, or nil if no match.
    public func firstMatch(_ string: String) -> [String: String]? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let m = regex.firstMatch(in: string, options: [], range: range) else { return nil }
        var captures: [String: String] = [:]
        for name in groupNames {
            let r = m.range(withName: name)
            if r.location != NSNotFound, let sr = Range(r, in: string) {
                captures[name] = String(string[sr])
            }
        }
        return captures
    }

    static func namedGroups(in pattern: String) -> [String] {
        var names: [String] = []
        var i = pattern.startIndex
        while i < pattern.endIndex {
            if pattern[i] == "\\" {
                i = pattern.index(i, offsetBy: 2, limitedBy: pattern.endIndex) ?? pattern.endIndex
                continue
            }
            if pattern[i...].hasPrefix("(?<"), !pattern[i...].hasPrefix("(?<="), !pattern[i...].hasPrefix("(?<!") {
                let start = pattern.index(i, offsetBy: 3)
                if let end = pattern[start...].firstIndex(of: ">") {
                    names.append(String(pattern[start..<end]))
                    i = end
                }
            }
            i = pattern.index(after: i)
        }
        return names
    }
}
