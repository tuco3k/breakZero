// Compiles on macOS (Xcode 27, iOS 27 SDK, 2026-10-01). Not yet run on a device (see PROGRESS.md).
import Core
import Shielding
import SwiftUI

/// Shown when Screen Time access was turned off and the wall came down. Calm, factual, no shame.
struct RevocationView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "shield.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Blocking is off").font(.title2.bold())
            Text("breakZero no longer has Screen Time access, so iOS unblocked every app it had blocked.")
                .multilineTextAlignment(.center)
            if let verified = model.lock.lastVerifiedIntact {
                Text("Last confirmed in place: \(verified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await rebuild() }
            } label: {
                Text("Turn blocking back on").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Continue without blocking") { model.acknowledgedWallDown = true }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(24)
    }

    private func rebuild() async {
        #if BZ_SCREEN_TIME && canImport(FamilyControls) && canImport(ManagedSettings) && canImport(DeviceActivity)
        do {
            try await FamilyControlsAuthorization.request()
            model.reconcile(source: "revocation.rebuild")
        } catch {
            self.error = error.localizedDescription
        }
        #endif
    }
}
