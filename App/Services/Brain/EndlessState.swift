import Foundation
import Observation
import PixlLibrary
import PixlModel

/// What the screens need to know about Endless Listening besides the station itself (`BrainActions.startEndless` starts it): whether its
/// introduction was shown, the host's switch, and the facts the host's notes are made from. The port of Android's `EndlessStateHolder`.
///
/// Two small values of `UserDefaults`, read the first time something asks, never at launch. `defaults` nil keeps them in memory (UI tests).
@MainActor @Observable
final class EndlessState {
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private weak var brain: BrainService?
    @ObservationIgnored private var factsSource: HostNoteFacts?
    private var seenValue: Bool
    private var notesValue: Bool

    init(defaults: UserDefaults?, brain: BrainService?) {
        self.defaults = defaults
        self.brain = brain
        seenValue = defaults?.bool(forKey: PreferenceKeys.endlessIntroSeen) ?? false
        notesValue = defaults?.object(forKey: PreferenceKeys.endlessHostNotes) as? Bool ?? true
    }

    /// True once the three-page introduction was shown (Start listening or Not now).
    var isIntroSeen: Bool { seenValue }

    func markIntroSeen() {
        guard !seenValue else { return }
        seenValue = true
        defaults?.set(true, forKey: PreferenceKeys.endlessIntroSeen)
    }

    /// The host's short notes about the songs coming up (on by default).
    var hostNotesEnabled: Bool {
        get { notesValue }
        set {
            guard newValue != notesValue else { return }
            notesValue = newValue
            defaults?.set(newValue, forKey: PreferenceKeys.endlessHostNotes)
        }
    }

    /// True while the queue is the Endless Listening station.
    var isActive: Bool { brain?.autoplay.isEndless ?? false }

    /// True when the host's notes are to be made: the station is the queue and the switch is on.
    var wantsHostNotes: Bool { isActive && notesValue }

    /// The artwork of the first seed, for the colour of the introduction's bars; nil when there is none. One read of the seeds (cached for the
    /// day), off the main actor.
    func firstSeedArt() async -> String? {
        guard let mixes = brain?.mixes else { return nil }
        let seeds = await mixes.endlessSeeds(now: currentTimeMillis())
        return seeds.first?.song.albumArtUriString
    }

    /// What the host may say about `window` (the current song and the next few), read off the main actor from what the engine already
    /// stored; nil while Endless Listening is not the queue's station (the other queues get the set notes only).
    func hostFacts(window: [Song]) async -> SetNoteLines.HostFacts? {
        guard wantsHostNotes, !window.isEmpty, let brain else { return nil }
        if factsSource == nil {
            guard let repository = brain.repository, let mixes = brain.mixes, let atlas = brain.stage2b?.parts.atlas else { return nil }
            factsSource = HostNoteFacts(repository: repository, mixes: mixes, atlas: atlas)
        }
        guard let source = factsSource else { return nil }
        return await source.facts(window: window, why: brain.autoplay.why)
    }
}
