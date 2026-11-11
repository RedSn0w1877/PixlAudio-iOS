import Foundation
import Testing
@testable import PixlModel

/// The contract of Spatial audio (docs/handoff/2026-11-10-plans/cloud-audio-spec.md): ids, settings, statuses,
/// library keys, the render manifest and the two service seams. Every expected value here is copied from the spec,
/// so a change on either side shows up as a failing test.
enum CloudAudioFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/cloud-audio"))
        return try Data(contentsOf: url)
    }

    static func manifest(_ name: String = "manifest.spatial") throws -> CloudLibraryManifest {
        try CloudLibraryManifest.decode(try data(name))
    }

    static let videoId = "J7p4bzqLvCw"
}

@Suite("Spatial profiles and selection")
struct SpatialProfileTests {
    @Test func theSixProfilesHaveTheSpecsIdsInTheSpecsOrder() {
        #expect(SpatialProfile.allCases.map(\.rawValue) == ["studio", "wide", "intimate", "hall", "surround", "night"])
        #expect(SpatialProfile.default == .studio)
        #expect(SpatialProfile(id: "hall") == .hall)
        #expect(SpatialProfile(id: "Hall") == nil)
        #expect(SpatialProfile(id: "off") == nil)
    }

    @Test func namesAndOneLinersAreTheSpecs() {
        #expect(SpatialProfile.allCases.map(\.displayName) == ["Studio", "Wide", "Intimate", "Concert Hall", "Surround", "Night"])
        #expect(SpatialProfile.studio.summary == "Clean and close, like good speakers in a quiet room.")
        #expect(SpatialProfile.wide.summary == "Instruments pushed out to the sides.")
        #expect(SpatialProfile.intimate.summary == "The voice right in front of you.")
        #expect(SpatialProfile.hall.summary == "A big room, a few rows back.")
        #expect(SpatialProfile.surround.summary == "Sound beside and behind you.")
        #expect(SpatialProfile.night.summary == "Softer and gentler for late listening.")
    }

    @Test func noShownTextUsesAWordTheSpecForbids() {
        let forbidden = ["lossless", "hi-res", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics",
                         "enhanced"]
        var shown = SpatialProfile.allCases.flatMap { [$0.displayName, $0.summary] }
        shown += SpatialStatusLine.allCases.compactMap(\.text)
        shown.append(SpatialCopy.levelNote)
        #expect(shown.count == 12 + 9 + 1)
        for text in shown {
            for word in forbidden { #expect(!text.lowercased().contains(word), "\(text) contains \(word)") }
        }
    }

    @Test func aSelectionIsOffOrAProfileAndUnknownTextIsOff() {
        #expect(SpatialSelection(storageValue: nil) == .off)
        #expect(SpatialSelection(storageValue: "off") == .off)
        #expect(SpatialSelection(storageValue: "night") == .profile(.night))
        #expect(SpatialSelection(storageValue: "cathedral") == .off)
        #expect(SpatialSelection.off.storageValue == "off")
        #expect(SpatialSelection.profile(.wide).storageValue == "wide")
        #expect(SpatialSelection.profile(.wide).isOn)
        #expect(!SpatialSelection.off.isOn)
        #expect(SpatialSelection.allChoices.count == 7)
        #expect(SpatialSelection.allChoices.first == .off)
        for choice in SpatialSelection.allChoices {
            #expect(SpatialSelection(storageValue: choice.storageValue) == choice)
        }
    }
}

@Suite("Route rule and level rule")
struct SpatialRulesTests {
    @Test func headphonesModeTakesWiredBluetoothAndUSBOnly() {
        let passing: Set<SpatialOutputKind> = [.wiredHeadphones, .bluetooth, .usbHeadset]
        for output in SpatialOutputKind.allCases {
            #expect(SpatialActivation.routePasses(mode: .headphones, output: output) == passing.contains(output))
        }
    }

    @Test func alwaysModeTakesEveryOutputOfThisPhoneButNeverADeviceThatPlaysItself() {
        for output in SpatialOutputKind.allCases {
            #expect(SpatialActivation.routePasses(mode: .always, output: output) == (output != .remote))
        }
    }

    @Test func theRouteModeDefaultsToHeadphones() {
        #expect(SpatialRouteMode(storageValue: nil) == .headphones)
        #expect(SpatialRouteMode(storageValue: "always") == .always)
        #expect(SpatialRouteMode(storageValue: "speakers") == .headphones)
    }

    @Test func activeNeedsAProfileThePassingRouteAndSingOff() {
        func active(_ selection: SpatialSelection, _ output: SpatialOutputKind, sing: Bool) -> Bool {
            SpatialActivation.isActive(selection: selection, mode: .headphones, output: output, singInstrumentalOn: sing)
        }
        #expect(active(.profile(.studio), .bluetooth, sing: false))
        #expect(!active(.off, .bluetooth, sing: false))
        #expect(!active(.profile(.studio), .phoneSpeaker, sing: false))
        #expect(!active(.profile(.studio), .bluetooth, sing: true))
    }

