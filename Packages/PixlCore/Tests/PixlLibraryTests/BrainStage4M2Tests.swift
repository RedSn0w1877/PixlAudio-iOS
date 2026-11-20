import Foundation
import Testing
@testable import PixlLibrary
import PixlModel

/// Stage 4 milestone 2: what the listener sees under an Ask Taizo answer (mix cards, "Less X", set notes, the weekly note, the optional batch
/// checks) and the offline station sentence. The golden files prove the pure functions match Android; these tests prove the rules around them
/// (the same expectations as Android's `Stage4M2Test`, `StationSentenceTest`, `SetNoteLinesTest` and the card tests of `TaizoMusicToolsTest`).
@Suite("Stage 4 milestone 2")
struct BrainStage4M2Tests {
    // MARK: Chips and labels

    private func query(share: Int = -1, count: Int = 30, tempo: String = "any", energy: String = "any") -> AssistantRules.Query {
        AssistantRules.Query(title: "Late drive", seedRefs: ["yt:aaaaaaaaaaa"], genreIds: [], moodIds: [], yearFrom: 0, yearTo: 0, energy: energy,
                             tempo: tempo, novelty: "any", noveltySharePct: share, count: count, excludeArtistRefs: [])
    }

    @Test func chipsAreAtMostSixAndOnlyForWhatCanChangeTheRequest() {
        let chips = AssistantCards.allChips(query(), topArtistRef: "yt:aaaaaaaaaaa", topGenreId: 4, unsupported: [])
        #expect(chips.count <= AssistantCards.maxChips)
        #expect(chips.first?.kind == AssistantRules.chipLessArtist)
        // New music is at 60 already: "More new" is not offered, "More familiar" is.
        let top = AssistantCards.allChips(query(share: 60), topArtistRef: "", topGenreId: 0, unsupported: [])
        #expect(!top.contains { $0.kind == AssistantRules.chipMoreNew })
        #expect(top.contains { $0.kind == AssistantRules.chipMoreFamiliar })
        // No new music asked for: "More familiar" has nothing to do.
        let none = AssistantCards.allChips(query(share: 0), topArtistRef: "", topGenreId: 0, unsupported: [])
        #expect(!none.contains { $0.kind == AssistantRules.chipMoreFamiliar })
        // A pace chip for a filter nobody can answer is not offered; energy stands in when tempo cannot be answered.
        let noTempo = AssistantCards.allChips(query(), topArtistRef: "", topGenreId: 0, unsupported: ["tempo"])
        #expect(!noTempo.contains { $0.kind == AssistantRules.chipSlower })
        #expect(noTempo.contains { $0.kind == AssistantRules.chipLowerEnergy })
        let neither = AssistantCards.allChips(query(), topArtistRef: "", topGenreId: 0, unsupported: ["tempo", "energy"])
        #expect(!neither.contains { $0.kind == AssistantRules.chipSlower || $0.kind == AssistantRules.chipLowerEnergy })
    }

    @Test func aChipLabelNeverGuessesAName() {
        let chip = AssistantRules.Chip(kind: AssistantRules.chipLessArtist, ref: "yt:aaaaaaaaaaa")
        #expect(AssistantCards.chipLabel(chip, artistName: "Sabrina Carpenter", genreName: "") == "Less Sabrina Carpenter")
        #expect(AssistantCards.chipLabel(chip, artistName: "  ", genreName: "") == "")
        let long = AssistantCards.chipLabel(chip, artistName: "The Hierophant Green Guardians of Everything", genreName: "")
        #expect(long.hasSuffix("\u{2026}") && long.utf16.count <= "Less ".utf16.count + AssistantCards.maxName)
        #expect(AssistantCards.chipLabel(AssistantRules.Chip(kind: 99), artistName: "x", genreName: "x") == "")
    }

