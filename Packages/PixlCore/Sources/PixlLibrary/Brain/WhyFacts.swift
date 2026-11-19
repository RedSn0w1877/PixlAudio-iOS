// The supporting facts under a reason (docs/brain-spec.md, 8.8, stage 2). A transliteration of the Android `:brain`
// module's `WhyFacts.kt`.

/// "Up to two supporting facts ('Bedroom pop . 2024 . you finished 9 of the last 10 like it')". With the data stage 2a
/// has there are three kinds of fact, each a true statement read from the listener's own log or from the pick itself:
///
///  - `keyArtistFinished`: how many of the last few plays by the pick's artist the listener finished;
///  - `keyTrackFinished`: how often they finished this very track;
///  - `keyYear`: the year the track came out, when the source said one.
///
/// Genre and mood facts need the atlas of stage 2b and are not guessed. The words live in each app's resources (D16);
/// this picks which facts are worth showing and what their arguments are.
public enum WhyFacts {
    public static let keyArtistFinished = "artist_finished"
    public static let keyTrackFinished = "track_finished"
    public static let keyYear = "year"

    public static let maxFacts = 2
    /// A rate over fewer plays than this says nothing.
    public static let minArtistPlays = 3
    /// A track finished fewer times than this is not worth a line.
    public static let minTrackFinished = 2
    /// A year outside this range is a parsing error, not a fact.
    public static let minYear = 1900
    public static let maxYear = 2100

    /// `a` and `b` are the arguments of the sentence; for a year, `a` is the year and `b` is 0.
    public struct Fact: Sendable, Equatable {
        public let key: String
        public let a: Int
        public let b: Int
    }

    /// `artistPlays` is how many of the listener's last plays by the artist were looked at (at most 10),
    /// `artistFinished` how many of those they finished; `trackFinished` is `completions` of the track (0 when it is
    /// unknown or never finished); `year` is 0 when unknown.
    ///
    /// The order is the order of how much each tells: the artist rate, then the track, then the year; a fact that is not
    /// true or not worth saying is left out, and at most `maxFacts` are returned.
    public static func pick(artistPlays: Int, artistFinished: Int, trackFinished: Int, year: Int) -> [Fact] {
        var out: [Fact] = []
        if artistPlays >= minArtistPlays && artistFinished >= 0 && artistFinished <= artistPlays {
            out.append(Fact(key: keyArtistFinished, a: artistFinished, b: artistPlays))
        }
        if out.count < maxFacts && trackFinished >= minTrackFinished {
            out.append(Fact(key: keyTrackFinished, a: trackFinished, b: 0))
        }
        if out.count < maxFacts && year >= minYear && year <= maxYear {
            out.append(Fact(key: keyYear, a: year, b: 0))
        }
        return out
    }
}
