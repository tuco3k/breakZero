// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import SwiftUI

/// Wall tab › Limits. Everything off by default. Every change goes through the ratchet:
/// lowering a limit or adding a block is instant; raising, adding minutes or removing waits.
struct LimitsSection: View {
    @Environment(AppModel.self) private var model
    let submit: (PolicyChange) -> Void
    @State private var addingSchedule = false
    @State private var editing: MinutesTarget?

    /// Which limit the minutes editor is for.
    enum MinutesTarget: Identifiable, Equatable {
        case daily(Platform), dailyTotal, sharedShortForm, shortForm(Platform)
        var id: String {
            switch self {
            case let .daily(p): "daily.\(p.rawValue)"
            case .dailyTotal: "total"
            case .sharedShortForm: "shared"
            case let .shortForm(p): "short.\(p.rawValue)"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case off, perApp, together, both
        var id: String { rawValue }
    }

    private var limits: LimitsPolicy { model.policy.limits }

    private var dailyMode: Mode {
        switch (!limits.dailyMinutes.isEmpty, limits.dailyTotalMinutes != nil) {
        case (false, false): .off
        case (true, false): .perApp
        case (false, true): .together
        case (true, true): .both
        }
    }

    private var shortFormMode: Mode {
        switch (!limits.shortFormPerPlatform.isEmpty, limits.shortFormMinutes > 0) {
        case (false, false): .off
        case (true, false): .perApp
        case (false, true): .together
        case (true, true): .both
        }
    }

    var body: some View {
        Section {
            Picker(String(localized: "Daily time"), selection: Binding(get: { dailyMode }, set: setDailyMode)) {
                Text("Off").tag(Mode.off)
                Text("Per app").tag(Mode.perApp)
                Text("All apps together").tag(Mode.together)
                Text("Both").tag(Mode.both)
            }
            if dailyMode == .perApp || dailyMode == .both {
                ForEach(model.policy.enabledPlatforms) { p in
                    minutesRow(p.displayName, used: model.usage.platformSeconds[p], value: limits.dailyMinutes[p], target: .daily(p))
                }
            }
            if dailyMode == .together || dailyMode == .both {
                minutesRow(String(localized: "All apps together"), used: model.usage.totalSeconds, value: limits.dailyTotalMinutes, target: .dailyTotal)
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Time counts only while that tab is on screen. Limits reset at midnight. Lowering a limit is instant; raising one waits for the cooldown. With both, the first to run out stops you.")
        }

        Section {
            Picker(String(localized: "Reels, Shorts and Spotlight"), selection: Binding(get: { shortFormMode }, set: setShortFormMode)) {
                Text("Off (always blocked)").tag(Mode.off)
                Text("Per app").tag(Mode.perApp)
                Text("One budget for all").tag(Mode.together)
                Text("Both").tag(Mode.both)
            }
            if shortFormMode == .perApp || shortFormMode == .both {
                ForEach(model.policy.enabledPlatforms) { p in
                    minutesRow(Self.shortFormName(p), used: model.usage.shortFormPlatformSeconds[p],
                               value: limits.shortFormPerPlatform[p], target: .shortForm(p))
                }
            }
            if shortFormMode == .together || shortFormMode == .both {
                minutesRow(String(localized: "All short videos together"), used: model.usage.shortFormSeconds,
                           value: limits.shortFormMinutes > 0 ? limits.shortFormMinutes : nil, target: .sharedShortForm)
            }
        } footer: {
            Text("With a budget, Reels and Shorts work until the minutes are used, then they're blocked until tomorrow. Turning a budget on or adding minutes waits for the cooldown.")
        }
        .sheet(item: $editing) { target in
            MinutesEditor(title: title(target), initial: current(target) ?? 15) { minutes in
                apply(target, minutes)
            }
        }

        Section {
            ForEach(model.policy.limits.schedules) { rule in
                VStack(alignment: .leading) {
                    Text(Self.targetName(rule.target))
                    Text(Self.window(rule)).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(String(localized: "Remove"), role: .destructive) { submit(.removeSchedule(id: rule.id)) }
                }
                .accessibilityAction(named: Text("Remove")) { submit(.removeSchedule(id: rule.id)) }
            }
            Button { addingSchedule = true } label: { Label(String(localized: "Add a schedule"), systemImage: "plus") }
        } header: {
            Text("Schedules")
        } footer: {
            Text("Adding a schedule is instant. Removing one waits for the cooldown.")
        }
        .sheet(isPresented: $addingSchedule) { AddScheduleView(submit: submit) }
    }

    private func minutes(_ seconds: Double?) -> Int { Int(((seconds ?? 0) / 60).rounded(.down)) }

    private func minutesRow(_ title: String, used: Double?, value: Int?, target: MinutesTarget) -> some View {
        Button { editing = target } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    Text("\(minutes(used)) min today").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(value.map { "\($0) min" } ?? String(localized: "Set")).foregroundStyle(.secondary)
            }
        }
    }

    static func shortFormName(_ p: Platform) -> String {
        switch p {
        case .instagram: String(localized: "Instagram Reels")
        case .youtube: String(localized: "YouTube Shorts")
        case .snapchat: String(localized: "Snapchat Spotlight")
        }
    }

    private func title(_ t: MinutesTarget) -> String {
        switch t {
        case let .daily(p): p.displayName
        case .dailyTotal: String(localized: "All apps together")
        case .sharedShortForm: String(localized: "All short videos together")
        case let .shortForm(p): Self.shortFormName(p)
        }
    }