    @Test func lessXIsOfferedOnlyForAWholeWordTheListenerWrote() {
        let named = [AssistantCards.Named(kind: AssistantCards.namedGenre, name: "Trap"),
                     AssistantCards.Named(kind: AssistantCards.namedGenre, name: "Pop")]
        #expect(LessOffer.offer(userText: "Why do I keep getting trap?", named: named)?.label == "Less Trap")
        #expect(LessOffer.offer(userText: "why so much entrapment", named: named) == nil)
        #expect(LessOffer.offer(userText: "why so much of it", named: named) == nil)
        // The longest whole-word name wins.
        let two = named + [AssistantCards.Named(kind: AssistantCards.namedGenre, name: "Latin Trap")]
        #expect(LessOffer.offer(userText: "why do i keep getting latin trap", named: two)?.name == "Latin Trap")
    }

    @Test func aLessOfferWalksIdleDoneIdleAndFailsWithoutATasteChange() {
        let offer = LessOffer(kind: 0, name: "Trap", label: "Less Trap")
        let done = offer.tapped(adjustmentId: "a1")
        #expect(done.phase == .done && done.adjustmentId == "a1")
        #expect(done.undone() == offer)
        #expect(offer.tapped(adjustmentId: nil).phase == .failed)
    }

    // MARK: The card

    private func pick(_ n: Int, _ artist: String) -> AssistantPick {
        AssistantPick(track: AssistantTrack(ref: "yt:abcdefgh\(String(format: "%03d", n))", title: "Song \(n)", artist: artist, inLibrary: n % 2 == 0),
                      whyKey: "asked")
    }

    @Test func aMixCardIsBuiltFromTheEnginesAnswerAlone() {
        let mix = AssistantMix(mixId: "m1", title: "Late drive", tracks: (1...12).map { pick($0, "Mono") }, unsupportedFilters: ["tempo"],
                               query: query(), topArtistRef: "yt:abcdefgh001", topArtistName: "Mono", topGenreId: 7, topGenreName: "Bedroom pop")
        let card = MixCard.of(mix)
        #expect(card.title == "Late drive" && card.total == 12)
        #expect(card.preview.count == MixCard.previewTracks && card.preview[0].title == "Song 1")
        #expect(card.notApplied == ["tempo"])
        #expect(card.chips.map(\.label).prefix(2) == ["Less Mono", "More Bedroom pop"])
        #expect(!card.chips.contains { $0.chip.kind == AssistantRules.chipSlower }, "tempo could not be applied, so Slower is not offered")
        // A chip about a name the mix does not have is not shown.
        let bare = MixCard.of(AssistantMix(mixId: "m2", title: "x", tracks: [pick(1, "A")], query: query()))
        #expect(bare.chips.allSatisfy { !$0.label.isEmpty })
    }

    @Test func aCardStateKeepsPlayingAndSavedOnlyWhileTheListIsTheSame() {
        let s = MixCardState(playing: true, saved: true)
        #expect(s.afterChip(succeeded: true) == MixCardState())
        let failed = s.afterChip(succeeded: false)
        #expect(failed.failed && failed.playing && failed.saved && !failed.busy)
        #expect(MixCardState(busy: true).afterSave(succeeded: true).saved)
        #expect(MixCardState().afterPlay(succeeded: false).failed)
    }

    // MARK: Set notes

    @Test func aSetNoteIsTrueOfItsQueueOrAbsent() {
        func slot(_ artist: String, _ genre: String, _ known: Bool) -> SetNotes.Slot { SetNotes.Slot(artist: artist, genre: genre, known: known) }
        let queue = [slot("Hoang Dung", "V-pop", true), slot("Mono", "V-pop", true), slot("Orange", "v-pop", true), slot("HIEUTHUHAI", "", false),
                     slot("Clairo", "bedroom pop", true)]
        let notes = SetNotes.notes(queue)
        #expect(notes.map(SetNotes.text) == ["Three from your V-pop side, then something new from HIEUTHUHAI."])
        #expect(SetNotes.notes([]).isEmpty)
        #expect(SetNotes.notes([slot("A", "pop", true)]).isEmpty, "one known song is not a group")
        #expect(SetNotes.firstGenre("pop; rock") == "pop" && SetNotes.firstGenre(nil) == "")
    }

    // MARK: The weekly note

    private let evidence = WeeklyNote.Evidence(tracks: 25, newSongs: 18, artists: ["Mono", "HIEUTHUHAI"], genre: "Bedroom pop",
                                               island: "Soft pop & R&B", newSharePct: 22)

