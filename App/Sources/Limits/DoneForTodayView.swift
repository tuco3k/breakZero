// UNVERIFIED: written on Linux, never compiled. Build on a Mac first (see PROGRESS.md).
import Core
import SwiftUI

/// Shown instead of a lite view when its daily limit is used up or a schedule blocks it.
/// Calm and factual. The only way to more time is a pass (purpose, wait, daily cap, logged).
struct DoneForTodayView: View {
    @Environment(AppModel.self) private var model
    let platform: Platform
    let reason: BlockReason
    @State private var askingForPass = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: reason == .schedule ? "moon.zzz" : "checkmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Request a pass")) { askingForPass = true }
                .buttonStyle(.bordered)
            Text("A pass gives you \(model.policy.pass.durationMinutes) minutes. It counts toward your \(model.policy.pass.dailyCap) passes a day.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .sheet(isPresented: $askingForPass) { LitePassView(platform: platform) }
    }

    private var title: String {
        switch reason {
        case .schedule: String(localized: "\(platform.displayName) is off right now")
        default: String(localized: "That's \(platform.displayName) for today")
        }
    }

    private var detail: String {
        switch reason {
        case .schedule:
            if let end = scheduleEnd { return String(localized: "Your schedule turns it back on at \(end).") }
            return String(localized: "Your schedule has it off for now.")
        default:
            if let end = model.limitStatus.dayEndsAt {
                return String(localized: "Your daily limit is used up. It starts again \(end.formatted(date: .omitted, time: .shortened)).")
            }
            return String(localized: "Your daily limit is used up. It starts again tomorrow.")
        }
    }

    /// End time of the active schedule window for this platform, as local "HH:mm".
    private var scheduleEnd: String? {
        guard let local = model.usage.localTime() else { return nil }
        let rule = model.policy.limits.schedules.first {
            $0.isValid && $0.target == .platform(platform) && $0.isActive(minute: local.minute, weekday: local.weekday)
        }
        guard let end = rule?.end else { return nil }
        var c = DateComponents()
        c.hour = end / 60
        c.minute = end % 60
        return Calendar.current.date(from: c)?.formatted(date: .omitted, time: .shortened)
    }
}

/// Purpose → wait → start. Same rules as native passes: cap, wait, logged on this phone only.
struct LitePassView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let platform: Platform
    @State private var purpose = ""
    @State private var request: PassRecord?
    @State private var now = Date()
    @State private var error: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                if let request {
                    Section {
                        if now < request.waitUntil {
                            Text("Wait \(Int(request.waitUntil.timeIntervalSince(now).rounded(.up))) seconds.")
                                .font(.title3.monospacedDigit())
                            Text("Still want it? You can close this and nothing is used.").foregroundStyle(.secondary)
                        } else {
                            Button(String(localized: "Start \(model.policy.pass.durationMinutes)-minute pass")) { start(request) }
                        }
                    }
                } else {
                    Section {
                        TextField(String(localized: "What do you need it for?"), text: $purpose, axis: .vertical)
                            .lineLimit(2...4)
                    } footer: {
                        Text("Saved on this phone only, with the time.")
                    }
                    Button(String(localized: "Ask for a pass")) { ask() }
                        .disabled(purpose.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "Pass for \(platform.displayName)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onReceive(timer) { now = $0 }
        }
    }

    private func ask() {
        do { request = try model.requestLitePass(platform, purpose: purpose) } catch let e as PassError {
            error = Self.describe(e)
        } catch { self.error = error.localizedDescription }
    }

    private func start(_ r: PassRecord) {
        do {
            try model.startLitePass(r.id)
            dismiss()
        } catch let e as PassError { error = Self.describe(e) } catch { self.error = error.localizedDescription }
    }

    static func describe(_ e: PassError) -> String {
        switch e {
        case let .capReached(cap): String(localized: "You've used all \(cap) passes for today.")
        case .emptyPurpose: String(localized: "Write a few words about why.")
        case .stillWaiting: String(localized: "Not yet. Wait for the timer.")
        default: String(localized: "That pass can't be used.")
        }
    }
}
