import Foundation

/// Beta build facts in one place: the version line in the Wall tab and the "Send feedback" email
/// (QUESTIONS #70). The email carries the version, build, iOS version and device model; nothing else.
enum BetaInfo {
    static let feedbackEmail = "tuco3k@gmail.com"

    static var version: String { info("CFBundleShortVersionString") }
    static var build: String { info("CFBundleVersion") }
    static var versionLine: String { "breakZero \(version) beta (\(build))" }

    static func feedbackURL(version: String, build: String, os: String, device: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = feedbackEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: "breakZero beta feedback (\(version), build \(build))"),
            URLQueryItem(name: "body", value: "\n\n—\nbreakZero \(version) (\(build)) · iOS \(os) · \(device)")
        ]
        return c.url
    }

    /// Hardware identifier, e.g. "iPhone18,1" (no name, no serial).
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }
}
