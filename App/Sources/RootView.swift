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
        // One toast at a time, never in the way of a tap (QUESTIONS #56).
        .overlay(alignment: .top) { ToastOverlay().allowsHitTesting(false) }
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
/// VStack. With our tab bar shown the web view ends above it (it once ran under the tab bar and
/// covered Instagram's bottom navigation); with the tab bar hidden it runs to the bottom of the screen.
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
                    // Tab bar hidden: run to the bottom edge of the screen. Otherwise the home-indicator
                    // safe area (34 pt) showed as a blank bar under Instagram's navigation. WebKit
                    // still keeps the page's fixed bars clear of the indicator (scroll view insets).
                    .ignoresSafeArea(.container, edges: model.tabBarVisible ? [] : .bottom)
                    .accessibilityLabel(Text("\(platform.displayName) lite view"))
            } else {
                ContentUnavailableView(String(localized: "Couldn't load filters"),
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("The \(platform.displayName) recipe failed to load. Check Diagnostics."))
            }
        }
    }
}

/// Slim native strip above a lite view: status on the left (feed-rules pill, time left), and the
/// button that shows/hides our tab bar on the right. Its own row, so it can't cover the site.
struct LiteHeaderStrip: View {
    @Environment(AppModel.self) private var model
    let platform: Platform
    @State private var showSubscriptions = false
    @State private var showHidden = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            if platform == .instagram, let story = model.instagramStoryUser, model.feedRulesOn {
                // While a story plays: one tap to never see this person again (narrowing, instant).
                Button { model.hideAccount(story) } label: {
                    Label(String(localized: "Hide @\(story)"), systemImage: "eye.slash")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else if platform == .instagram, model.feedRulesActive {
                Button { showHidden = true } label: {
                    Text("\(model.feedRuleName) · \(model.hiddenCount) hidden")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows who was hidden recently"))
            } else {
                Text(platform.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let left = model.limitStatus.shortFormRemaining(platform) {
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
        .sheet(isPresented: $showSubscriptions) { YouTubeSubscriptionsView() }
        .sheet(isPresented: $showHidden) { HiddenRecentlyView() }
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

/// The app's single toast: top of the screen, non-interactive, merged and short-lived (ToastCenter).
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.toasts.current {
            Text(t.text)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 52)
                .padding(.horizontal, 24)
                .transition(.opacity)
                .id(t.id)
                .accessibilityAddTraits(.updatesFrequently)
                .animation(.easeInOut(duration: 0.2), value: t.text)
        }
    }
}
