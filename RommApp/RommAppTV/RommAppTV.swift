import SwiftUI

/// tvOS's own entry point, the sibling of `RommApp.swift`.
///
/// Deliberately thinner: no `AppDelegate`/`UIApplicationDelegateAdaptor`
/// (that exists on iOS only to serve orientation lock and home screen quick
/// actions, neither of which apply to a TV), and none of the Files app /
/// offline-sync wiring `RommApp.swift` does at launch and on scene phase
/// changes, since tvOS's storage model is the transient, same-network cache
/// described in the roadmap rather than a kept-games mirror. Reuses
/// `RootView`/`Session` exactly as iOS does; that is the whole shared core.
@main
struct RommAppTV: App {
    @StateObject private var session = Session()

    /// The iOS app does this from its app delegate, which this target does
    /// not compile, so tvOS did it nowhere and no game ever rumbled here.
    init() {
        GameControllerManager.installRumbleRouting()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                // The very first pairing, ServerSetupView + PairingView
                // through the live Session, is the household's first
                // profile: it already has a server and a token, there is
                // no separate "adopt" action for whoever just paired this
                // Apple TV. Without this, TVProfileStore stayed empty
                // after first setup even though the app was genuinely
                // signed in, and Add A Profile had nothing to treat as
                // "the account already on this server" to pair alongside.
                // Guarded on TVProfileStore.profiles.isEmpty so this only
                // ever backfills once, never on an ordinary reload().
                // Both onAppear and onChange are needed: onChange alone
                // misses a device that was already signed in before this
                // feature existed (session reached .ready in a previous
                // launch, so the transition already happened and will
                // never fire again), onAppear alone misses a fresh
                // install (session is not yet .ready when this view
                // first appears).
                .onAppear { syncFirstProfileIfNeeded() }
                .onChange(of: session.stage) { _, _ in syncFirstProfileIfNeeded() }
        }
    }

    /// Two cases, not one: a genuinely fresh install (`TVProfileStore` has
    /// never held anything, so this is the very first profile) and a
    /// device that already has a profile but just signed out and back in
    /// through Settings' plain "Sign out" button, which only clears the
    /// shared Session/Keychain slot, not this store's own separate copy
    /// of that profile's token. Without handling the second case, a
    /// re-pair after signing out left the stored profile pointing at a
    /// token Keychain no longer has, and every enrichment fetch against
    /// it would fail for a completely different reason than "never
    /// fetched:" a stale credential, not a missing one.
    private func syncFirstProfileIfNeeded() {
        guard session.stage == .ready,
              let url = session.serverURL, let host = url.host,
              let token = Keychain.token(forHost: host)
        else { return }

        if TVProfileStore.profiles.isEmpty {
            // Labeled with the server host immediately, so the profile
            // exists and the chip has something to show right away
            // rather than waiting on a network round trip; enriched with
            // the real username/avatar the moment that call lands.
            // Takes the session's second address with it, so the very
            // first profile owns whatever this device was set up with
            // rather than leaving it in the app wide slot for the next
            // profile to inherit. Nil today, since nothing on tvOS sets
            // one by hand.
            let profile = TVProfile(
                id: UUID(),
                label: host,
                serverURLString: url.absoluteString,
                localServerURLString: session.localServerURL?.absoluteString,
                romDeviceId: session.romDeviceId
            )
            TVProfileStore.addProfile(profile, token: token)
            TVProfileStore.activeProfileID = profile.id
            TVProfileStore.enrichIfNeeded(profile)
            return
        }

        // Already has profiles: if the active one is for this same host
        // but is holding a token that no longer matches what Session just
        // freshly obtained, that is exactly the signed-out-and-back-in
        // case. Refresh its stored token in place rather than minting a
        // second, duplicate profile for the same account.
        if let active = TVProfileStore.activeProfile, active.host == host {
            TVProfileStore.syncToken(token, for: active.id)
            TVProfileStore.enrichIfNeeded(active)
        }
    }
}
