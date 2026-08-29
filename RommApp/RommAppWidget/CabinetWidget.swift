import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The home screen widget, in full.
///
/// Like the Apple TV's top shelf, it reads a snapshot the app left in the
/// shared app group and draws it. It makes no network calls, holds no
/// credentials, and links no part of the app beyond the two small files
/// both processes genuinely share, `WidgetSnapshot` and `CabinetLink`.
/// That is a design decision, not an accident of it being small: this
/// runs whenever the home screen wants a refresh, routinely while nobody
/// has opened Cabinet at all, and anything it had to ask a server for
/// would be a widget that goes blank whenever a self-hosted RomM is
/// asleep.
///
/// One widget kind in three sizes, configured through App Intents from
/// the start rather than static first: a static widget and a configurable
/// one are different WidgetKit types, and switching later can make people
/// re-add a widget they already placed.

/// What a placed widget shows. Three choices and no fourth: picking an
/// individual game would need library search inside the configuration
/// sheet, which is a screen, not an option.
enum WidgetShows: String, AppEnum {
    case lastPlayed
    case recents
    case favorites

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Shows" }
    static var caseDisplayRepresentations: [WidgetShows: DisplayRepresentation] { [
        .lastPlayed: "Last Played",
        .recents: "Recents",
        .favorites: "Favorites",
    ] }
}

struct CabinetWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Cabinet" }
    static var description: IntentDescription { IntentDescription("Choose what the widget shows.") }

    @Parameter(title: "Shows", default: .lastPlayed)
    var shows: WidgetShows

    /// On by default: a tinted home screen greys out every widget's
    /// pictures unless they opt out, and box art drained of its colour
    /// loses most of what makes it recognizable at a glance. Music makes
    /// the same call for album art. The toggle is for whoever tinted
    /// their home screen on purpose and wants the widget to match.
    @Parameter(title: "Full colour covers", default: true)
    var fullColourCovers: Bool
}

struct CabinetWidgetEntry: TimelineEntry {
    let date: Date
    let games: [WidgetSnapshot.Game]
    let mode: WidgetShows
    let fullColour: Bool
    /// Whether the app has ever written anything at all, which decides
    /// what an empty widget says. No snapshot means Cabinet has not run
    /// since the widget arrived; a snapshot with no favourites means
    /// nothing has been favourited, and "Open Cabinet" would be a lie
    /// about what fixes that.
    let hasSnapshot: Bool
}

struct CabinetWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CabinetWidgetEntry {
        entry(for: CabinetWidgetConfigIntent())
    }

    func snapshot(for configuration: CabinetWidgetConfigIntent, in context: Context) async -> CabinetWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: CabinetWidgetConfigIntent, in context: Context) async -> Timeline<CabinetWidgetEntry> {
        // One entry and no refresh date: the widget cannot fetch, so time
        // passing changes nothing it could show. The app reloads the
        // timelines itself whenever it writes a fresh snapshot.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: CabinetWidgetConfigIntent) -> CabinetWidgetEntry {
        NSLog("[widget] entry requested, shows=%@ fullColour=%d", configuration.shows.rawValue, configuration.fullColourCovers ? 1 : 0)
        let payload = WidgetSnapshot.read()
        let games: [WidgetSnapshot.Game]
        switch configuration.shows {
        case .lastPlayed: games = Array((payload?.games ?? []).prefix(1))
        case .recents: games = payload?.games ?? []
        case .favorites: games = payload?.favorites ?? []
        }
        return CabinetWidgetEntry(
            date: Date(),
            games: games,
            mode: configuration.shows,
            fullColour: configuration.fullColourCovers,
            hasSnapshot: payload != nil
        )
    }
}

