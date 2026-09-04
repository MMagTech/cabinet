import TVServices

/// The top shelf extension, in full.
///
/// It reads a snapshot the app left behind and turns it into shelf
/// items. It makes no network calls, holds no credentials, and links no
/// part of the app. That is a design decision, not an accident of it
/// being small: this runs as a separate process whenever the Home screen
/// wants content, which is routinely before anything is signed in this
/// boot and while nobody has opened Cabinet at all. Anything it had to
/// ask a server for would be a shelf that goes blank whenever a
/// self-hosted RomM is asleep. See `docs/scope-tvos-top-shelf.md`.
///
/// Sectioned content, poster shape. The other two styles both want wide
/// art per item (1940x692 inset, a full 1920x1080 carousel) and Cabinet
/// has no wide art for any game, so both would mean inventing everything
/// either side of a portrait cover. Box art at 2:3 is what RomM already
/// stores, and a row of it is Home's own Recent shelf living on the Home
/// screen.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let games = TopShelfSnapshot.load()?.games ?? []
        let items = games.compactMap(item(for:))

        // Nil, not an empty section. Never paired, nothing played yet,
        // signed out, and every poster purged all arrive here, and for
        // all four the right answer is to say nothing and let tvOS fall
        // back to the static Top Shelf brand image already in the asset
        // catalog. An empty titled "Recent" row would be the app
        // claiming the space and then failing to fill it.
        //
        // Deliberately no "Sign in to Cabinet" or "Browse your library"
        // item either. Everything on this shelf is a game that can be
        // pressed play on, or the shelf is not there.
        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }

        let collection = TVTopShelfItemCollection(items: items)
        collection.title = "Recent"
        completionHandler(TVTopShelfSectionedContent(sections: [collection]))
    }

    private func item(for game: TopShelfSnapshot.Game) -> TVTopShelfSectionedItem? {
        // A game whose poster the system has purged is skipped rather
        // than shown with a placeholder. The app rewrites every poster
        // when it next foregrounds, so this heals itself, and a row with
        // holes punched in it looks broken in a way a shorter row does
        // not. Games that genuinely have no cover art, most of arcade,
        // never reach this: the app renders them a real placeholder
        // poster at write time, so they have a file like anything else.
        guard let posters = TopShelfSnapshot.existingPosterURLs(game) else { return nil }

        let item = TVTopShelfSectionedItem(identifier: "rom-\(game.romId)")
        item.title = game.title
        item.imageShape = .poster
        // A real file per scale rather than the 2x one handed to both
        // traits. The trait is a statement about what the file is, not a
        // request for a size, so pointing 1x at a 2x image is telling
        // the system something untrue about it and leaving the result
        // to whatever it does with that. Two files at these dimensions
        // cost a few hundred kilobytes in a directory the system can
        // purge at will.
        item.setImageURL(posters.oneX, for: .screenScale1x)
        item.setImageURL(posters.twoX, for: .screenScale2x)

        // The two actions do different things on purpose, which is what
        // they are for. Play boots the game. Select opens its launch
        // screen, where the save states are, because someone resuming
        // Tuesday's run wants that and not a fresh boot.
        if let play = CabinetLink.play(romId: game.romId) {
            item.playAction = TVTopShelfAction(url: play)
        }
        if let display = CabinetLink.game(romId: game.romId) {
            item.displayAction = TVTopShelfAction(url: display)
        }

        return item
    }
}
