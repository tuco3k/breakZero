// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import LiteWeb
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.lock.wallDownSince != nil && !model.acknowledgedWallDown {
                RevocationView()
            } else {
                tabs
            }
        }
        .sheet(item: $model.externalURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            ForEach(model.policy.enabledPlatforms) { p in
                LiteTab(platform: p)
                    .tabItem { Label(p.displayName, systemImage: p.symbolName) }
                    .badge(model.unread[p] ?? 0)
                    .tag(AppTab.lite(p))
            }
            NavigationStack { WallView() }
                .tabItem { Label(String(localized: "Wall"), systemImage: "shield.lefthalf.filled") }
                .tag(AppTab.wall)
        }
    }
}

/// One warm web view per platform. The controller lives in the model, so switching tabs
/// doesn't tear the page down.
struct LiteTab: View {
    @Environment(AppModel.self) private var model
    let platform: Platform

    var body: some View {
        if let c = model.controller(for: platform) {
            LiteWebView(controller: c)
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityLabel(Text("\(platform.displayName) lite view"))
        } else {
            ContentUnavailableView(String(localized: "Couldn't load filters"),
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("The \(platform.displayName) recipe failed to load. Check Diagnostics."))
        }
    }
}

extension Platform {
    var displayName: String {
        switch self {
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        }
    }

    var symbolName: String {
        switch self {
        case .instagram: "bubble.left.and.bubble.right"
        case .youtube: "play.rectangle"
        }
    }
}