    private func current(_ t: MinutesTarget) -> Int? {
        switch t {
        case let .daily(p): limits.dailyMinutes[p]
        case .dailyTotal: limits.dailyTotalMinutes
        case .sharedShortForm: limits.shortFormMinutes > 0 ? limits.shortFormMinutes : nil
        case let .shortForm(p): limits.shortFormPerPlatform[p]
        }
    }

    private func apply(_ t: MinutesTarget, _ m: Int) {
        switch t {
        case let .daily(p): submit(.setDailyLimit(p, minutes: m))
        case .dailyTotal: submit(.setDailyTotal(minutes: m))
        case .sharedShortForm: submit(.setShortFormBudget(minutes: m))
        case let .shortForm(p): submit(.setPlatformShortFormBudget(p, minutes: m))
        }
    }

    /// Switching mode turns limits on (at a starting value you can edit) or off. Each change goes
    /// through the ratchet like any other.
    private func setDailyMode(_ m: Mode) {
        let wantPerApp = m == .perApp || m == .both, wantTotal = m == .together || m == .both
        if wantPerApp, limits.dailyMinutes.isEmpty {
            for p in model.policy.enabledPlatforms { submit(.setDailyLimit(p, minutes: 60)) }
        } else if !wantPerApp {
            for p in limits.dailyMinutes.keys { submit(.setDailyLimit(p, minutes: nil)) }
        }
        if wantTotal, limits.dailyTotalMinutes == nil { submit(.setDailyTotal(minutes: 120)) }
        else if !wantTotal, limits.dailyTotalMinutes != nil { submit(.setDailyTotal(minutes: nil)) }
    }

    private func setShortFormMode(_ m: Mode) {
        let wantPerApp = m == .perApp || m == .both, wantShared = m == .together || m == .both
        if wantPerApp, limits.shortFormPerPlatform.isEmpty {
            for p in model.policy.enabledPlatforms { submit(.setPlatformShortFormBudget(p, minutes: 5)) }
        } else if !wantPerApp {
            for p in limits.shortFormPerPlatform.keys { submit(.setPlatformShortFormBudget(p, minutes: nil)) }
        }
        if wantShared, limits.shortFormMinutes == 0 { submit(.setShortFormBudget(minutes: 10)) }
        else if !wantShared, limits.shortFormMinutes > 0 { submit(.setShortFormBudget(minutes: 0)) }
    }

    static func targetName(_ t: LimitTarget) -> String {
        switch t {
        case .shortForm: String(localized: "Block Reels, Shorts and Spotlight")
        case let .platform(p): String(localized: "Block \(p.displayName) entirely")
        }
    }

    static func time(_ minute: Int) -> String {
        var c = DateComponents()
        c.hour = minute / 60
        c.minute = minute % 60
        return Calendar.current.date(from: c)?.formatted(date: .omitted, time: .shortened) ?? "\(minute / 60):\(minute % 60)"
    }

    static func window(_ r: ScheduleRule) -> String {
        let days: String
        if let w = r.weekdays, w.count < 7 {
            let symbols = Calendar.current.shortWeekdaySymbols
            days = w.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
        } else {
            days = String(localized: "Every day")
        }
        return "\(time(r.start))–\(time(r.end)) · \(days)"
    }
}

struct AddScheduleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let submit: (PolicyChange) -> Void
    @State private var target: LimitTarget = .shortForm
    @State private var start = Self.date(21 * 60)
    @State private var end = Self.date(7 * 60)
    @State private var weekdays: Set<Int> = Set(1...7)

    var body: some View {
        NavigationStack {
            Form {
                Picker(String(localized: "What"), selection: $target) {
                    Text("Reels, Shorts and Spotlight").tag(LimitTarget.shortForm)
                    ForEach(model.policy.enabledPlatforms) { p in
                        Text("All of \(p.displayName)").tag(LimitTarget.platform(p))
                    }
                }
                DatePicker(String(localized: "From"), selection: $start, displayedComponents: .hourAndMinute)
                DatePicker(String(localized: "Until"), selection: $end, displayedComponents: .hourAndMinute)
                Section(String(localized: "Days")) {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.weekdaySymbols[d - 1], isOn: Binding(
                            get: { weekdays.contains(d) },
                            set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                    }
                }
            }
            .navigationTitle(String(localized: "Add a schedule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let rule = ScheduleRule(id: UUID().uuidString, target: target, start: Self.minute(start), end: Self.minute(end),
                                                weekdays: weekdays.count == 7 ? nil : weekdays)
                        submit(.addSchedule(rule))
                        dismiss()
                    }
                    .disabled(weekdays.isEmpty || Self.minute(start) == Self.minute(end))
                }
            }
        }
    }

    static func date(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    static func minute(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// Any whole number of minutes, 1–240: stepper plus typing. Nothing changes until Apply, so a
/// stepper doesn't queue a cooldown change on every tap.
struct MinutesEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var minutes: Int
    let onApply: (Int) -> Void

    init(title: String, initial: Int, onApply: @escaping (Int) -> Void) {
        self.title = title
        self._minutes = State(initialValue: min(max(initial, 1), 240))
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $minutes, in: 1...240) {
                    HStack {
                        TextField(String(localized: "Minutes"), value: $minutes, format: .number)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 80)
                            .onChange(of: minutes) { _, new in minutes = min(max(new, 1), 240) }
                        Text("min a day")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Apply")) { onApply(minutes); dismiss() }
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}
