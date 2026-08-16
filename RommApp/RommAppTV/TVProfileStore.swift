#if os(tvOS)
import Foundation
import Security

/// One RomM account paired to this Apple TV. Not a system user, a RomM
/// account: see the design memory this was built against for why those are
/// kept as separate axes of identity, and why this is in-app rather than
/// tvOS's own system-level multi-user entitlement (that would partition
/// the shared ROM cache per system user, forcing a redundant re-download
/// per person of the same bytes).
struct TVProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    /// Full server URL string (scheme included), not just host: this is
    /// exactly what `Session.activateProfile(serverURL:token:localURL:)`
    /// needs, and what `Session.serverURL.absoluteString` already looks
    /// like.
    var serverURLString: String
    /// This profile's own second address, if its server has one. Belongs
    /// to the profile rather than to the device for the same reason the
    /// token does: two profiles can point at two different servers, and
    /// `Session`'s own `localServerURL` is a single app wide slot. See
    /// `Session.activateProfile` for what went wrong when this was left
    /// device wide.
    ///
    /// Optional, and that is also the whole migration path: a `Codable`
    /// struct decodes a missing key for an optional as nil, so profiles
    /// stored before this existed come back with no second address and
    /// behave exactly as they did.
    var localServerURLString: String? = nil
    /// RomM's own id for this profile's pairing, needed by the presence
    /// heartbeat. Per profile because RomM issues one per pairing, and two
    /// profiles are two pairings even on the same server. Optional, and
    /// nil for every profile paired before this was kept, which correctly
    /// turns presence off for them rather than reporting it against
    /// somebody else's device.
    var romDeviceId: String? = nil

    var host: String? { URL(string: serverURLString)?.host }

    var localServerURL: URL? { localServerURLString.flatMap { URL(string: $0) } }
}

/// Every profile paired on this Apple TV, kept completely independent of
/// `Keychain.swift`/`Session`'s own single-account storage on purpose:
/// phones are one person, so iOS never gets this at all (see
/// tvos-account-switching-design). Nothing here is reachable from iOS
/// code, and nothing in this file edits `Keychain.swift`'s format, it only
/// calls its existing public methods the same way pairing itself already
/// does.
///
/// A profile's own token lives in a separate Keychain entry, keyed by the
/// profile's own id rather than by host: two profiles on the same RomM
/// server share a host, and `Keychain.swift`'s own host-keyed storage can
/// only ever hold one token per host at a time, which is exactly the
/// collision the design doc flagged. That slot is still what `Session`
/// actually reads from; `activate(_:session:)` copies the chosen profile's
/// token into it right before asking `Session` to reload.
enum TVProfileStore {
    private static let profilesKey = "com.mmagtech.RommAppTV.profiles"
    private static let activeIDKey = "com.mmagtech.RommAppTV.activeProfileID"
    private static let tokenService = "com.mmagtech.RommAppTV.profileToken"

    static var profiles: [TVProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: profilesKey),
                  let decoded = try? JSONDecoder().decode([TVProfile].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    static var activeProfileID: UUID? {
        get {
            UserDefaults.standard.string(forKey: activeIDKey).flatMap(UUID.init)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: activeIDKey)
        }
    }

    static var activeProfile: TVProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Adds a freshly-paired profile from `TVAddProfileView`'s own
    /// standalone `RommClient` flow, independent of the live `Session`.
    /// Stored, but not activated: the switcher's list shows it and
    /// whoever is adding it decides when (or whether) to switch to it,
    /// rather than a fresh pairing silently taking over from whoever was
    /// already signed in on this Apple TV.
    static func addProfile(_ profile: TVProfile, token: String) {
        saveToken(token, for: profile.id)
        profiles.append(profile)
    }

    /// Updates a profile's label in place. Used to swap a placeholder
    /// (the server host, shown immediately) for the real RomM username
    /// once `/api/users/me` actually answers.
    static func rename(_ id: UUID, to label: String) {
        var list = profiles
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].label = label
        profiles = list
    }

    /// Replaces a profile's stored token in place, without creating a new
    /// profile or touching its label/avatar. For the one case that isn't
    /// "add" or "rename": signing out and back in through Settings'
    /// plain Sign Out (which only clears the shared Session/Keychain
    /// slot) leaves this store's own copy of that profile's token stale,
    /// pointed at a credential Keychain no longer has.
    static func syncToken(_ token: String, for id: UUID) {
        saveToken(token, for: id)
    }

    /// Fetches the real username and avatar for a profile that never got
    /// either: specifically the household's first profile when it was
    /// created by an older build, before this existed, so it is stuck
    /// showing the server host as its label and has no avatar file to
    /// load. Safe to call any time regardless (a no-op past "nothing to
    /// fetch"): it only overwrites the label if the fetch actually
    /// returns something, and it always tries the avatar since a missing
    /// file is the only signal available for "never fetched."
    static func enrichIfNeeded(_ profile: TVProfile) {
        guard let url = URL(string: profile.serverURLString), let token = token(for: profile.id) else { return }
        let needsAvatar = !FileManager.default.fileExists(atPath: avatarURL(for: profile.id).path)
        let needsLabel = profile.label == profile.host
        guard needsAvatar || needsLabel else { return }
        Task {
            let client = RommClient(baseURL: url, accessToken: token)
            guard let user = try? await client.currentUser() else { return }
            if needsLabel { rename(profile.id, to: user.username) }
            if needsAvatar, let avatar = try? await client.avatarData(userId: user.id) {
                saveAvatar(avatar, for: profile.id)
            }
        }
    }

    /// Makes `profile` the active one: its own stored token and its own
    /// second address go into the shared slots `Session` reads from, then
    /// `Session` reloads from them.
    ///
    /// The second address travels with the profile for the same reason the
    /// token does. A profile with none passes nil, which clears whatever
    /// the previous profile left behind rather than inheriting it.
    @MainActor
    static func activate(_ profile: TVProfile, session: Session) {
        guard let url = URL(string: profile.serverURLString), let token = token(for: profile.id) else { return }
        try? session.activateProfile(
            serverURL: url,
            token: token,
            localURL: profile.localServerURL,
            romDeviceId: profile.romDeviceId
        )
        activeProfileID = profile.id
    }

    /// Forgets a profile entirely: its token, and its entry in the list.
    /// Never called on the currently active profile; the switcher UI keeps
    /// that button disabled, since removing the one you are signed in as
    /// would leave `Session` pointed at a token this store no longer has a
    /// copy of.
    static func remove(_ profile: TVProfile) {
        deleteToken(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        try? FileManager.default.removeItem(at: avatarURL(for: profile.id))
    }

    // MARK: Avatar image

    /// The account's real RomM avatar photo, not a secret so it lives in
    /// the plain purgeable cache directory rather than Keychain, the same
    /// tier `CoverCache` already uses for cover art. Never guaranteed to
    /// still be there (the OS can reclaim it same as any cache), which is
    /// exactly why `TVAccountChip` falls back to a generic person icon
    /// rather than assuming this file exists.
    static func avatarURL(for id: UUID) -> URL {
        avatarsDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    static func saveAvatar(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)
        try? data.write(to: avatarURL(for: id), options: .atomic)
    }

    private static var avatarsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVProfileAvatars", isDirectory: true)
    }

    // MARK: Per-profile token storage

    private static func query(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    private static func saveToken(_ token: String, for id: UUID) {
        SecItemDelete(query(id: id) as CFDictionary)
        var attributes = query(id: id)
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func token(for id: UUID) -> String? {
        var lookup = query(id: id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken(for id: UUID) {
        SecItemDelete(query(id: id) as CFDictionary)
    }
}
#endif
