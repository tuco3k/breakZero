// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import SwiftUI

/// "What is the wall?" — shown the first time the Wall tab opens, and from a row afterwards.
/// Plain words, short sentences. The "can't stop" part must match SECURITY_MODEL.md.
struct WallExplainerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What it does") {
                    point("hand.raised", "It hides the parts built to keep you scrolling: Reels, Shorts, Explore, suggested posts and autoplay.")
                    point("bubble.left.and.bubble.right", "Messages, people you follow, posting and search keep working.")
                    point("tortoise", "It makes loosening slow. A change that gives you more freedom waits before it happens.")
                }
                Section("Tighter now, looser later") {
                    point("bolt", "Making the wall stronger works right away.")
                    point("hourglass", "Making it weaker waits for the cooldown. That's 24 hours unless you chose another time.")
                    point("xmark.circle", "You can cancel a waiting change any time.")
                    point("arrow.down.circle", "Lowering a time limit is instant. Raising one waits.")
                }
                Section("Hard Lock") {
                    point("lock", "Pick a date. Until then, nothing can be loosened at all.")
                    point("clock.badge.exclamationmark", "Changing the phone's clock doesn't end it early.")
                }
                Section("Passes") {
                    point("ticket", "Some things need extra time or the real app. A pass gives you a few minutes.")
                    point("text.cursor", "You type why you need it, then wait a bit. Each pass is saved on this phone only.")
                    point("number", "You get a set number of passes a day.")
                }
                Section("What it can't stop") {
                    #if BZ_SCREEN_TIME
                    point("exclamationmark.triangle", "It can't stop you using another device. Other browsers still work unless you also block those websites in Screen Time.")
                    point("person.badge.key", "Anyone who can turn off breakZero's Screen Time access can take the wall down. A Screen Time passcode set by someone you trust makes that much harder.")
                    point("bell.slash", "Apps behind the wall can't send you notifications.")
                    #else
                    point("exclamationmark.triangle", "It can't stop you using another browser, the real apps, or another device.")
                    #endif
                    point("hand.thumbsup", "It's a speed bump for weak moments, not a prison. That's on purpose.")
                }
                #if !BZ_SCREEN_TIME
                Section("Off in this free build") {
                    point("app.badge", "The real Instagram and YouTube apps aren't blocked. Blocking them needs Apple's Screen Time permission (Family Controls), which this free build doesn't have.")
                    point("trash", "breakZero can't stop itself being deleted, so deleting it removes the wall.")
                    point("ticket", "Passes only add time in breakZero. They can't open the real apps.")
                    point("checkmark.seal", "Everything inside breakZero still works: the filters, the cooldown, Hard Lock and time limits.")
                }
                #endif
            }
            .navigationTitle(String(localized: "What is the wall?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Got it") { dismiss() } } }
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
            .accessibilityElement(children: .combine)
    }
}
