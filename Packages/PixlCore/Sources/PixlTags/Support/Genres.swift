// The ID3v1 genre table as TagLib 2 spells it (`ID3v1::genre(int)`), used for numeric ID3v2 `TCON` values, the
// MP4 `gnre` atom and ID3v1 tags. Verified against the strings in the Android app's bundled libtaglib.so.

import Foundation

/// TagLib's ID3v1 genre list (indices 0…191) and its name → index lookup.
public enum ID3v1Genres {
    public static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal",
        "Jazz-Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip",
        "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
        "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk",
        "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk",
        "Folk Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass",
        "Avant-garde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A Cappella", "Euro-House", "Dancehall", "Goa", "Drum & Bass", "Club-House",
        "Hardcore Techno", "Terror", "Indie", "Britpop", "Worldbeat", "Polsk Punk", "Beat", "Christian Gangsta Rap",
        "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "Jpop", "Synthpop", "Abstract", "Art Rock", "Baroque", "Bhangra", "Big Beat",
        "Breakbeat", "Chillout", "Downtempo", "Dub", "EBM", "Eclectic", "Electro", "Electroclash", "Emo",
        "Experimental", "Garage", "Global", "IDM", "Illbient", "Industro-Goth", "Jam Band", "Krautrock",
        "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk", "Post-Rock", "Psytrance",
        "Shoegaze", "Space Rock", "Trop Rock", "World Music", "Neoclassical", "Audiobook", "Audio Theatre",
        "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep", "Garage Rock", "Psybient",
    ]

    /// TagLib `ID3v1::genre(i)`: the name, or an empty string when out of range.
    public static func name(_ index: Int) -> String {
        index >= 0 && index < names.count ? names[index] : ""
    }

    /// Old spellings TagLib still maps to their index (`ID3v1::genreIndex`).
    static let legacyNames: [String: Int] = [
        "Jazz+Funk": 29, "Folk/Rock": 81, "Bebob": 85, "Avantgarde": 90, "Dance Hall": 125, "Hardcore": 129,
        "BritPop": 132, "Negerpunk": 133,
    ]

    /// TagLib `ID3v1::genreIndex(name)`: the index for a name, or 255 when unknown.
    public static func index(of name: String) -> Int {
        if let i = names.firstIndex(of: name) { return i }
        return legacyNames[name] ?? 255
    }
}
