import Core
import SwiftUI

/// "Old Instagram": the Friends list that decides whose posts and stories the feed shows.
/// Adding is a loosening (waits the cooldown, except the very first friend); removing is instant
/// (except the last one, which would switch the filter off). See ARCHITECTURE.md §4c.
struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var newName = ""
    @State private var resultText: String?

    var body: some View {
        List {
            statusSection
            if !model.pendingFriendAdds.isEmpty { pendingSection }
            findSection
            if !suggestions.isEmpty { suggestionsSection }
            friendsSection
        }
        .navigationTitle(String(localized: "Old Instagram"))
        .searchable(text: $search, prompt: Text("Search friends and suggestions"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .alert(resultText ?? "", isPresented: Binding(get: { resultText != nil }, set: { if !$0 { resultText = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if let recipe = model.recipes[.instagram], let f = recipe.friendsFilter {
                Toggle(isOn: toggleBinding(f.toggle, recipe)) {
                    VStack(alignment: .leading) {
                        Text("Friends only")
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let t = f.forceFollowingToggle {
                    Toggle(ToggleTitles.title(t), isOn: toggleBinding(t, recipe))
                }
            }
        } footer: {
            Text("Your home feed and stories show only the people on this list. Brands, creators, suggestions and ads are hidden. Messages, search, posting and any profile you open still work. The list stays on this phone.")
        }
    }

    private var statusLine: String {
        if model.friends.isEmpty { return String(localized: "Turns on when you add your first friend.") }
        let n = model.friends.count
        let count = n == 1 ? String(localized: "1 friend") : String(localized: "\(n) friends")
        return model.friendsActive ? String(localized: "On · \(count)") : String(localized: "Off · \(count)")
    }

    private var pendingSection: some View {
        Section {
            ForEach(model.pendingFriendAdds, id: \.username) { item in
                HStack {
                    Text("@\(item.username)")
                    Spacer()
                    Text("About \(item.due.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Waiting to be added")
        } footer: {
            Text("Adding someone loosens the wall, so it waits for the cooldown. Cancel it in the Wall tab.")
        }
    }

    private var findSection: some View {
        Section {
            if model.isScanning {
                Label(String(localized: "Reading the lists you open"), systemImage: "list.bullet.rectangle")
                Text("In the Instagram tab: open your profile, tap Followers and scroll to the end, then do the same for Following. Only names already on your screen are read; nothing is downloaded in the background.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(String(localized: "Stop reading")) { model.stopFriendsScan() }
            } else {
                Button {
                    model.startFriendsScan()
                } label: {
                    Label(String(localized: "Find friends in Followers and Following"), systemImage: "person.2")
                }
                Button {
                    model.startFriendsScan(open: "/accounts/close_friends/")
                } label: {
                    Label(String(localized: "Import Close Friends"), systemImage: "star.circle")
                }
            }
            if let line = scanSummary {
                Text(line).font(.footnote).foregroundStyle(.secondary)
                Button(String(localized: "Clear what was read"), role: .destructive) { model.clearFriendsScan() }
            }
        } header: {
            Text("Find friends")
        } footer: {
            Text("People who follow you and whom you follow (and your Close Friends) become suggestions. You choose who to add.")
        }
    }

    private var scanSummary: String? {
        let s = model.friendsScan
        guard s.updatedAt != nil else { return nil }
        var parts: [String] = []
        if let owner = s.owner {
            parts.append(String(localized: "@\(owner): \(s.followers.count) followers and \(s.following.count) following read, \(s.mutuals.count) in both"))
        }
        if !s.closeFriends.isEmpty { parts.append(String(localized: "\(s.closeFriends.count) close friends")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var suggestions: [String] {
        filter(model.friendSuggestions).filter { name in !model.pendingFriendAdds.contains { $0.username == name } }
    }

    private var suggestionsSection: some View {
        Section {
            ForEach(suggestions, id: \.self) { name in
                HStack {
                    Text("@\(name)")
                    if model.friendsScan.closeFriends.contains(name) {
                        Image(systemName: "star.fill").foregroundStyle(.green).accessibilityLabel(Text("Close friend"))
                    }
                    Spacer()
                    Button(String(localized: "Add")) { add([name]) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Add \(name)"))
                }
            }
            if suggestions.count > 1 {
                Button(String(localized: "Add all \(suggestions.count)")) { add(suggestions) }
            }
        } header: {
            Text("Suggestions")
        }
    }

    private var friendsSection: some View {
        Section {
            HStack {
                TextField(String(localized: "Add by username"), text: $newName)
                    .textContentType(.username)
                    .onSubmit(addTyped)
                Button(String(localized: "Add"), action: addTyped)
                    .disabled(Friends.normalize(newName) == nil)
            }
            ForEach(filter(model.friends), id: \.self) { name in
                Text("@\(name)")
                    .swipeActions {
                        Button(String(localized: "Remove"), role: .destructive) { remove(name) }
                    }
                    .accessibilityAction(named: Text("Remove")) { remove(name) }
            }
        } header: {
            Text("Friends (\(model.friends.count))")
        } footer: {
            Text("Removing someone applies right away.")
        }
    }

    // MARK: Actions

    private func filter(_ names: [String]) -> [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        return q.isEmpty ? names : names.filter { $0.contains(q) }
    }

    private func toggleBinding(_ id: String, _ recipe: Recipe) -> Binding<Bool> {
        Binding(get: { model.policy.settings(for: .instagram).isOn(id, in: recipe) },
                set: { show(model.submit([.setToggle(.instagram, id: id, on: $0)])) })
    }

    private func addTyped() {
        guard let name = Friends.normalize(newName) else { return }
        add([name])
        newName = ""
    }

    private func add(_ names: [String]) {
        show(model.addFriends(names))
    }

    private func remove(_ name: String) {
        if let r = model.removeFriend(name) { show([r]) }
    }

    /// Say what happened only when something didn't apply right away.
    private func show(_ results: [SubmitResult]) {
        let queued = results.compactMap { r -> PendingChange? in if case let .queued(p) = r { return p }; return nil }
        if let hard = results.lazy.compactMap({ r -> Date? in if case let .rejectedHardLock(d) = r { return d }; return nil }).first {
            resultText = String(localized: "Hard Lock is on until \(hard.formatted(date: .abbreviated, time: .shortened)). Nothing can be loosened before then.")
        } else if let first = queued.first {
            resultText = queued.count == 1
                ? String(localized: "That loosens the wall, so it applies \(first.estimatedDue.formatted(date: .abbreviated, time: .shortened)). You can cancel it until then.")
                : String(localized: "\(queued.count) changes loosen the wall, so they apply \(first.estimatedDue.formatted(date: .abbreviated, time: .shortened)). You can cancel them until then.")
        } else if let why = results.lazy.compactMap({ r -> String? in if case let .rejectedInvalid(w) = r { return w }; return nil }).first {
            resultText = why
        }
    }
}