    @Test func theLevelRuleGivesTheHeadroomBackCappedAtUnity() {
        // 10^(4/20) = 1.585 (the spec's factor).
        #expect(abs(SpatialLevel.linear(db: 4) - 1.585) < 0.001)
        // No normalisation: the gain stays 1, so Spatial is 4 dB quieter and nothing clips.
        #expect(SpatialLevel.playbackGain(1, headroomDb: 4) == 1)
        // Normalisation pulls the song down 6 dB: 4 dB of it comes back.
        let reduced = Float(SpatialLevel.linear(db: -6))
        #expect(abs(SpatialLevel.playbackGain(reduced, headroomDb: 4) - Float(SpatialLevel.linear(db: -2))) < 1e-5)
        // Down exactly 4 dB: exactly unity.
        #expect(abs(SpatialLevel.playbackGain(Float(SpatialLevel.linear(db: -4)), headroomDb: 4) - 1) < 1e-5)
        // Down 2 dB: capped.
        #expect(SpatialLevel.playbackGain(Float(SpatialLevel.linear(db: -2)), headroomDb: 4) == 1)
        // No headroom, or a broken value: the gain is unchanged.
        #expect(SpatialLevel.playbackGain(0.5, headroomDb: 0) == 0.5)
        #expect(SpatialLevel.playbackGain(0.5, headroomDb: -3) == 0.5)
        #expect(SpatialLevel.playbackGain(0.5, headroomDb: .nan) == 0.5)
        #expect(SpatialLevel.defaultHeadroomDb == 4.0)
    }
}

@Suite("Cloud audio settings")
struct CloudAudioSettingsTests {
    @Test func theKeysAreTheSpecsNames() {
        #expect(CloudAudioSettingsKey.all == ["spatial.profile", "spatial.route", "spatial.cloud", "spatial.prepareAhead",
                                              "cloudAudio.storageMB", "cloudAudio.monthlyCapUSD", "cloudAudio.dailyAhead"])
        #expect(Set(CloudAudioSettingsKey.all).count == 7)
    }

    @Test func theDefaultsAreTheSpecs() {
        let settings = CloudAudioSettings(stored: CloudAudioStoredSettings(), builtInCloudKeys: true)
        #expect(settings.profile == .off)
        #expect(settings.route == .headphones)
        #expect(settings.cloud)
        #expect(settings.prepareAhead)
        #expect(settings.storageMB == 3072)
        #expect(settings.monthlyCapUSD == 30)
        #expect(settings.dailyAhead == 25)
        #expect(settings == CloudAudioSettings(builtInCloudKeys: true))
        #expect(settings.storageBytes == 3072 * 1_048_576)
        #expect(settings.monthlyCapMicroUSD == 30_000_000)
    }

    @Test func theCloudIsOnByDefaultOnlyWithBuiltInKeysAndAChoiceWins() {
        #expect(!CloudAudioSettings(stored: CloudAudioStoredSettings(), builtInCloudKeys: false).cloud)
        #expect(CloudAudioSettings(stored: CloudAudioStoredSettings(cloud: true), builtInCloudKeys: false).cloud)
        #expect(!CloudAudioSettings(stored: CloudAudioStoredSettings(cloud: false), builtInCloudKeys: true).cloud)
    }

    @Test func storedValuesAreReadAndBroughtInsideTheirRanges() {
        let stored = CloudAudioStoredSettings(profile: "hall", route: "always", cloud: false, prepareAhead: false,
                                              storageMB: 1, monthlyCapUSD: 500, dailyAhead: 0)
        let settings = CloudAudioSettings(stored: stored, builtInCloudKeys: true)
        #expect(settings.profile == .profile(.hall))
        // A stored `always` is honoured whether or not Developer mode is on.
        #expect(settings.route == .always)
        #expect(!settings.cloud)
        #expect(!settings.prepareAhead)
        // 256 … 65536 MB, up to 200 dollars, 1 … 100 songs a day (the spec's stored forms).
        #expect(settings.storageMB == 256)
        #expect(settings.monthlyCapUSD == 200)
        #expect(settings.dailyAhead == 1)
        #expect(CloudAudioSettings.clampedStorageMB(10_000_000) == 65_536)
        #expect(CloudAudioSettings.clampedDailyAhead(1_000) == 100)
    }

    @Test func noLimitIsStoredAsMinusOne() {
        #expect(CloudAudioSettings.noLimitStoredValue == -1)
        #expect(CloudAudioSettings.monthlyCap(fromStored: -1) == nil)
        // Something that is not a number was nobody's choice: the default, never "no limit".
        #expect(CloudAudioSettings.monthlyCap(fromStored: .nan) == 30)
        #expect(CloudAudioSettings.monthlyCap(fromStored: .infinity) == 30)
        #expect(CloudAudioSettings.monthlyCap(fromStored: -.infinity) == 30)
        #expect(CloudAudioSettings.storedMonthlyCap(.nan) == 30)
        #expect(CloudAudioSettings.monthlyCap(fromStored: 0) == 0)
        #expect(CloudAudioSettings.monthlyCap(fromStored: 75) == 75)
        #expect(CloudAudioSettings.storedMonthlyCap(nil) == -1)
        #expect(CloudAudioSettings.storedMonthlyCap(1_000) == 200)
        var settings = CloudAudioSettings(builtInCloudKeys: true)
        settings.monthlyCapUSD = nil
        #expect(settings.monthlyCapMicroUSD == nil)
        #expect(CloudAudioSettings(stored: settings.stored, builtInCloudKeys: true).monthlyCapUSD == nil)
    }

    @Test func aFullWriteReadsBackTheSame() {
        var settings = CloudAudioSettings(builtInCloudKeys: false)
        settings.profile = .profile(.surround)
        settings.route = .always
        settings.cloud = true
        settings.prepareAhead = false
        settings.storageMB = 8192
        settings.monthlyCapUSD = 120
        settings.dailyAhead = 40
        #expect(CloudAudioSettings(stored: settings.stored, builtInCloudKeys: false) == settings)
        #expect(settings.stored.profile == "surround")
        #expect(settings.stored.route == "always")
    }
}