struct CabinetWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "CabinetWidget",
            intent: CabinetWidgetConfigIntent.self,
            provider: CabinetWidgetProvider()
        ) { entry in
            CabinetWidgetView(entry: entry)
        }
        .configurationDisplayName("Cabinet")
        .description("Your last played game, recents, or favorites.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CabinetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CabinetWidgetEntry

    var body: some View {
        if entry.games.isEmpty {
            empty
        } else if entry.mode == .lastPlayed, let game = entry.games.first {
            lastPlayed(game)
        } else {
            grid
        }
    }

    // MARK: Last played

    /// The hero treatment, scaled down: art fitted over a blurred copy of
    /// itself, never cropped to fill. Box art is tall and two of the
    /// three widget shapes are not, so filling would slice the art to a
    /// strip of its middle; fitting shows all of it and the blur fills
    /// the leftovers with the art's own colours. Tapping anywhere opens
    /// the game's launch screen, not the game itself: the launch screen
    /// is where the save states are, and it is one more press for
    /// somebody who did mean to boot straight in.
    @ViewBuilder
    private func lastPlayed(_ game: WidgetSnapshot.Game) -> some View {
        let art = coverImage(game)
        Group {
            switch family {
            case .systemSmall:
                fitted(art, title: game.title)
            case .systemMedium:
                HStack(spacing: 12) {
                    fitted(art, title: game.title)
                    titleBand(game)
                    Spacer(minLength: 0)
                }
            default:
                VStack(spacing: 10) {
                    fitted(art, title: game.title)
                        .frame(maxHeight: .infinity)
                    HStack {
                        titleBand(game)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .widgetURL(CabinetLink.game(romId: game.romId))
        .containerBackground(for: .widget) {
            if let art {
                colourManaged(Image(uiImage: art).resizable())
                    .scaledToFill()
                    .blur(radius: 20)
                    .overlay(Color.black.opacity(0.15))
            } else {
                Color(.systemBackground)
            }
        }
    }

    @ViewBuilder
    private func fitted(_ art: UIImage?, title: String) -> some View {
        if let art {
            colourManaged(Image(uiImage: art).resizable())
                .scaledToFit()
        } else {
            // No art cached for this game. The title carries the card
            // rather than the row being dropped: a nameless gap reads as
            // a bug, a game with no cover does not.
            placeholderCard(title: title)
        }
    }

    private func titleBand(_ game: WidgetSnapshot.Game) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(game.title)
                .font(.headline)
                .lineLimit(2)
            Text(game.platform)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Recents and favourites

    /// How many covers fit each size, always full rows. The snapshot
    /// carries a couple more than the biggest grid draws, which is slack
    /// for games with no art, not a number to grow into.
    private var gridShape: (columns: Int, rows: Int) {
        switch family {
        case .systemSmall: return (2, 2)
        case .systemMedium: return (4, 1)
        default: return (3, 2)
        }
    }

    private var grid: some View {
        let (columns, rows) = gridShape
        let games = Array(entry.games.prefix(columns * rows))
        return VStack(spacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < games.count {
                            linked(games[index]) { tile(games[index]) }
                        } else {
                            // Keeps a short list from stretching its
                            // covers to fill the row.
                            Color.clear
                        }
                    }
                }
            }
        }
        .containerBackground(Color(.systemBackground), for: .widget)
    }

    /// One cover, cropped to its cell. The cells are near enough box
    /// art's own shape on the wide sizes that the crop is a sliver; the
    /// small widget's square cells lose more, and a quarter of a small
    /// widget is too little room to do better in.
    private func tile(_ game: WidgetSnapshot.Game) -> some View {
        Color.clear
            .overlay {
                if let art = coverImage(game) {
                    colourManaged(Image(uiImage: art).resizable())
                        .scaledToFill()
                } else {
                    placeholderCard(title: game.title)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Wraps a tile in its game's link where links work. The small
    /// widget ignores per item links by design, so its grid opens the
    /// app and no more.
    @ViewBuilder
    private func linked(_ game: WidgetSnapshot.Game, @ViewBuilder content: () -> some View) -> some View {
        if let url = CabinetLink.game(romId: game.romId) {
            Link(destination: url) { content() }
        } else {
            content()
        }
    }

    // MARK: Shared pieces

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "gamecontroller")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(entry.hasSnapshot && entry.mode == .favorites ? "No favorites yet" : "Open Cabinet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .containerBackground(Color(.systemBackground), for: .widget)
    }

    private func placeholderCard(title: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay {
                Text(title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
    }

    private func coverImage(_ game: WidgetSnapshot.Game) -> UIImage? {
        guard let file = game.coverFile, let url = WidgetSnapshot.coverURL(file) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Box art keeps its colour on a tinted home screen unless the
    /// configuration says otherwise, which is what Music does for album
    /// art: a cover drained to the accent colour is barely a cover. On an
    /// untinted home screen this changes nothing either way.
    private func colourManaged(_ image: Image) -> some View {
        image.widgetAccentedRenderingMode(entry.fullColour ? .fullColor : nil)
    }
}
