import Core
import SwiftUI

/// "What is the Wall?": what the Lock does, in plain words built from the person's real settings and
/// this build (QUESTIONS #63). Shown the first time the Wall tab opens, from a row afterwards, and (short
/// version) as the first part of the press-and-hold confirmation. Never explains it with the word
/// "wall" or jargon; the "can't stop" list must match SECURITY_MODEL.md.
struct WallExplainer: Equatable {
    struct Point: Equatable, Hashable {
        var symbol: String
        var text: String
    }

    struct Part: Equatable, Hashable {
        var title: String
        var points: [Point]
    }

    var intro: String
    var parts: [Part]

    /// What the explanation depends on.
    struct Facts: Equatable {
        var cooldown: TimeInterval
        var grace: TimeInterval
        var lockOn: Bool
        var pass: PassRules
        var screenTimeBuild: Bool
        /// e.g. (26, 2).
        var iOS: (major: Int, minor: Int)

        static func == (a: Facts, b: Facts) -> Bool {
            a.cooldown == b.cooldown && a.grace == b.grace && a.lockOn == b.lockOn && a.pass == b.pass
                && a.screenTimeBuild == b.screenTimeBuild && a.iOS == b.iOS
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 86400 ? [.day, .hour] : (t >= 3600 ? [.hour, .minute] : [.minute])
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: t) ?? "\(Int(t / 60)) minutes"
    }

    static func make(_ x: Facts) -> WallExplainer {
        let wait = duration(x.cooldown)
        var parts: [Part] = []
        parts.append(Part(title: String(localized: "How it works"), points: [
            Point(symbol: "lock", text: String(localized: "When it's on, your current settings are locked in.")),
            Point(symbol: "bolt", text: String(localized: "You can make breakZero stricter at any time, and that takes effect right away.")),
            Point(symbol: "hourglass", text: String(localized: "Anything that makes it less strict (turning a block off, raising a time limit, showing more accounts) waits \(wait) before it applies.")),
            Point(symbol: "xmark.circle", text: String(localized: "You can cancel a waiting change anytime.")),
            Point(symbol: x.lockOn ? "checkmark.circle" : "circle",
                  text: x.lockOn ? String(localized: "Right now the Lock is on.") : String(localized: "Right now the Lock is off: every change applies right away.")),
        ]))
        parts.append(Part(title: String(localized: "Why"), points: [
            Point(symbol: "heart", text: String(localized: "The urge to undo a limit usually passes. The wait means a weak moment can't undo a decision you made with a clear head.")),
        ]))
        parts.append(Part(title: String(localized: "Hard Lock"), points: [
            Point(symbol: "calendar", text: String(localized: "Until a date you pick, nothing can be made less strict at all.")),
            Point(symbol: "clock.badge.exclamationmark", text: String(localized: "Changing the phone's clock doesn't end it early.")),
        ]))
        let passPoint: String
        if x.screenTimeBuild {
            passPoint = String(localized: "If you truly need the real app (for example to post with music), you can ask for a short pass: you say why, wait \(x.pass.waitSeconds) seconds, and get \(x.pass.durationMinutes) minutes.")
        } else {
            passPoint = String(localized: "If a time limit or schedule has stopped you and you truly need more, you can ask for a short pass: you say why, wait \(x.pass.waitSeconds) seconds, and get \(x.pass.durationMinutes) more minutes in breakZero.")
        }
        parts.append(Part(title: String(localized: "Passes"), points: [
            Point(symbol: "ticket", text: passPoint),
            Point(symbol: "number", text: String(localized: "You get \(x.pass.dailyCap) a day, and each one is saved on this phone with the reason you gave.")),
        ]))
        parts.append(Part(title: String(localized: "Changed your mind?"), points: [
            x.grace > 0
                ? Point(symbol: "arrow.uturn.backward", text: String(localized: "Right after you turn the Lock on, you have \(duration(x.grace)) to undo it instantly."))
                : Point(symbol: "arrow.uturn.backward", text: String(localized: "You turned off the undo time, so turning the Lock on can't be undone instantly.")),
        ]))
        var cant: [Point] = [
            Point(symbol: "laptopcomputer.and.iphone", text: String(localized: "Another phone, tablet or computer.")),
        ]
        if x.screenTimeBuild {
            cant.append(Point(symbol: "safari", text: String(localized: "Other browsers, unless you also block those websites in Screen Time.")))
            if (x.iOS.major, x.iOS.minor) < (26, 4) {
                cant.append(Point(symbol: "faceid", text: String(localized: "On this iPhone (iOS \(x.iOS.major).\(x.iOS.minor)), breakZero's Screen Time access can be turned off with Face ID or your passcode. iOS 26.4 or later with a Screen Time passcode makes that much harder.")))
            } else {
                cant.append(Point(symbol: "person.badge.key", text: String(localized: "Without a Screen Time passcode, breakZero's Screen Time access can be turned off with Face ID. With one set by someone you trust, it needs that passcode (still being confirmed on iOS 26.4).")))
            }
            cant.append(Point(symbol: "bell.slash", text: String(localized: "Apps you block can't send you notifications.")))
        } else {
            cant.append(Point(symbol: "trash", text: String(localized: "In this version, deleting breakZero removes the Lock and all your settings.")))
            cant.append(Point(symbol: "app.badge", text: String(localized: "In this version the real Instagram and YouTube apps, Safari and other browsers aren't blocked. Blocking them needs Apple's Screen Time permission, which this version doesn't have.")))
        }
        cant.append(Point(symbol: "hand.thumbsup", text: String(localized: "It's a speed bump for weak moments, not a prison. That's on purpose.")))
        parts.append(Part(title: String(localized: "What it can't stop"), points: cant))
        return WallExplainer(intro: String(localized: "The Wall is a lock for your settings."), parts: parts)
    }

    /// Short version for the press-and-hold confirmation.
    static func confirmation(_ x: Facts) -> [String] {
        var lines = [
            String(localized: "The Wall is a lock for your settings."),
            String(localized: "Your blocks, feed rules, time limits and passes are locked in as they are now."),
            String(localized: "Stricter changes still apply right away. Anything less strict waits \(duration(x.cooldown))."),
        ]
        if x.grace > 0 { lines.append(String(localized: "You can undo this for \(duration(x.grace)) after turning it on.")) }
        if !x.screenTimeBuild { lines.append(String(localized: "In this version, deleting breakZero removes the Lock.")) }
        return lines
    }

    /// Every sentence, for tests.
    var allText: [String] { [intro] + parts.flatMap { [$0.title] + $0.points.map(\.text) } }
}

extension WallExplainer.Facts {
    @MainActor
    init(model: AppModel) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if BZ_SCREEN_TIME
        let st = true
        #else
        let st = false
        #endif
        self.init(cooldown: model.policy.cooldown, grace: model.policy.lockGraceSeconds, lockOn: model.policy.lockEnabled,
                  pass: model.policy.pass, screenTimeBuild: st, iOS: (v.majorVersion, v.minorVersion))
    }
}

struct WallExplainerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let e = WallExplainer.make(.init(model: model))
        NavigationStack {
            List {
                Section {
                    Text(e.intro).font(.title3.weight(.semibold))
                }
                ForEach(e.parts, id: \.self) { part in
                    Section(part.title) {
                        ForEach(part.points, id: \.self) { p in
                            Label { Text(p.text) } icon: { Image(systemName: p.symbol).foregroundStyle(.tint) }
                                .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "What is the Wall?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Got it") { dismiss() } } }
        }
    }
}