@Suite("Renditions")
struct RenditionTests {
    @Test func aSlotIsTheFileStemAndTheManifestSlot() {
        #expect(RenditionKey(videoId: "J7p4bzqLvCw", profile: .studio).slot == "sp-studio")
        #expect(RenditionKey.slot(.hall) == "sp-hall")
        for profile in SpatialProfile.allCases {
            #expect(RenditionKey.profile(slot: RenditionKey.slot(profile)) == profile)
        }
        #expect(RenditionKey.profile(slot: "sp-cathedral") == nil)
        #expect(RenditionKey.profile(slot: "instrumental") == nil)
        #expect(RenditionKey.profile(slot: "sp-") == nil)
        #expect(RenditionKey.profile(slot: "studio") == nil)
        #expect(RenditionKey.manifestKind == "spatial")
        #expect(RenditionKey(videoId: "J7p4bzqLvCw", profile: .wide).description == "J7p4bzqLvCw/sp-wide")
    }

    @Test func theStatusesAreTheSpecsWithQueuedAsThreeCasesInAndroidsOrder() {
        // Android's `SpatialRenditionStatus`: NONE, PREVIEW, QUEUED, WAITING_FOR_NETWORK, CAP_REACHED, PROCESSING,
        // DOWNLOADING, READY, FAILED.
        #expect(RenditionStatus.allCases.map(\.rawValue)
            == ["none", "preview", "queued", "waitingForNetwork", "capReached", "processing", "downloading", "ready",
                "failed"])
        // The spec's `queued`, with or without a reason.
        let queued: Set<RenditionStatus> = [.queued, .waitingForNetwork, .capReached]
        for status in RenditionStatus.allCases {
            #expect(status.isQueued == queued.contains(status), "\(status)")
        }
    }

    @Test func theShownStatusIsTheLibrarysOnceTheCloudIsInvolvedElsePreviewWhileTheStagePlays() {
        #expect(RenditionStatus.none.shown(onDeviceAudible: true) == .preview)
        #expect(RenditionStatus.none.shown(onDeviceAudible: false) == RenditionStatus.none)
        #expect(RenditionStatus.preview.shown(onDeviceAudible: false) == RenditionStatus.none)
        #expect(RenditionStatus.preview.shown(onDeviceAudible: true) == .preview)
        for status in RenditionStatus.allCases where status != .none && status != .preview {
            #expect(status.shown(onDeviceAudible: true) == status, "\(status)")
            #expect(status.shown(onDeviceAudible: false) == status, "\(status)")
        }
    }

    @Test func failuresAreRetriedAfterTenMinutesAnHourThenADay() {
        #expect(RenditionRetry.backoffMs == [600_000, 3_600_000, 86_400_000])
        #expect(RenditionRetry.delayMs(afterFailures: 0) == 0)
        #expect(RenditionRetry.delayMs(afterFailures: 1) == 600_000)
        #expect(RenditionRetry.delayMs(afterFailures: 2) == 3_600_000)
        #expect(RenditionRetry.delayMs(afterFailures: 3) == 86_400_000)
        #expect(RenditionRetry.delayMs(afterFailures: 9) == 86_400_000)
        #expect(!RenditionRetry.isDue(failures: 1, lastFailureAtMs: 1_000, nowMs: 1_000 + 599_999))
        #expect(RenditionRetry.isDue(failures: 1, lastFailureAtMs: 1_000, nowMs: 1_000 + 600_000))
        #expect(!RenditionRetry.isDue(failures: 2, lastFailureAtMs: 0, nowMs: 600_000))
    }
}

