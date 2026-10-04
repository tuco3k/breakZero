import Core
import SwiftUI

/// Feed rules (ARCHITECTURE.md §4c rev. 2): who the Instagram feed and stories show. Mutuals by
/// default; the lists are for exceptions. Widening waits for the cooldown, narrowing is instant;
/// importing or re-syncing mutuals is data, not a rule change.
struct FeedRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var expanded: Set<PeopleGroup> = []
    @State private var showImport = false
    @State private var showSync = false

    enum PeopleGroup: String, CaseIterable, Identifiable {
        case mutuals, followingOnly, always, never, closeFriends, myList
        var id: String { rawValue }
    }

    var body: some View {
        List {
            rulesSection
            dataSection
            ForEach(PeopleGroup.allCases) { group in peopleSection(group) }
        }
        .navigationTitle(String(localized: "Feed rules"))
        .searchable(text: $search, prompt: Text("Search people"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            Button(selecting ? String(localized: "Done") : String(localized: "Select")) {
                selecting.toggle()
                if !selecting { selected = [] }
            }
        }
        .safeAreaInset(edge: .bottom) { if selecting { bulkBar } }
        .sheet(isPresented: $showImport) { ImportExportView() }
        .sheet(isPresented: $showSync) { SyncView() }
        .onAppear {
            // Short sections start open, long ones closed.
            expanded = Set(PeopleGroup.allCases.filter { names($0).count <= 20 })
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            if let recipe = model.recipes[.instagram], let f = recipe.friendsFilter {
                Toggle(String(localized: "Feed rules"), isOn: toggle(f.toggle, recipe))
                if model.feedRulesOn {
                    Picker(String(localized: "Feed shows"), selection: audience(.feed)) { audienceOptions }
                    Picker(String(localized: "Stories show"), selection: audience(.stories)) { audienceOptions }
                    if AppModel.isExperimental(model.igSettings.audience(.feed))
                        || AppModel.isExperimental(model.igSettings.audience(.stories)) {
                        Label(String(localized: "Experimental: this rule hides most posts, so the feed can load slowly and show few. “Everyone I follow” is the steady choice."),
                              systemImage: "flask")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle(isOn: Binding(get: { model.igSettings.profileStories },
                                         set: { submit([.setProfileStories(.instagram, $0)]) })) {
                        VStack(alignment: .leading) {
                            Text("Play stories from profiles I open")
                            Text("One person at a time; it never moves on to someone else.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let t = f.forceFollowingToggle {
                        Toggle(ToggleTitles.title(t), isOn: toggle(t, recipe))
                    }
                    Button(String(localized: "Use the Old Instagram preset (Experimental)")) {
                        submit([.setAudience(.instagram, .feed, .mutuals), .setAudience(.instagram, .stories, .mutuals)]
                               + (f.forceFollowingToggle.map { [.setToggle(.instagram, id: $0, on: true)] } ?? []))
                    }
                }
            }
        } footer: {
            Text("Precedence: Never show, then Always show, then the rule. Suggestions and ads are always hidden. Showing more people waits for the cooldown; showing fewer is instant.")
        }
    }

    @ViewBuilder private var audienceOptions: some View {
        ForEach(Audience.allCases, id: \.self) { a in
            Text(AppModel.isExperimental(a) ? String(localized: "\(AppModel.audienceName(a)) (Experimental)")
                                            : AppModel.audienceName(a)).tag(a)
        }
    }

    private func audience(_ s: FeedSurface) -> Binding<Audience> {
        Binding(get: { model.igSettings.audience(s) }, set: { submit([.setAudience(.instagram, s, $0)]) })
    }

    private func toggle(_ id: String, _ recipe: Recipe) -> Binding<Bool> {
        Binding(get: { model.igSettings.isOn(id, in: recipe) }, set: { submit([.setToggle(.instagram, id: id, on: $0)]) })
    }

    private func submit(_ changes: [PolicyChange]) {
        let results = model.submit(changes)
        if let p = results.lazy.compactMap({ r -> PendingChange? in if case let .queued(p) = r { return p }; return nil }).first {
            model.showToast(String(localized: "That shows more, so it applies \(p.estimatedDue.formatted(date: .abbreviated, time: .shortened))."),
                            kind: "rules.queued")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            let p = model.people
            if let days = p.daysSinceUpdate(now: Date()) {
                LabeledContent(String(localized: "Mutuals"), value: "\(p.mutuals.count)")
                Text(days == 0 ? String(localized: "Mutuals last updated today") : String(localized: "Mutuals last updated \(days) days ago"))
                    .font(.footnote).foregroundStyle(p.isStale(now: Date()) ? .orange : .secondary)
                if p.isStale(now: Date()) {
                    Text("It's been a while. New mutuals only appear after a refresh.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Text("Mutuals aren't known yet, so the Mutuals rule isn't filtering. Import your data to turn it on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { showImport = true } label: {
                Label(p.updatedAt == nil ? String(localized: "Import Instagram data (recommended)") : String(localized: "Re-import"),
                      systemImage: "square.and.arrow.down")
            }
            Button { showSync = true } label: {
                Label(model.syncRunning ? String(localized: "Sync running…") : String(localized: "Re-sync by scrolling my lists"),
                      systemImage: "arrow.triangle.2.circlepath")
            }
            DisclosureGroup(String(localized: "Other ways")) {
                Button(String(localized: "Import Close Friends")) { model.startManualScan(open: "/accounts/close_friends/") }
                Text("Opens your Close Friends list in the Instagram tab and reads the names that are checked as you scroll. Nothing is sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isScanning {
                    Button(String(localized: "Stop reading lists")) { model.stopManualScan() }
                } else {
                    Button(String(localized: "Scroll my lists by hand")) { model.startManualScan() }
                    Text("Last resort: open your Followers and Following yourself and scroll to the end. Only adds names.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Who is mutual")
        } footer: {
            Text("Stays on this phone. breakZero never asks Instagram for these lists in the background.")
        }
    }

    // MARK: People

    private func names(_ g: PeopleGroup) -> [String] {
        let p = model.people, s = model.igSettings
        switch g {
        case .mutuals: return p.mutuals.sorted()
        case .followingOnly: return p.followingOnly.sorted()
        case .always: return s.feedRules.always
        case .never: return s.feedRules.never
        case .closeFriends: return p.closeFriends.sorted()
        case .myList: return s.friends
        }
    }

    private func title(_ g: PeopleGroup) -> String {
        switch g {
        case .mutuals: String(localized: "Mutuals")
        case .followingOnly: String(localized: "Following only")
        case .always: String(localized: "Always show")
        case .never: String(localized: "Never show")
        case .closeFriends: String(localized: "Close Friends")
        case .myList: String(localized: "My list")
        }
    }

    private func filtered(_ list: [String]) -> [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        return q.isEmpty ? list : list.filter { $0.contains(q) }
    }

    @ViewBuilder
    private func peopleSection(_ g: PeopleGroup) -> some View {
        let all = names(g)
        let shown = filtered(all)
        if !all.isEmpty || g == .always || g == .never {
            Section {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(g) || !search.isEmpty },
                                                    set: { if $0 { expanded.insert(g) } else { expanded.remove(g) } })) {
                    if g == .myList || g == .always || g == .never { addField(g) }
                    ForEach(shown, id: \.self) { row($0) }
                    ForEach(model.pendingPeople(list(for: g) ?? .myList).filter { _ in list(for: g) != nil }, id: \.username) { item in
                        HStack {
                            Text("@\(item.username)").foregroundStyle(.secondary)
                            Spacer()
                            Text(item.adding ? "Adding \(item.due.formatted(date: .abbreviated, time: .shortened))"
                                             : "Removing \(item.due.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("\(title(g)) (\(all.count))").font(.headline)
                }
            }
        }
    }

    private func list(for g: PeopleGroup) -> PeopleList? {
        switch g {
        case .always: .always
        case .never: .never
        case .myList: .myList
        default: nil
        }
    }

    private func row(_ name: String) -> some View {
        let rules = model.igSettings.feedRules
        return HStack {
            if selecting {
                Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(name) ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            Text("@\(name)")
            Spacer()
            if rules.never.contains(name) { Text("Never").font(.caption).foregroundStyle(.red) }
            else if rules.always.contains(name) { Text("Always").font(.caption).foregroundStyle(.green) }
            if model.people.closeFriends.contains(name) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.green).accessibilityLabel(Text("Close friend"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggleSelected(name) } }
        .accessibilityAddTraits(selecting && selected.contains(name) ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            if rules.never.contains(name) {
                Button(String(localized: "Show")) { model.changePeople(.never, add: false, [name]) }
            } else {
                Button(String(localized: "Never show"), role: .destructive) { model.changePeople(.never, add: true, [name]) }
            }
        }
        .swipeActions(edge: .leading) {
            if rules.always.contains(name) {
                Button(String(localized: "Not always")) { model.changePeople(.always, add: false, [name]) }
            } else {
                Button(String(localized: "Always show")) { model.changePeople(.always, add: true, [name]) }.tint(.green)
            }
        }
    }

    @State private var newName: [PeopleGroup: String] = [:]

    private func addField(_ g: PeopleGroup) -> some View {
        HStack {
            TextField(String(localized: "Add by username"), text: Binding(get: { newName[g] ?? "" }, set: { newName[g] = $0 }))
                .textContentType(.username)
            Button(String(localized: "Add")) {
                if let l = list(for: g), let n = Friends.normalize(newName[g] ?? "") {
                    model.changePeople(l, add: true, [n])
                    newName[g] = ""
                }
            }
            .disabled(Friends.normalize(newName[g] ?? "") == nil)
        }
    }

    private func toggleSelected(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
    }

    // MARK: Bulk

    private var visibleNames: [String] {
        Array(Set(PeopleGroup.allCases.filter { expanded.contains($0) || !search.isEmpty }.flatMap { filtered(names($0)) })).sorted()
    }

    private var bulkBar: some View {
        HStack {
            Button(String(localized: "All")) { selected = Set(visibleNames) }
            Button(String(localized: "None")) { selected = [] }
            Spacer()
            Text("\(selected.count) selected").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Menu(String(localized: "Actions")) {
                Button(String(localized: "Always show")) { bulk(.always, add: true) }
                Button(String(localized: "Never show"), role: .destructive) { bulk(.never, add: true) }
                Button(String(localized: "Add to My list")) { bulk(.myList, add: true) }
                Divider()
                Button(String(localized: "Remove from Always show")) { bulk(.always, add: false) }
                Button(String(localized: "Remove from Never show")) { bulk(.never, add: false) }
                Button(String(localized: "Remove from My list")) { bulk(.myList, add: false) }
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func bulk(_ list: PeopleList, add: Bool) {
        model.changePeople(list, add: add, Array(selected))
        selected = []
    }
}

/// Step-by-step: request Instagram's data export, then import it here.
struct ImportExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var working = false
    @State private var summary: AppModel.ImportSummary?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "In the Instagram app or website open **Accounts Center**.")
                    step(2, "Tap **Your information and permissions** › **Download your information**.")
                    step(3, "Choose **Some of your information**, then only **Followers and following**.")
                    step(4, "Choose **Download to device**. Format: **HTML or JSON**, both work. Date range: **All time**.")
                    step(5, "Instagram emails you when it's ready (minutes to a day). Save the .zip to Files.")
                    step(6, "Come back here and import it.")
                } header: { Text("Get your data") }
                Section {
                    Button { picking = true } label: {
                        Label(String(localized: "Import the .zip or .json files"), systemImage: "doc.zipper")
                    }
                    .disabled(working)
                    if working { ProgressView(String(localized: "Reading…")) }
                    if let s = summary {
                        Label(String(localized: "\(s.mutuals) mutuals, \(s.following) following, \(s.followers) followers")
                              + (s.closeFriends.map { String(localized: ", \($0) close friends") } ?? ""),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let r = s.partialRange {
                            Label(String(localized: "This export only covers \(r.start.formatted(date: .abbreviated, time: .omitted))–\(r.end.formatted(date: .abbreviated, time: .omitted)). People you've followed for longer are missing. For the full list, request a new export with Date range: All time."),
                                  systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        if s.closeFriendsNotIncluded {
                            Label(String(localized: "Close friends weren't imported: Instagram's HTML export doesn't say who they are. Use Import Close Friends instead."),
                                  systemImage: "star.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                } footer: {
                    Text("Read on this phone only. Only the followers, following and close-friends files are opened; nothing is uploaded.")
                }
            }
            .navigationTitle(String(localized: "Import mutuals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(String(localized: "Done")) { dismiss() } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.zip, .json], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                working = true
                problem = nil
                Task {
                    defer { working = false }
                    do { summary = try await model.importExport(urls) } catch { problem = Self.describe(error) }
                }
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.headline).foregroundStyle(.secondary)
            Text(text)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? ExportImporter.Failure {
        case .notAnExport: String(localized: "No followers or following lists found. Choose the .zip from Instagram, or the followers_1.json and following.json files.")
        case .noFollowingList: String(localized: "The export has followers but no following list. Include \"Followers and following\" when you request it.")
        case .unreadableArchive: String(localized: "The .zip couldn't be read. Try downloading it again.")
        case .tooLarge: String(localized: "That file is too large. Request only \"Followers and following\".")
        case nil: (error as? PeopleData.ReplaceError) == .noFollowing
            ? String(localized: "The export has no following list.") : error.localizedDescription
        }
    }
}

/// Optional auto-scroll sync of the user's own Followers and Following.
struct SyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var owner = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Instagram can treat fast scrolling as automation. breakZero scrolls slowly, reads at most \(SyncSession.defaultCap) new names per list each time, and stops the moment Instagram shows a warning. Importing your data is safer.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
                Section {
                    TextField(String(localized: "Your Instagram username"), text: $owner)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if model.syncRunning {
                        Button(String(localized: "Stop"), role: .destructive) { model.stopSync() }
                    } else {
                        Button(model.sync?.currentList != nil && model.sync?.finished == false
                               ? String(localized: "Continue") : String(localized: "Start")) {
                            model.startSync(owner: owner)
                            dismiss()
                        }
                        .disabled(Friends.normalize(owner) == nil)
                    }
                } footer: {
                    Text("Opens your Followers, then Following, in the Instagram tab and scrolls them where you can see it.")
                }
                if let s = model.sync {
                    Section(String(localized: "Progress")) {
                        LabeledContent(String(localized: "Followers read"), value: "\(s.collected[.followers]?.count ?? 0)")
                        LabeledContent(String(localized: "Following read"), value: "\(s.collected[.following]?.count ?? 0)")
                        if let list = s.currentList, !s.finished {
                            LabeledContent(String(localized: "Now"), value: list == .followers ? String(localized: "Followers") : String(localized: "Following"))
                        }
                        if s.finished { Label(String(localized: "Finished"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        if let stop = s.lastStop { Text(Self.describe(stop)).font(.footnote).foregroundStyle(stop.isWarning ? .orange : .secondary) }
                        if !s.incompleteLists.isEmpty {
                            Text("A list ended much shorter than before, so nobody was removed from it.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Re-sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(String(localized: "Done")) { dismiss() } }
            .onAppear { owner = model.sync?.owner ?? model.people.owner ?? "" }
        }
    }

    static func describe(_ r: SyncStopReason) -> String {
        switch r {
        case .cap: String(localized: "Paused after the per-session limit. Tap Continue later.")
        case .challenge: String(localized: "Stopped: Instagram asked to confirm it's you. Do that in the Instagram tab, and wait a day before syncing again.")
        case .login: String(localized: "Stopped: Instagram asked you to log in.")
        case .warning: String(localized: "Stopped: Instagram showed a message. Try again later.")
        case .stalled: String(localized: "Stopped: nothing new loaded for a while. Try again later.")
        case .leftPage: String(localized: "Stopped because the list was closed.")
        case .userStopped: String(localized: "Stopped.")
        }
    }
}

/// What the status pill opens: who the rules hid recently, with Always show / Never show.
struct HiddenRecentlyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.recentlyHidden.isEmpty {
                    Text("Nobody hidden yet.").foregroundStyle(.secondary)
                }
                ForEach(model.recentlyHidden, id: \.self) { name in
                    HStack {
                        Text("@\(name)")
                        Spacer()
                        Button(String(localized: "Always show")) { model.changePeople(.always, add: true, [name]) }
                            .buttonStyle(.bordered)
                        Button(String(localized: "Never show")) { model.changePeople(.never, add: true, [name]) }
                            .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                }
            }
            .navigationTitle(String(localized: "Hidden recently"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(String(localized: "Done")) { dismiss() } }
        }
    }
}
