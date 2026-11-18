import PixlLibrary
import PixlModel

/// Where the listener starts a queue from (docs/brain-spec.md, 4.1 `surface`, 4.2): the tag `PlaybackStore.play`
/// puts on the queue's entries, so the event log knows the surface of each play. A track with one of these tags was
/// chosen by the listener; only Autoplay's picks carry an arm.
nonisolated extension BrainItemTag {
    static let album = BrainSurfaces.tag(Surface.album)
    static let artist = BrainSurfaces.tag(Surface.artist)
    static let search = BrainSurfaces.tag(Surface.search)
    static let dailyMix = BrainSurfaces.tag(Surface.dailyMix)
    static let yourMix = BrainSurfaces.tag(Surface.yourMix)
    static let homeShelf = BrainSurfaces.tag(Surface.homeShelf)
    static let assistant = BrainSurfaces.tag(Surface.assistant)

    /// A playlist, by a hash of its id (the id is the listener's own data and stays out of the log).
    static func playlist(id: String) -> BrainItemTag { BrainSurfaces.playlist(id: id) }
}
