// What the chat shows for a mix `build_mix` made (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2): "Late drive · 30
// songs", Play, Save, and the chips under it. Mirrors Android's `MixCard.kt`. A plain value built from the engine's own answer: the model's
// text is never read, and a chip is a delta on the stored request applied on the device, with no model call.

import Foundation
import PixlFoundation

/// One chip under a mix card: the delta it applies to the stored request and the words it wears.
public struct MixCardChip: Sendable, Equatable, Identifiable {
    public let chip: AssistantRules.Chip
    public let label: String

    public var id: String { "\(chip.kind):\(chip.ref):\(chip.genreId)" }

    public init(chip: AssistantRules.Chip, label: String) {
        self.chip = chip
        self.label = label
    }
}

/// One track shown on a mix card.
public struct MixCardTrack: Sendable, Equatable {
    public let title: String
    public let artist: String

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

public struct MixCard: Sendable, Equatable {
    public let mixId: String
    public let title: String
    public let total: Int
    public let chips: [MixCardChip]
    public let preview: [MixCardTrack]
    /// Filters the request asked for that the data could not answer ("tempo"), so the card can say they were not applied.
    public let notApplied: [String]
    /// How many of the songs the mix was asked to follow could not be used (nothing similar to them could be had right now).
    public let seedsNotUsed: Int

    public static let previewTracks = 4

    public init(mixId: String, title: String, total: Int, chips: [MixCardChip], preview: [MixCardTrack], notApplied: [String],
                seedsNotUsed: Int = 0) {
        self.seedsNotUsed = seedsNotUsed
        self.mixId = mixId
        self.title = title
        self.total = total
        self.chips = chips
        self.preview = preview
        self.notApplied = notApplied
    }

    /// The card of `mix`: only chips that have words (a chip about a name nobody has is not offered).
    public static func of(_ mix: AssistantMix) -> MixCard {
        let chips = AssistantCards.allChips(mix.query, topArtistRef: mix.topArtistRef, topGenreId: mix.topGenreId,
                                            unsupported: mix.chipUnsupported).compactMap { chip -> MixCardChip? in
            let label = AssistantCards.chipLabel(chip, artistName: mix.topArtistName, genreName: mix.topGenreName)
            return label.isEmpty ? nil : MixCardChip(chip: chip, label: label)
        }
        return MixCard(mixId: mix.mixId, title: mix.title, total: mix.tracks.count, chips: chips,
                       preview: mix.tracks.prefix(previewTracks).map { MixCardTrack(title: $0.track.title, artist: $0.track.artist) },
                       notApplied: mix.unsupportedFilters, seedsNotUsed: mix.seedsNotUsed.count)
    }
}

/// What a mix card is doing right now (the chat holds one per card).
public struct MixCardState: Sendable, Equatable {
    /// A chip or Save is being worked out.
    public var busy = false
    public var playing = false
    public var saved = false
    /// The last chip, Play or Save did not work.
    public var failed = false

    public init(busy: Bool = false, playing: Bool = false, saved: Bool = false, failed: Bool = false) {
        self.busy = busy
        self.playing = playing
        self.saved = saved
        self.failed = failed
    }

    /// A chip came back with a new mix: the card is a different list, so it is neither playing nor saved.
    public func afterChip(succeeded: Bool) -> MixCardState {
        succeeded ? MixCardState() : MixCardState(busy: false, playing: playing, saved: saved, failed: true)
    }

    public func afterSave(succeeded: Bool) -> MixCardState {
        MixCardState(busy: false, playing: playing, saved: succeeded, failed: !succeeded)
    }

    public func afterPlay(succeeded: Bool) -> MixCardState {
        MixCardState(busy: busy, playing: succeeded, saved: saved, failed: !succeeded)
    }
}

/// The one-tap "Less trap" that ends an explanation (`AssistantCards.lessTarget`): idle, done (with the taste change's id for Undo) or failed.
public struct LessOffer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, done, failed }

    public let kind: Int
    public let name: String
    public let label: String
    public var phase: Phase
    public var adjustmentId: String?

    public init(kind: Int, name: String, label: String, phase: Phase = .idle, adjustmentId: String? = nil) {
        self.kind = kind
        self.name = name
        self.label = label
        self.phase = phase
        self.adjustmentId = adjustmentId
    }

    /// The offer for what the listener asked about, or nil when none of `named` is in their words (or has no label).
    public static func offer(userText: String, named: [AssistantCards.Named]) -> LessOffer? {
        guard let target = AssistantCards.lessTarget(userText: userText, named: named) else { return nil }
        let label = AssistantCards.lessLabel(target.name)
        return label.isEmpty ? nil : LessOffer(kind: target.kind, name: target.name, label: label)
    }

    public func tapped(adjustmentId: String?) -> LessOffer {
        var next = self
        next.phase = adjustmentId == nil ? .failed : .done
        next.adjustmentId = adjustmentId
        return next
    }

    public func undone() -> LessOffer {
        var next = self
        next.phase = .idle
        next.adjustmentId = nil
        return next
    }
}