@Suite("Library keys and the local store's layout")
struct CloudLibraryKeyTests {
    private let videoId = CloudAudioFixtures.videoId

    @Test func theVersionsAreTheSpecs() {
        #expect(CloudLibrary.version == 1)
        #expect(CloudLibrary.engineId == "pixl-spatial-1")
        #expect(CloudLibrary.workerVersion == "1.1.0")
        #expect(CloudLibrary.versionPrefix == "lib/v1/")
        #expect(CloudLibrary.timeToLiveDays == 30)
    }

    @Test func keysAreBuiltAsTheSpecWritesThem() {
        #expect(CloudLibrary.audioKey(RenditionKey(videoId: videoId, profile: .studio)) == "lib/v1/J7p4bzqLvCw/sp-studio.flac")
        #expect(CloudLibrary.manifestKey(RenditionKey(videoId: videoId, profile: .studio)) == "lib/v1/J7p4bzqLvCw/sp-studio.json")
        #expect(CloudLibrary.audioKey(RenditionKey(videoId: videoId, profile: .hall)) == "lib/v1/J7p4bzqLvCw/sp-hall.flac")
        #expect(CloudLibrary.folder(videoId: videoId) == "lib/v1/J7p4bzqLvCw/")
    }

    @Test func onlyAnElevenCharacterVideoIdMakesAKey() {
        #expect(CloudLibrary.isValidVideoId("J7p4bzqLvCw"))
        #expect(CloudLibrary.isValidVideoId("a-b_c-D_E12"))
        for bad in ["", "J7p4bzqLvC", "J7p4bzqLvCww", "J7p4bzqLv/w", "../../../etc", "J7p4bzqLvC ", "J7p4bzqLvCé", "J7p4bzq.vCw"] {
            #expect(!CloudLibrary.isValidVideoId(bad), "\(bad)")
            #expect(CloudLibrary.audioKey(RenditionKey(videoId: bad, profile: .studio)) == nil)
            #expect(CloudLibrary.manifestKey(RenditionKey(videoId: bad, profile: .wide)) == nil)
            #expect(CloudAudioLocalLayout.relativePath(RenditionKey(videoId: bad, profile: .studio)) == nil)
        }
    }

    @Test func aKeyIsTakenApartAgain() throws {
        for profile in SpatialProfile.allCases {
            let key = RenditionKey(videoId: videoId, profile: profile)
            let audio = try #require(CloudLibrary.audioKey(key))
            let manifest = try #require(CloudLibrary.manifestKey(key))
            #expect(CloudLibrary.parse(objectKey: audio) == CloudLibrary.ObjectKey(rendition: key, isManifest: false))
            #expect(CloudLibrary.parse(objectKey: manifest) == CloudLibrary.ObjectKey(rendition: key, isManifest: true))
        }
        for bad in ["lib/v2/J7p4bzqLvCw/sp-studio.flac", "lib/v1/J7p4bzqLvCw/sp-studio.wav", "lib/v1/J7p4bzqLvCw/sp-cathedral.flac",
                    "lib/v1/J7p4bzqLvCw/x/sp-studio.flac", "lib/v1/short/sp-studio.flac", "out/J7p4bzqLvCw/sp-studio.flac",
                    "lib/v1/J7p4bzqLvCw/", "lib/v1/J7p4bzqLvCw/sp-studio", "lib/v1/J7p4bzqLvCw/studio.flac", "in/abc.flac"] {
            #expect(CloudLibrary.parse(objectKey: bad) == nil, "\(bad)")
        }
    }

    @Test func theLocalStoreKeepsTheVideoIdAndTheProfileInThePath() {
        let key = RenditionKey(videoId: videoId, profile: .surround)
        #expect(CloudAudioLocalLayout.directoryName == "CloudAudio")
        #expect(CloudAudioLocalLayout.relativePath(key) == "J7p4bzqLvCw/sp-surround.flac")
        #expect(CloudAudioLocalLayout.relativePath(key, manifest: true) == "J7p4bzqLvCw/sp-surround.json")
        #expect(CloudAudioLocalLayout.audioFileName(.night) == "sp-night.flac")
        #expect(CloudAudioLocalLayout.manifestFileName(.night) == "sp-night.json")
    }

