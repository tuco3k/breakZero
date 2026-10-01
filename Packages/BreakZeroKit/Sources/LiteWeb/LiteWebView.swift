// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SafariServices
import SwiftUI
import UIKit
import WebKit

/// Hosts a controller's (long-lived) web view. The controller outlives tab switches so the view
/// stays warm; this wrapper only attaches it.
public struct LiteWebView: UIViewRepresentable {
    public let controller: LiteWebController

    public init(controller: LiteWebController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> WKWebView { controller.webView }
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// SFSafariViewController for links that leave the platform. Not our traffic: Safari's own.
public struct SafariView: UIViewControllerRepresentable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    public func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
#endif
