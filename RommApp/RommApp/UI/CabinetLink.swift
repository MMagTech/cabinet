import Foundation

/// The URL that opens Cabinet at a particular game.
///
/// `cabinet://play?rom=123` boots the game, `cabinet://game?rom=123` opens
/// its launch screen. Two URLs rather than one carrying a flag, so a link
/// is readable on sight in a log or a crash report.
///
/// Lives here, in the shared folder, rather than beside the Apple TV's top
/// shelf where it started. The format is now spoken by four things that do
/// not all compile the same files: the top shelf extension writes it, the
/// television's deep link handler reads it, and on iPhone the widget writes
/// it and Spotlight results carry it. One definition, so a change cannot
/// reach three of them and miss the fourth.
enum CabinetLink {
    static let scheme = "cabinet"

    static func play(romId: Int) -> URL? { url(host: "play", romId: romId) }
    static func game(romId: Int) -> URL? { url(host: "game", romId: romId) }

    private static func url(host: String, romId: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "rom", value: String(romId))]
        return components.url
    }

    /// What the app got handed. Nil for anything that is not one of ours,
    /// including a well-formed URL carrying a rom id that is not a number.
    static func parse(_ url: URL) -> (romId: Int, startsPlaying: Bool)? {
        guard url.scheme == scheme,
              let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "rom" })?.value,
              let romId = Int(raw)
        else { return nil }

        switch host {
        case "play": return (romId, true)
        case "game": return (romId, false)
        default: return nil
        }
    }
}