    @Test func aFileOfTheStoreSaysWhichRenditionItIs() {
        let store = ["/", "var", "mobile", "Library", "Application Support", "CloudAudio"]
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "sp-night.flac"])
            == RenditionKey(videoId: videoId, profile: .night))
        // A manifest, a stream cache file, a download, an instrumental: not a rendition.
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "sp-night.json"]) == nil)
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "instrumental.flac"]) == nil)
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: ["/", "Caches", "YouTube", "streams", "J7p4bzqLvCw.m4a"]) == nil)
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: ["/", "Downloads", videoId, "sp-night.flac"]) == nil)
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + ["short", "sp-night.flac"]) == nil)
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: ["sp-night.flac"]) == nil)
        let url = URL(fileURLWithPath: "/data/Application Support/CloudAudio/\(videoId)/sp-wide.flac")
        #expect(CloudAudioLocalLayout.rendition(ofAudioFile: url) == RenditionKey(videoId: videoId, profile: .wide))
        #expect(CloudAudioLocalLayout.rendition(ofAudioFile: URL(string: "pixlstream://J7p4bzqLvCw")!) == nil)
    }
}

@Suite("Render manifest")
struct CloudLibraryManifestTests {
    private let videoId = CloudAudioFixtures.videoId
    private var studio: RenditionKey { RenditionKey(videoId: videoId, profile: .studio) }

    @Test func theSpecsExampleDecodesAndIsAccepted() throws {
        let manifest = try CloudAudioFixtures.manifest()
        #expect(manifest.schema == "pixl.library.render")
        #expect(manifest.v == 1 && manifest.libV == 1)
        #expect(manifest.videoId == videoId && manifest.kind == "spatial" && manifest.profile == "studio")
        let audio = try #require(manifest.audio)
        #expect(audio.key == "lib/v1/J7p4bzqLvCw/sp-studio.flac")
        #expect(audio.bytes == 27_100_200)
        #expect(audio.codec == "flac" && audio.bits == 16 && audio.sampleRate == 48_000)
        #expect(audio.samples == 9_696_000 && audio.durationMs == 202_000)
        #expect(manifest.loudness?.integratedLufs == -13.8)
        #expect(manifest.loudness?.sourceLufs == -9.8)
        #expect(manifest.loudness?.truePeakDb == -1.0)
        #expect(manifest.loudness?.limiterMaxDb == 0.6)
        #expect(manifest.headroomDb == 4.0)
        #expect(manifest.source?.itag == 251 && manifest.source?.codec == "opus")
        #expect(manifest.source?.sampleRate == 48_000 && manifest.source?.decodedSamples == 9_696_000)
        #expect(manifest.render?.engine == CloudLibrary.engineId)
        #expect(manifest.render?.stems == "open-cascade-6")
        #expect(manifest.stemMode == .stems6)
        #expect(manifest.worker?.version == "1.1.0" && manifest.worker?.gitSha == "abcdef012345")
        #expect(manifest.createdAt == "2026-11-10T19:02:11Z")
        #expect(manifest.keepsSourceTimeline == true)
        #expect(manifest.check(for: studio) == .success(audio))
        #expect(manifest.isAccepted(for: studio))
    }

    @Test func aManifestForSomethingElseThanWasAskedIsRefused() throws {
        let manifest = try CloudAudioFixtures.manifest()
        #expect(manifest.check(for: RenditionKey(videoId: videoId, profile: .wide)) == .failure(.wrongProfile("studio")))
        #expect(manifest.check(for: RenditionKey(videoId: "AAAAAAAAAAA", profile: .studio)) == .failure(.wrongVideoId(videoId)))
        #expect(!manifest.isAccepted(for: RenditionKey(videoId: videoId, profile: .night)))

        var changed = manifest
        changed.schema = "pixl.cloudstudio.result"
        #expect(changed.check(for: studio) == .failure(.wrongSchema("pixl.cloudstudio.result")))
        changed = manifest
        changed.v = 2
        #expect(changed.check(for: studio) == .failure(.wrongSchemaVersion(2)))
        changed = manifest
        changed.libV = 2
        #expect(changed.check(for: studio) == .failure(.wrongLibraryVersion(2)))
        changed = manifest
        changed.profile = nil
        #expect(changed.check(for: studio) == .failure(.wrongProfile(nil)))
        // `kind` is always `spatial` today; a kind a later schema adds is not this render.
        changed = manifest
        changed.kind = "stems"
        #expect(changed.check(for: studio) == .failure(.wrongKind("stems")))
    }

    @Test func aManifestMustNameUsableAudioAtItsCanonicalKey() throws {
        let manifest = try CloudAudioFixtures.manifest()
        var changed = manifest
        changed.audio = nil
        #expect(changed.check(for: studio) == .failure(.audioMissing))
        changed = manifest
        changed.audio?.key = "lib/v1/J7p4bzqLvCw/../../in/other.flac"
        #expect(changed.check(for: studio) == .failure(.wrongAudioKey("lib/v1/J7p4bzqLvCw/../../in/other.flac")))
        changed = manifest
        changed.audio?.key = "lib/v1/J7p4bzqLvCw/sp-wide.flac"
        #expect(changed.check(for: studio) == .failure(.wrongAudioKey("lib/v1/J7p4bzqLvCw/sp-wide.flac")))
        changed = manifest
        changed.audio?.codec = "aac"
        #expect(changed.check(for: studio) == .failure(.wrongAudioCodec("aac")))
        changed = manifest
        changed.audio?.bytes = 0
        #expect(changed.check(for: studio) == .failure(.badAudioFacts))
        changed = manifest
        changed.audio?.sha256 = "abc"
        #expect(changed.check(for: studio) == .failure(.badAudioFacts))
    }

