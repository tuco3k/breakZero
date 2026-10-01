// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
import Core
import SwiftUI

/// Wall tab › Limits. Everything off by default. Every change goes through the ratchet:
/// lowering a limit or adding a block is instant; raising, adding minutes or removing waits.
struct LimitsSection: View {
    @Environment(AppModel.self) private var model
    let submit: (PolicyChange) -> Void
    @State private var addingSchedule = false

    static let dailyOptions = [15, 30, 45, 60, 90, 120, 180]
    static let budgetOptions = [5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        Section {
            ForEach(model.policy.enabledPlatforms) { p in
                Picker(selection: Binding(
                    get: { model.policy.limits.dailyMinutes[p] ?? 0 },
                    set: { submit(.setDailyLimit(p, minutes: $0 == 0 ? nil : $0)) })
                ) {
                    Text("Off").tag(0)
                    ForEach(Self.dailyOptions, id: \.self) { Text("\($0) min a day").tag($0) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(p.displayName)
                        Text("\(minutes(model.usage.platformSeconds[p])) min today").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker(selection: Binding(
                get: { model.policy.limits.shortFormMinutes },
                set: { submit(.setShortFormBudget(minutes: $0)) })
            ) {
                Text("Off (always blocked)").tag(0)
                ForEach(Self.budgetOptions, id: \.self) { Text("\($0) min a day").tag($0) }
            } label: {
                VStack(alignment: .leading) {
                    Text("Reels, Shorts and Spotlight")
                    Text("\(minutes(model.usage.shortFormSeconds)) min today, all apps together").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Time counts only while that tab is on screen. Limits reset at midnight. Lowering a limit is instant; raising one waits for the cooldown. With a Reels/Shorts budget, they work until the minutes are used, then they're blocked until tomorrow.")
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
