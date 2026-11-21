// Which installed voice the host speaks with. The notes are English text, so an English voice is asked for: the listener's own English
// variant first, else US English, else any other English; a voice made for fun (novelty) or built from a person's own voice is never
// used. Within a group the better quality wins, then the identifier, so the same phone always picks the same voice. Nothing here needs
// the network: the system lists only voices that are installed. The app reads the voices and hands them over; the choice is this.

public enum HostVoiceChoice {
    /// One installed voice as the system describes it. `quality` is 0 for the default one, 1 enhanced, 2 premium.
    public struct Candidate: Sendable, Equatable {
        public let identifier: String
        public let language: String
        public let quality: Int
        public let isNovelty: Bool
        public let isPersonal: Bool

        public init(identifier: String, language: String, quality: Int, isNovelty: Bool = false, isPersonal: Bool = false) {
            self.identifier = identifier
            self.language = language
            self.quality = quality
            self.isNovelty = isNovelty
            self.isPersonal = isPersonal
        }
    }

    /// "en_GB" and "en-gb" are the same tag.
    static func normal(_ tag: String) -> String {
        var out = ""
        for c in tag.lowercased() { out.append(c == "_" ? "-" : c) }
        return out
    }

    static func isEnglish(_ tag: String) -> Bool {
        let t = normal(tag)
        return t == "en" || t.hasPrefix("en-")
    }

    /// The identifier of the voice to speak with, or nil when no installed English voice can be used (the host then stays silent).
    /// `preferredLanguages` are the listener's languages in order (the first English one is their own variant).
    public static func pick(_ voices: [Candidate], preferredLanguages: [String]) -> String? {
        let own = preferredLanguages.first(where: isEnglish).map(normal)
        var best: (group: Int, quality: Int, id: String)?
        for v in voices where isEnglish(v.language) && !v.isNovelty && !v.isPersonal {
            let tag = normal(v.language)
            let group: Int
            if let own, own != "en", tag == own { group = 0 } else if tag == "en-us" { group = 1 } else { group = 2 }
            let better: Bool
            if let b = best {
                better = group != b.group ? group < b.group : (v.quality != b.quality ? v.quality > b.quality : v.identifier < b.id)
            } else {
                better = true
            }
            if better { best = (group, v.quality, v.identifier) }
        }
        return best?.id
    }
}