    @Test func theDownloadMustMatchTheManifestsSizeAndHash() throws {
        let manifest = try CloudAudioFixtures.manifest()
        let sha = try #require(manifest.audio?.sha256)
        #expect(manifest.audioMatches(bytes: 27_100_200, sha256: sha))
        #expect(manifest.audioMatches(bytes: 27_100_200, sha256: sha.uppercased()))
        #expect(!manifest.audioMatches(bytes: 27_100_201, sha256: sha))
        #expect(!manifest.audioMatches(bytes: 27_100_200, sha256: String(repeating: "0", count: 64)))
        var empty = manifest
        empty.audio = nil
        #expect(!empty.audioMatches(bytes: 0, sha256: ""))
    }

    @Test func theStemModesAreTheSpecs() {
        #expect(CloudStemMode.allCases.map(\.rawValue) == ["stems6", "stems4", "mix"])
    }

    @Test func aManifestWrittenBesideTheAudioReadsBackTheSame() throws {
        let manifest = try CloudAudioFixtures.manifest()
        #expect(try CloudLibraryManifest.decode(manifest.encoded()) == manifest)
    }

    @Test func aMissingHeadroomFallsBackToFour() throws {
        var manifest = try CloudAudioFixtures.manifest()
        manifest.loudness = nil
        #expect(manifest.headroomDb == 4.0)
        #expect(manifest.isAccepted(for: studio))
        #expect(manifest.keepsSourceTimeline == true)
        manifest.source = nil
        #expect(manifest.keepsSourceTimeline == nil)
    }

    @Test func somethingThatIsNotAManifestDoesNotDecode() {
        #expect(throws: (any Error).self) { try CloudLibraryManifest.decode(Data("{\"schema\":\"x\"}".utf8)) }
        #expect(throws: (any Error).self) { try CloudLibraryManifest.decode(Data("not json".utf8)) }
    }
}

@Suite("The two services")
struct SpatialServicesTests {
    private let song = Song(id: "sp:1", title: "Song", artist: "Artist", artistId: 1, album: "Album", albumId: 1, path: "",
                            contentUriString: "spotify://1", albumArtUriString: nil, duration: 202_000, mimeType: nil,
                            bitrate: nil, sampleRate: nil)