    @Test func theWeeklyNoteIsTheTemplateUnlessACloudAnswerIsTrueOfTheEvidence() {
        #expect(WeeklyNote.template(evidence).hasPrefix("This week's First Listen has 25 songs"))
        #expect(WeeklyNote.template(.init(tracks: 0, newSongs: -1, artists: [], genre: "", island: "", newSharePct: -1)) == "")
        let good = "This week's list has 25 songs, and 18 of them are new to your library. It opens with [[Mono]] and [[HIEUTHUHAI]]."
        #expect(WeeklyNote.check(good, evidence) == "This week's list has 25 songs, and 18 of them are new to your library. It opens with Mono and HIEUTHUHAI.")
        #expect(WeeklyNote.check("This week's list has 26 songs. It opens with [[Mono]].", evidence) == nil, "a number the evidence does not hold")
        #expect(WeeklyNote.check("This week's list has 25 songs. It opens with [[Radiohead]].", evidence) == nil, "a name the evidence does not hold")
        #expect(WeeklyNote.check("This list has 25 songs. I learned you like Mono.", evidence) == nil, "the word learn")
        #expect(WeeklyNote.check("One sentence about 25 songs.", evidence) == nil)
    }

    @Test func theWeeklyNotesEvidenceHashChangesWithTheEvidenceOnly() {
        #expect(WeeklyNote.evidenceHash(evidence) == WeeklyNote.evidenceHash(evidence))
        let other = WeeklyNote.Evidence(tracks: 26, newSongs: 18, artists: ["Mono", "HIEUTHUHAI"], genre: "Bedroom pop", island: "Soft pop & R&B", newSharePct: 22)
        #expect(WeeklyNote.evidenceHash(evidence) != WeeklyNote.evidenceHash(other))
    }

    // MARK: Words the app never says

    private let forbidden = ["lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics", "enhanced", "learn"]

