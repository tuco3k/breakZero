import Foundation

/// breakzero:// links. Posted in local notifications by the ShieldAction extension (which can't
/// open apps itself) and handled by the app.
public enum DeepLink {
    public static let scheme = "breakzero"
    /// userInfo key in the local notification carrying the link.
    public static let userInfoKey = "bz.deeplink"

    public static func lite(_ p: Platform) -> URL { URL(string: "\(scheme)://lite/\(p.rawValue)")! }
    public static let wall = URL(string: "\(scheme)://wall")!
    public static let pass = URL(string: "\(scheme)://pass")!
    public static let diagnostics = URL(string: "\(scheme)://diagnostics")!
}