    @Test func theNoopLibraryHoldsNothingAndAsksForNothing() async {
        let library: any SpatialLibrary = NoopSpatialLibrary()
        let key = RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .studio)
        await library.apply(CloudAudioSettings(builtInCloudKeys: true))
        #expect(await library.localRendition(key) == nil)
        #expect(await library.localRenditions(videoId: key.videoId).isEmpty)
        #expect(await library.status(key) == RenditionStatus.none)
        let request = RenditionRequest(song: song, videoId: key.videoId, profile: key.profile)
        #expect(request.key == key && request.reason == .playing)
        #expect(await library.request(request) == RenditionStatus.none)
        await library.markPlayed(key)
        #expect(await library.usage() == .empty)
        #expect(await library.removeAll() == .empty)
        var events = 0
        for await _ in await library.events() { events += 1 }
        #expect(events == 0)
    }

    @Test func theNoopPlayerPlaysPlainStereo() async {
        let playback: any SpatialPlayback = NoopSpatialPlayback()
        await playback.apply(CloudAudioSettings(builtInCloudKeys: false))
        let snapshot = await playback.snapshot()
        #expect(snapshot == .idle)
        #expect(!snapshot.isActive && snapshot.wantedRender == nil)
        #expect(snapshot.audible == .stereo)
        var events = 0
        for await _ in await playback.events() { events += 1 }
        #expect(events == 0)
    }

    @Test func aSnapshotWantsTheSelectedProfilesRenderOnlyWhileActiveAndNotYetPlayingIt() {
        var snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                               selection: .profile(.wide), output: .bluetooth, routePasses: true,
                                               audible: .onDevice(.wide))
        #expect(snapshot.isActive)
        #expect(snapshot.wantedRender == RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .wide))
        snapshot.audible = .render(.wide)
        #expect(snapshot.wantedRender == nil)
        // The render of another profile still plays (the swap has not happened yet): the new one is wanted.
        snapshot.audible = .render(.studio)
        #expect(snapshot.wantedRender == RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .wide))
        // A song the on-device stage cannot take (its sample rate) plays stereo: its render is wanted all the same.
        snapshot.audible = .stereo
        #expect(snapshot.wantedRender == RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .wide))
        snapshot.audible = .onDevice(.wide)
        snapshot.routePasses = false
        #expect(!snapshot.isActive && snapshot.wantedRender == nil)
        snapshot.routePasses = true
        snapshot.singInstrumentalOn = true
        #expect(!snapshot.isActive && snapshot.wantedRender == nil)
        snapshot.singInstrumentalOn = false
        snapshot.videoId = nil
        #expect(snapshot.isActive && snapshot.wantedRender == nil)
        snapshot.videoId = CloudAudioFixtures.videoId
        snapshot.selection = .off
        #expect(!snapshot.isActive && snapshot.wantedRender == nil)
    }

    @Test func whatHoldsASelectedProfileBackComesInAndroidsOrder() {
        var snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                               selection: .profile(.studio), output: .bluetooth, routePasses: true,
                                               audible: .onDevice(.studio))
        #expect(snapshot.route == .headphones)
        #expect(snapshot.blockedBy == nil)
        snapshot.audible = .render(.studio)
        #expect(snapshot.blockedBy == nil)
        // A rate the stage does not take: stereo while active.
        snapshot.audible = .stereo
        #expect(snapshot.blockedBy == .format)
        // Sing comes before the format.
        snapshot.singInstrumentalOn = true
        #expect(snapshot.blockedBy == .sing)
        // The route comes first.
        snapshot.output = .phoneSpeaker
        snapshot.routePasses = false
        #expect(snapshot.blockedBy == .route)
        // A device that plays the music itself: the route rule's "no" while the mode is headphones…
        snapshot.singInstrumentalOn = false
        snapshot.output = .remote
        #expect(snapshot.blockedBy == .route)
        // …and the device itself while the mode is `always` (Sing still comes first then).
        snapshot.route = .always
        #expect(SpatialActivation.routePasses(mode: snapshot.route, output: snapshot.output) == snapshot.routePasses)
        #expect(snapshot.blockedBy == .remote)
        snapshot.singInstrumentalOn = true
        #expect(snapshot.blockedBy == .sing)
        // Nothing selected, or nothing loaded: nothing is held back.
        snapshot.selection = .off
        #expect(snapshot.blockedBy == nil)
        snapshot.selection = .profile(.studio)
        snapshot.songId = nil
        #expect(snapshot.blockedBy == nil)
        #expect(SpatialBlock.allCases == [.route, .sing, .remote, .format])
    }

    @Test func whatIsAudibleSaysItsProfile() {
        #expect(SpatialAudible.stereo.profile == nil)
        #expect(SpatialAudible.onDevice(.hall).profile == .hall)
        #expect(SpatialAudible.render(.night).profile == .night)
        #expect(SpatialAudible.render(.night).isCloudRender && !SpatialAudible.render(.night).isOnDevice)
        #expect(SpatialAudible.onDevice(.hall).isOnDevice && !SpatialAudible.onDevice(.hall).isCloudRender)
        #expect(!SpatialAudible.stereo.isOnDevice && !SpatialAudible.stereo.isCloudRender)
    }

    @Test func everyStateOfTheSheetHasTheSpecsSentence() {
        #expect(SpatialStatusLine.onPhoneForNow.text == "On your phone for now. The cloud version takes about a minute.")
        #expect(SpatialStatusLine.waitingForWifi.text == "On your phone for now. The cloud version waits for Wi-Fi.")
        #expect(SpatialStatusLine.cloudLimitReached.text == "On your phone only. This month's cloud limit is reached.")
        #expect(SpatialStatusLine.gettingCloudVersion.text == "Getting the cloud version.")
        #expect(SpatialStatusLine.cloudVersion.text == "Playing the cloud version.")
        #expect(SpatialStatusLine.onPhoneOnly.text == "On your phone only. Turn on cloud renders for the full version.")
        #expect(SpatialStatusLine.cloudFailed.text == "The cloud version didn't work this time. Still playing on your phone.")
        #expect(SpatialStatusLine.headphonesOnly.text == "Headphones only. Plug in to hear it.")
        #expect(SpatialStatusLine.pausedForSing.text == "Paused while Sing is on.")
        #expect(SpatialStatusLine.none.text == nil)
        // Android's `SpatialStatusLine`, case for case and in its order.
        #expect(SpatialStatusLine.allCases == [.none, .onPhoneForNow, .waitingForWifi, .cloudLimitReached,
                                               .gettingCloudVersion, .cloudVersion, .onPhoneOnly, .cloudFailed,
                                               .headphonesOnly, .pausedForSing])
        #expect(SpatialCopy.levelNote == "Spatial plays a little quieter so the peaks stay clean.")
    }

    @Test func theStatusLineFollowsWhatPlays() {
        var settings = CloudAudioSettings(builtInCloudKeys: true)
        settings.profile = .profile(.studio)
        var snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                               selection: .profile(.studio), output: .wiredHeadphones, routePasses: true,
                                               audible: .onDevice(.studio))
        func line(cloudRendersOn: Bool = true, _ status: RenditionStatus) -> SpatialStatusLine {
            SpatialStatusLine.of(settings: settings, snapshot: snapshot, status: status, cloudRendersOn: cloudRendersOn)
        }
        // The on-device stage plays: the line follows the cloud (Android's table, row for row).
        let onDevice: [RenditionStatus: SpatialStatusLine] = [
            .none: .onPhoneForNow, .preview: .onPhoneForNow, .queued: .onPhoneForNow,
            .waitingForNetwork: .waitingForWifi, .capReached: .cloudLimitReached, .processing: .onPhoneForNow,
            .downloading: .gettingCloudVersion, .ready: .gettingCloudVersion, .failed: .cloudFailed,
        ]
        #expect(onDevice.count == RenditionStatus.allCases.count)
        for (status, expected) in onDevice {
            #expect(line(status) == expected, "\(status)")
            // Cloud renders off (either switch) comes before anything the library says, a render already on the
            // phone included.
            #expect(line(cloudRendersOn: false, status) == .onPhoneOnly, "\(status)")
        }
        // A song the stage cannot take plays stereo: no line of its own, so none, until its render plays.
        snapshot.audible = .stereo
        #expect(snapshot.blockedBy == .format)
        for status in RenditionStatus.allCases {
            #expect(line(status) == SpatialStatusLine.none, "\(status)")
            #expect(line(cloudRendersOn: false, status) == SpatialStatusLine.none, "\(status)")
        }
        // The render plays, whatever the switches say now.
        snapshot.audible = .render(.studio)
        #expect(line(.ready) == .cloudVersion)
        #expect(line(cloudRendersOn: false, .ready) == .cloudVersion)
        // The route rule fails.
        snapshot.output = .phoneSpeaker
        snapshot.routePasses = false
        snapshot.audible = .stereo
        #expect(line(.ready) == .headphonesOnly)
        // Sing's instrumental plays.
        snapshot.output = .wiredHeadphones
        snapshot.routePasses = true
        snapshot.singInstrumentalOn = true
        #expect(line(.ready) == .pausedForSing)
        // Another device plays the music: the route rule's "no" in headphones mode; no line in `always` mode, where
        // only Sing still has one.
        snapshot.singInstrumentalOn = false
        snapshot.output = .remote
        snapshot.routePasses = false
        #expect(line(.processing) == .headphonesOnly)
        snapshot.route = .always
        #expect(line(.processing) == SpatialStatusLine.none)
        snapshot.singInstrumentalOn = true
        #expect(line(.processing) == .pausedForSing)
        // Off (the setting, whatever the player still has), or nothing loaded.
        snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                           selection: .profile(.studio), output: .wiredHeadphones, routePasses: true,
                                           audible: .onDevice(.studio))
        settings.profile = .off
        #expect(line(.none) == SpatialStatusLine.none)
        settings.profile = .profile(.studio)
        #expect(line(.none) == .onPhoneForNow)
        snapshot.songId = nil
        #expect(line(.none) == SpatialStatusLine.none)
    }

    @Test func theHubHandsEveryEventToEveryStream() async {
        let hub = SpatialEventHub<Int>()
        let first = hub.stream()
        let second = hub.stream(first: 0)
        #expect(hub.subscriberCount == 2)
        hub.send(1)
        hub.send(2)
        hub.finish()
        var one: [Int] = [], two: [Int] = []
        for await value in first { one.append(value) }
        for await value in second { two.append(value) }
        #expect(one == [1, 2])
        #expect(two == [0, 1, 2])
        #expect(hub.subscriberCount == 0)
        // After `finish` a new stream still works.
        let third = hub.stream()
        hub.send(3)
        hub.finish()
        var three: [Int] = []
        for await value in third { three.append(value) }
        #expect(three == [3])
    }

    @Test func aStreamThatIsDroppedLeavesTheHub() async {
        let hub = SpatialEventHub<Int>(bufferSize: 2)
        do {
            let stream = hub.stream()
            #expect(hub.subscriberCount == 1)
            _ = stream
        }
        // The continuation's termination handler runs when the stream is released.
        for _ in 0..<50 where hub.subscriberCount != 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(hub.subscriberCount == 0)
        // A slow reader keeps the newest events only.
        let slow = hub.stream()
        for value in 1...5 { hub.send(value) }
        hub.finish()
        var got: [Int] = []
        for await value in slow { got.append(value) }
        #expect(got == [4, 5])
    }
}
