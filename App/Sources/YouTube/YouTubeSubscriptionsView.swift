// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import SwiftUI
import UniformTypeIdentifiers

/// Login-free Subscriptions (BRIEF §6 S2 fallback): latest uploads from the channels in a Google
/// Takeout export, read from public RSS feeds. Tapping a video opens it in the YouTube lite view,
/// signed in or not. No thumbnails: text only, no extra hosts.
struct YouTubeSubscriptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = SubscriptionsState()
    @State private var importing = false
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if state.channels.isEmpty {
                    Section {
                        Text("See new videos from the channels you follow without signing in to YouTube.")
                        Text("1. On a computer, go to takeout.google.com.\n2. Choose only “YouTube and YouTube Music”, then “subscriptions”.\n3. Save subscriptions.csv to Files on this iPhone.\n4. Tap Import below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Import subscriptions.csv") { importing = true }
                    } header: { Text("No sign-in needed") }
                } else {
                    if !state.failedChannels.isEmpty {
                        Text("\(state.failedChannels.count) channels didn't load. Pull to try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.visibleVideos(includeShorts: model.youtubeListIncludesShorts)) { v in
                        Button {
                            model.openYouTube(path: v.watchPath)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).font(.body).foregroundStyle(.primary).lineLimit(3)
                                Text("\(v.channelTitle) · \(v.published.formatted(.relative(presentation: .named)))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityHint(Text("Opens in the YouTube tab"))
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            .overlay { if loading && state.videos.isEmpty { ProgressView() } }
            .refreshable { await refresh(force: true) }
            .navigationTitle(String(localized: "Subscriptions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel(Text("Import subscriptions.csv"))
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case let .success(url):
                    do {
                        let n = try model.importTakeoutCSV(from: url)
                        message = n == 0 ? String(localized: "No channels found in that file.") : String(localized: "Imported \(n) channels.")
                        Task { await refresh(force: true) }
                    } catch {
                        message = String(localized: "Couldn't read that file.")
                    }
                case .failure:
                    break
                }
            }
            .task { await refresh(force: false) }
        }
    }

    private func refresh(force: Bool) async {
        state = model.youtubeSubscriptions
        guard !state.channels.isEmpty else { return }
        loading = true
        await model.refreshYouTubeSubscriptions(force: force)
        state = model.youtubeSubscriptions
        loading = false
    }
}