    private func clean(_ text: String, _ what: String) {
        let lower = text.lowercased()
        for word in forbidden { #expect(!lower.contains(word), "\(what) says \"\(word)\": \(text)") }
    }

    @Test func noTemplateWrittenInThePureCoreUsesAWordTheAppNeverSays() {
        for kind in 0...11 {
            let chip = AssistantRules.Chip(kind: kind, ref: "yt:aaaaaaaaaaa", genreId: 5)
            clean(AssistantCards.chipLabel(chip, artistName: "Mono", genreName: "Bedroom pop"), "chip \(kind)")
        }
        for n in SetNotes.notes((0..<12).map { SetNotes.Slot(artist: "Mono", genre: $0 % 7 == 6 ? "" : "V-pop", known: $0 % 6 != 5) }) {
            clean(SetNotes.text(n), "set note")
        }
        clean(WeeklyNote.template(evidence), "weekly template")
        clean(WeeklyNote.evidenceLines(evidence), "weekly evidence")
        for name in (AssistantRules.factorNames + AssistantRules.negativeNames).compactMap({ $0 }) { clean(name, "factor") }
        clean(WeeklyNote.joinNames(["a", "b", "c"]), "names")
    }

    // MARK: The review fixes of the pure core (Android `e31f835`): unmarked names, whole-word text, negative affinities, one "Less X" target

    private func registry(_ names: [String], _ texts: [String] = []) -> Grounding.Registry {
        var r = Grounding.Registry()
        for n in names { r.addName(n) }
        for t in texts { r.addText(t) }
        return r
    }

    private func scan(_ reply: String, _ reg: Grounding.Registry, user: String = "") -> Grounding.Verdict {
        Grounding.check(reply, reg, userText: user, placeholder: "(unverified)", dropUngroundedNumbers: true, scanUnmarked: true)
    }

    private func plain(_ reply: String, _ reg: Grounding.Registry) -> Grounding.Verdict {
        Grounding.check(reply, reg, userText: "", placeholder: "(unverified)", dropUngroundedNumbers: true)
    }

    @Test func aNameWithNoMarkAndNoQuoteIsFoundBySecondPass() {
        let reg = registry(["Espresso", "Sabrina Carpenter"])
        let v = scan("You might also try Radiohead or OK Computer.", reg)
        #expect(!v.ok)
        #expect(v.ungroundedNames == ["Radiohead", "OK Computer"])
        #expect(v.cleaned == "You might also try (unverified) or (unverified).")
        // A returned name is fine bare; a sentence opener and the app's own words are not names.
        #expect(scan("Sabrina Carpenter and Espresso fit. Great. I think Taizo and Spotify agree on Monday.", reg).ok)
        // The first word of a run may be grammar ("Try Radiohead").
        #expect(scan("Try Radiohead.", reg).ungroundedNames == ["Radiohead"])
        // Part of a returned name counts ("Good Luck" of "Good Luck, Babe!").
        #expect(scan("Then comes Good Luck in the middle.", registry(["Good Luck, Babe!"])).ok)
        // Off by default: the plain check does not look for them.
        #expect(plain("You might also try Radiohead.", reg).ok)
    }

    @Test func singleQuotesAndGuillemetsAreQuotedNamesAndATextMatchesWholeWordsOnly() {
        let reg = registry([], ["{\"genre\":\"asia\"}"])
        #expect(plain("Try 'Chappell Roan' now.", reg).ungroundedNames == ["Chappell Roan"])
        #expect(plain("Try \u{00AB}Lorde\u{00BB}.", reg).ungroundedNames == ["Lorde"])
        // "Sia" is inside "asia" but is not a word of it.
        #expect(plain("Try \"Sia\".", reg).ungroundedNames == ["Sia"])
        // An apostrophe is not a quote.
        #expect(plain("It's what you don't skip.", reg).ok)
    }

    @Test func aNegativeAffinityIsSaidAsASkipAndIsNeverAReasonInItsFavour() {
        var x = [Double](repeating: 0.0, count: Ranker.d)
        x[0] = 1.0
        x[2] = -1.5
        x[8] = 1.0
        let w = Ranker.weights(p0: 0.6)
        let factors = AssistantRules.topFactors(x, w)
        let skip = factors.first { $0.name == "you often skip this artist" }
        #expect(skip != nil && skip?.up == false)
        #expect(factors.allSatisfy { $0.name != "you play this artist" })
        // With a weight of the other sign the skip would read as a reason for the pick: it is left out.
        var negW = w
        negW[2] = -abs(negW[2]) - 0.5
        #expect(AssistantRules.topFactors(x, negW).allSatisfy { $0.name != "you often skip this artist" })
    }

    @Test func aLessTargetNeedsExactlyOneNameTheListenerDidNotPraise() {
        let pair = [AssistantCards.Named(kind: 0, name: "Pop"), AssistantCards.Named(kind: 0, name: "Rock")]
        #expect(AssistantCards.lessTarget(userText: "why do I keep getting pop? I love rock though", named: pair)?.name == "Pop")
        #expect(AssistantCards.lessTarget(userText: "why do I keep getting pop and rock", named: pair) == nil)
        let trap = [AssistantCards.Named(kind: 0, name: "Trap")]
        #expect(AssistantCards.lessTarget(userText: "i love trap, why so much trap", named: trap) == nil)
    }

    @Test func aBatchAnswerThatSaysAForbiddenWordIsDropped() {
        let ins = [AssistBatch.IslandIn(id: 1, genres: ["Bedroom pop"], artists: ["Clairo"])]
        let kept = AssistBatch.validateIslandNames(ins, [AssistBatch.IslandName(id: 1, name: "Learned bedroom pop", line: "")])
        #expect(kept.isEmpty)
        let ok = AssistBatch.validateIslandNames(ins, [AssistBatch.IslandName(id: 1, name: "Dreamy bedroom pop", line: "Soft songs, 2024")])
        #expect(ok.map(\.name) == ["Dreamy bedroom pop"] && ok[0].line.isEmpty, "a line with a digit is dropped alone")
    }

    // MARK: The station sentence (no network)

    @Test func aStationRequestGivesTheNameAskedFor() {
        #expect(StationSentence.parse("Start a station from Radiohead") == "radiohead")
        #expect(StationSentence.parse("start station based on Espresso please") == "espresso")
        #expect(StationSentence.parse("play a radio of bedroom pop") == "bedroom pop")
        #expect(StationSentence.parse("Put on a station for the weeknd!") == "weeknd")
        #expect(StationSentence.parse("start me a station like \"Good Luck, Babe!\"") == "good luck, babe!")
        #expect(StationSentence.parse("station from jazz") == "jazz")
        #expect(StationSentence.parse("play some jazz radio") == "jazz")
        #expect(StationSentence.parse("start Sơn Tùng M-TP radio") == "sơn tùng m-tp")
    }

    @Test func anythingThatIsNotAStationRequestIsLeftToTheOldPath() {
        #expect(StationSentence.parse("play Radiohead") == nil)
        #expect(StationSentence.parse("what is a radio station?") == nil)
        #expect(StationSentence.parse("make me a playlist for the gym") == nil)
        #expect(StationSentence.parse("") == nil)
        #expect(StationSentence.parse("play the radio") == nil)
        #expect(StationSentence.parse("start a station from this") == nil)
        #expect(StationSentence.parse("my radio is broken, start fixing it") == nil)
        #expect(StationSentence.parse("start a station from " + String(repeating: "x", count: 80)) == nil)
    }
}

/// Set notes over a queue of songs (Android `SetNoteLinesTest`).
@Suite("Set notes on the queue")
struct SetNoteLinesTests {
    private func song(_ id: String, _ artist: String, _ genre: String?) -> Song {
        Song(id: id, title: "T\(id)", artist: artist, artistId: 1, artists: [ArtistRef(id: 1, name: artist, isPrimary: true)], album: "A",
             albumId: 1, path: "", contentUriString: "", albumArtUriString: nil, duration: 1_000, genre: genre, mimeType: nil, bitrate: nil,
             sampleRate: nil)
    }

