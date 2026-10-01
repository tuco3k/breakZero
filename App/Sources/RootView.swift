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
                    // Hidden by default so the site gets the whole screen (the header strip toggles it).
                    .toolbar(model.tabBarVisible ? .visible : .hidden, for: .tabBar)
                    .tabItem { Label(p.displayName, systemImage: p.symbolName) }
                    .badge(model.unread[p] ?? 0)
                    .tag(AppTab.lite(p))
            }
            NavigationStack { WallView() }
                // Always visible on the Wall tab, so there's always a way back to the lite tabs.
                .toolbar(.visible, for: .tabBar)
                .tabItem { Label(String(localized: "Wall"), systemImage: "shield.lefthalf.filled") }
                .tag(AppTab.wall)
        }
    }
}

/// One warm web view per platform. The controller lives in the model, so switching tabs
/// doesn't tear the page down.
///
/// Layout rule: nothing of ours overlaps the site. The header strip sits *above* the web view in a
/// VStack, and the web view stays inside the safe area, so it ends above our tab bar (when shown)
/// and above the home indicator. Previously the web view ran under the tab bar and covered
/// Instagram's bottom navigation.
struct LiteTab: View {
    @Environment(AppModel.self) private var model
    let platform: Platform

    var body: some View {
        VStack(spacing: 0) {
            LiteHeaderStrip(platform: platform)
            if let reason = model.limitStatus.platformBlock[platform] {
                // The web view stays alive (and paused) underneath; nothing of it is shown.
                DoneForTodayView(platform: platform, reason: reason)
            } else if let c = model.controller(for: platform) {
                LiteWebView(controller: c)
                    .accessibilityLabel(Text("\(platform.displayName) lite view"))
            } else {
                ContentUnavailableView(String(localized: "Couldn't load filters"),
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("The \(platform.displayName) recipe failed to load. Check Diagnostics."))
            }
        }
    }
}

/// Slim native strip above a lite view: a short status message on the left (toasts), and the
/// button that shows/hides our tab bar on the right. Its own row, so it can't cover the site.
struct LiteHeaderStrip: View {
    @Environment(AppModel.self) private var model
    let platform: Platform
    @State private var showSubscriptions = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            if let toast = model.toast, toast.platform == nil || toast.platform == platform {
                Label(toast.text, systemImage: "hand.raised")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Text(platform.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let left = model.limitStatus.shortFormRemaining {
                    Text(left > 0 ? "· Reels/Shorts \(Int((left / 60).rounded(.up))) min left" : "· Reels/Shorts done today")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let left = model.limitStatus.platformRemaining[platform] {
                    Text("· \(Int((left / 60).rounded(.up))) min left today")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if platform == .youtube {
                Button { showSubscriptions = true } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Subscriptions without signing in"))
            }
            Button {
                withAnimation(.snappy) { model.tabBarVisible.toggle() }
            } label: {
                Image(systemName: model.tabBarVisible ? "chevron.down.circle" : "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.tabBarVisible ? Text("Hide tabs") : Text("Show tabs"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(.bar)
        .animation(.default, value: model.toast)
        .sheet(isPresented: $showSubscriptions) { YouTubeSubscriptionsView() }
    }
}

extension Platform {
    var displayName: String {
        switch self {
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .snapchat: "Snapchat"
        }
    }

    var symbolName: String {
        switch self {
        case .instagram: "bubble.left.and.bubble.right"
        case .youtube: "play.rectangle"
        case .snapchat: "message"
        }
    }
}