    private func library(_ id: String, _ artist: String, _ genre: String) -> Song { song(id, artist, genre) }

    private func outside(_ id: String, _ artist: String) -> Song { song(id, artist, nil) }

    private func known(_ s: Song) -> Bool { !s.id.hasPrefix("yt") }

    @Test func threeSongsOfOneGenreAndThenANewOneReadAsOneNoteOnTheFirstOfTheThree() {
        let queue = [library("1", "Hoang Dung", "V-pop, ballad"), library("2", "Mono", "V-pop"), library("3", "Orange", "v-pop"),
                     outside("yt4", "HIEUTHUHAI"), library("5", "Clairo", "bedroom pop")]
        let notes = SetNoteLines.forQueue(queue, currentIndex: 0, isKnown: known)
        let text = "Three from your V-pop side, then something new from HIEUTHUHAI."
        #expect(notes.bySongId == ["1": text])
        #expect(notes.current == text)
    }

    @Test func theNoteIsMadeFromWhatIsStillToPlaySoItMovesWithTheCurrentSong() {
        let queue = [library("1", "A", "pop"), library("2", "B", "pop"), library("3", "C", "pop"), outside("yt4", "D")]
        let notes = SetNoteLines.forQueue(queue, currentIndex: 1, isKnown: known)
        #expect(notes.bySongId == ["2": "Two from your pop side, then something new from D."])
        #expect(notes.current == "Two from your pop side, then something new from D.")
        #expect(SetNoteLines.forQueue(queue, currentIndex: -1, isKnown: known).bySongId.isEmpty)
        #expect(SetNoteLines.forQueue([], currentIndex: 0, isKnown: known).current == nil)
        #expect(SetNoteLines.forQueue(queue, currentIndex: 3, isKnown: known).current == nil)
    }
}

/// The weekly note's one cloud call a week (Android `WeeklyNoteRepository`): counted before it is made, never offline, the template when the
/// answer is not true of the evidence, the same text for the week while the evidence is unchanged.
@Suite("Weekly note service")
struct WeeklyNoteServiceTests {
    private let evidence = WeeklyNote.Evidence(tracks: 25, newSongs: 18, artists: ["Mono", "HIEUTHUHAI"], genre: "Bedroom pop", island: "", newSharePct: 22)
    private let good = "This week's list has 25 songs, and 18 of them are new to your library. It opens with [[Mono]] and [[HIEUTHUHAI]]."

    final class Calls: @unchecked Sendable {
        var asks = 0
        var prompts: [String] = []
        var systems: [String] = []
        var answer: String?
        var allowed = true
    }

    private func service(_ calls: Calls, file: URL? = nil) -> WeeklyNoteService {
        WeeklyNoteService(file: file, mayAsk: { calls.allowed }, ask: { system, prompt, _ in
            calls.asks += 1
            calls.prompts.append(prompt)
            calls.systems.append(system)
            return calls.answer
        })
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("weekly-note-\(UUID().uuidString).json")
    }

    @Test func aTrueCloudAnswerIsKeptForTheWeekAndAskedForOnce() async {
        let calls = Calls()
        calls.answer = good
        let s = service(calls, file: tempFile())
        let first = await s.note(for: evidence, week: 7)
        let second = await s.note(for: evidence, week: 7)
        #expect(first == "This week's list has 25 songs, and 18 of them are new to your library. It opens with Mono and HIEUTHUHAI.")
        #expect(second == first)
        #expect(calls.asks == 1)
        #expect(calls.prompts.first == WeeklyNote.evidenceLines(evidence), "only the evidence rows go to the model")
    }

    @Test func anAnswerThatIsNotTrueOfTheEvidenceIsReplacedByTheTemplateAndTheWeekIsStillCounted() async {
        let calls = Calls()
        calls.answer = "This week's list has 26 songs. It opens with [[Radiohead]]."
        let s = service(calls, file: tempFile())
        let first = await s.note(for: evidence, week: 7)
        #expect(first == WeeklyNote.template(evidence))
        // A second open the same week makes no second call, even though the first answer was thrown away.
        let second = await s.note(for: evidence, week: 7)
        #expect(second == WeeklyNote.template(evidence))
        #expect(calls.asks == 1)
    }

    @Test func offlineTheCallIsNotMadeAndNotCountedSoTheNextOpenMayAsk() async {
        let calls = Calls()
        calls.allowed = false
        calls.answer = good
        let s = service(calls, file: tempFile())
        #expect(await s.note(for: evidence, week: 7) == WeeklyNote.template(evidence))
        #expect(calls.asks == 0)
        calls.allowed = true
        #expect(await s.note(for: evidence, week: 7) != WeeklyNote.template(evidence))
        #expect(calls.asks == 1)
    }

    @Test func aCrashAfterTheCountMakesNoSecondCallAndANewWeekAsksAgain() async {
        let file = tempFile()
        let calls = Calls()
        calls.answer = nil
        _ = await service(calls, file: file).note(for: evidence, week: 7)
        #expect(calls.asks == 1)
        // A new process reads the file: the week was counted before the call, so there is no second one.
        calls.answer = good
        #expect(await service(calls, file: file).note(for: evidence, week: 7) == WeeklyNote.template(evidence))
        #expect(calls.asks == 1)
        #expect(await service(calls, file: file).note(for: evidence, week: 8) != WeeklyNote.template(evidence))
        #expect(calls.asks == 2)
    }

    @Test func nothingToSayMeansNoNoteAndNoCall() async {
        let calls = Calls()
        calls.answer = good
        let empty = WeeklyNote.Evidence(tracks: 0, newSongs: -1, artists: [], genre: "", island: "", newSharePct: -1)
        #expect(await service(calls).note(for: empty, week: 1) == nil)
        #expect(calls.asks == 0)
    }

    @Test func theInstructionNeverNamesTheVendorOrAProductAndNeverClaimsToLearn() {
        let lower = WeeklyNoteService.system.lowercased()
        for word in ["claude", "anthropic", "binilyrics", "lossless", "dolby", "atmos", "enhanced"] { #expect(!lower.contains(word)) }
        #expect(WeeklyNoteService.system.contains("[[double square brackets]]"))
    }

    @Test func theEvidenceNamesTheGenreMostAdjacentPicksCarry() {
        #expect(WeeklyNoteEvidence.mostVoted([5, 7, 7, 5, 9]) == 5, "a tie goes to the lower id")
        #expect(WeeklyNoteEvidence.mostVoted([]) == GenreAtlas.none)
    }
}
