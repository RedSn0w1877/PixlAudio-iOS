import Foundation
import Testing
@testable import PixlModel

/// The contract of Spatial audio and Enhanced audio (docs/handoff/2026-11-10-plans/cloud-audio-spec.md): ids,
/// settings, statuses, library keys, the render manifest and the two service seams. Every expected value here is
/// copied from the spec, so a change on either side shows up as a failing test.
enum CloudAudioFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/cloud-audio"))
        return try Data(contentsOf: url)
    }

    static func manifest(_ name: String) throws -> CloudLibraryManifest {
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
        let forbidden = ["lossless", "hi-res", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics"]
        var shown = SpatialProfile.allCases.flatMap { [$0.displayName, $0.summary] }
        shown += [SpatialStatusLine.onDeviceForNow, .cloudVersion, .headphonesOnly].compactMap(\.text)
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
        // No headroom (Enhanced), or a broken value: the gain is unchanged.
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
                                              "enhanced.enabled", "cloudAudio.storageMB", "cloudAudio.monthlyCapUSD",
                                              "cloudAudio.dailyAhead"])
        #expect(Set(CloudAudioSettingsKey.all).count == 8)
    }

    @Test func theDefaultsAreTheSpecs() {
        let settings = CloudAudioSettings(stored: CloudAudioStoredSettings(), builtInCloudKeys: true)
        #expect(settings.profile == .off)
        #expect(settings.route == .headphones)
        #expect(settings.cloud)
        #expect(settings.prepareAhead)
        #expect(settings.enhancedEnabled)
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
                                              enhancedEnabled: false, storageMB: 1, monthlyCapUSD: 500, dailyAhead: 0)
        let settings = CloudAudioSettings(stored: stored, builtInCloudKeys: true)
        #expect(settings.profile == .profile(.hall))
        #expect(settings.route == .always)
        #expect(!settings.cloud)
        #expect(!settings.prepareAhead)
        #expect(!settings.enhancedEnabled)
        #expect(settings.storageMB == 256)
        #expect(settings.monthlyCapUSD == 200)
        #expect(settings.dailyAhead == 1)
        #expect(CloudAudioSettings.clampedStorageMB(10_000_000) == 65_536)
        #expect(CloudAudioSettings.clampedDailyAhead(1_000) == 100)
    }

    @Test func noLimitIsANegativeStoredCap() {
        #expect(CloudAudioSettings.monthlyCap(fromStored: -1) == nil)
        #expect(CloudAudioSettings.monthlyCap(fromStored: .nan) == nil)
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
    @Test func slotsAreTheFileStemsAndTheManifestSlots() {
        #expect(RenditionKind.spatial(.studio).slot == "sp-studio")
        #expect(RenditionKind.spatial(.hall).slot == "sp-hall")
        #expect(RenditionKind.enhanced.slot == "enhanced")
        #expect(RenditionKind.allKinds.count == 7)
        for kind in RenditionKind.allKinds { #expect(RenditionKind(slot: kind.slot) == kind) }
        #expect(RenditionKind(slot: "sp-cathedral") == nil)
        #expect(RenditionKind(slot: "instrumental") == nil)
        #expect(RenditionKind(slot: "sp-") == nil)
        #expect(RenditionKind.spatial(.night).manifestKind == "spatial")
        #expect(RenditionKind.enhanced.manifestKind == "enhanced")
        #expect(RenditionKind.enhanced.profile == nil)
        #expect(RenditionKey(videoId: "J7p4bzqLvCw", profile: .wide).description == "J7p4bzqLvCw/sp-wide")
    }

    @Test func theStatusesAreTheSpecsSix() {
        #expect(RenditionStatus.allCases.map(\.rawValue) == ["none", "preview", "queued", "processing", "ready", "failed"])
        #expect(RenditionStatus.queued.isInFlight && RenditionStatus.processing.isInFlight)
        #expect(!RenditionStatus.ready.isInFlight && !RenditionStatus.failed.isInFlight && !RenditionStatus.preview.isInFlight)
    }

    @Test func theShownStatusIsTheLibrarysOnceTheCloudIsInvolvedElsePreviewWhileTheStagePlays() {
        #expect(RenditionStatus.shown(library: .none, onDeviceAudible: true) == .preview)
        #expect(RenditionStatus.shown(library: .none, onDeviceAudible: false) == .none)
        #expect(RenditionStatus.shown(library: .queued, onDeviceAudible: true) == .queued)
        #expect(RenditionStatus.shown(library: .processing, onDeviceAudible: true) == .processing)
        #expect(RenditionStatus.shown(library: .ready, onDeviceAudible: false) == .ready)
        #expect(RenditionStatus.shown(library: .failed, onDeviceAudible: true) == .failed)
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
        #expect(CloudLibrary.audioKey(RenditionKey(videoId: videoId, kind: .enhanced)) == "lib/v1/J7p4bzqLvCw/enhanced.flac")
        #expect(CloudLibrary.manifestKey(RenditionKey(videoId: videoId, kind: .enhanced)) == "lib/v1/J7p4bzqLvCw/enhanced.json")
        #expect(CloudLibrary.folder(videoId: videoId) == "lib/v1/J7p4bzqLvCw/")
    }

    @Test func onlyAnElevenCharacterVideoIdMakesAKey() {
        #expect(CloudLibrary.isValidVideoId("J7p4bzqLvCw"))
        #expect(CloudLibrary.isValidVideoId("a-b_c-D_E12"))
        for bad in ["", "J7p4bzqLvC", "J7p4bzqLvCww", "J7p4bzqLv/w", "../../../etc", "J7p4bzqLvC ", "J7p4bzqLvCé", "J7p4bzq.vCw"] {
            #expect(!CloudLibrary.isValidVideoId(bad), "\(bad)")
            #expect(CloudLibrary.audioKey(RenditionKey(videoId: bad, kind: .enhanced)) == nil)
            #expect(CloudLibrary.manifestKey(RenditionKey(videoId: bad, profile: .wide)) == nil)
            #expect(CloudAudioLocalLayout.relativePath(RenditionKey(videoId: bad, kind: .enhanced)) == nil)
        }
    }

    @Test func aKeyIsTakenApartAgain() throws {
        for kind in RenditionKind.allKinds {
            let key = RenditionKey(videoId: videoId, kind: kind)
            let audio = try #require(CloudLibrary.audioKey(key))
            let manifest = try #require(CloudLibrary.manifestKey(key))
            #expect(CloudLibrary.parse(objectKey: audio) == CloudLibrary.ObjectKey(rendition: key, isManifest: false))
            #expect(CloudLibrary.parse(objectKey: manifest) == CloudLibrary.ObjectKey(rendition: key, isManifest: true))
        }
        for bad in ["lib/v2/J7p4bzqLvCw/sp-studio.flac", "lib/v1/J7p4bzqLvCw/sp-studio.wav", "lib/v1/J7p4bzqLvCw/sp-cathedral.flac",
                    "lib/v1/J7p4bzqLvCw/x/sp-studio.flac", "lib/v1/short/sp-studio.flac", "out/J7p4bzqLvCw/sp-studio.flac",
                    "lib/v1/J7p4bzqLvCw/", "lib/v1/J7p4bzqLvCw/sp-studio", "in/abc.flac"] {
            #expect(CloudLibrary.parse(objectKey: bad) == nil, "\(bad)")
        }
    }

    @Test func theLocalStoreKeepsTheVideoIdAndTheSlotInThePath() {
        let key = RenditionKey(videoId: videoId, profile: .surround)
        #expect(CloudAudioLocalLayout.directoryName == "CloudAudio")
        #expect(CloudAudioLocalLayout.relativePath(key) == "J7p4bzqLvCw/sp-surround.flac")
        #expect(CloudAudioLocalLayout.relativePath(key, manifest: true) == "J7p4bzqLvCw/sp-surround.json")
        #expect(CloudAudioLocalLayout.audioFileName(.enhanced) == "enhanced.flac")
        #expect(CloudAudioLocalLayout.manifestFileName(.enhanced) == "enhanced.json")
    }

    @Test func aFileOfTheStoreSaysWhichRenditionItIs() {
        let store = ["/", "var", "mobile", "Library", "Application Support", "CloudAudio"]
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "sp-night.flac"])
            == RenditionKey(videoId: videoId, profile: .night))
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "enhanced.flac"])
            == RenditionKey(videoId: videoId, kind: .enhanced))
        // A manifest, a stream cache file, a download, an instrumental: not a rendition.
        #expect(CloudAudioLocalLayout.rendition(ofAudioFileAt: store + [videoId, "sp-night.json"]) == nil)
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
    private var enhanced: RenditionKey { RenditionKey(videoId: videoId, kind: .enhanced) }

    @Test func theSpecsSpatialExampleDecodesAndIsAccepted() throws {
        let manifest = try CloudAudioFixtures.manifest("manifest.spatial")
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
        #expect(manifest.source?.cutoffHz == 20_000)
        #expect(manifest.render?.engine == CloudLibrary.engineId)
        #expect(manifest.render?.stems == "open-cascade-6")
        #expect(manifest.stemMode == .stems6)
        #expect(manifest.restoreReason == .fullBand)
        #expect(!manifest.restoreApplied)
        #expect(manifest.worker?.version == "1.1.0" && manifest.worker?.gitSha == "abcdef012345")
        #expect(manifest.createdAt == "2026-11-10T19:02:11Z")
        #expect(manifest.keepsSourceTimeline == true)
        #expect(manifest.check(for: studio) == .success(.audio(audio)))
        #expect(manifest.isAccepted(for: studio))
    }

    @Test func aManifestForSomethingElseThanWasAskedIsRefused() throws {
        let manifest = try CloudAudioFixtures.manifest("manifest.spatial")
        #expect(manifest.check(for: RenditionKey(videoId: videoId, profile: .wide)) == .failure(.wrongProfile("studio")))
        #expect(manifest.check(for: enhanced) == .failure(.wrongKind("spatial")))
        #expect(manifest.check(for: RenditionKey(videoId: "AAAAAAAAAAA", profile: .studio)) == .failure(.wrongVideoId(videoId)))
        #expect(!manifest.isAccepted(for: enhanced))

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
    }

    @Test func aSpatialManifestMustNameUsableAudioAtItsCanonicalKey() throws {
        let manifest = try CloudAudioFixtures.manifest("manifest.spatial")
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
        let manifest = try CloudAudioFixtures.manifest("manifest.spatial")
        let sha = try #require(manifest.audio?.sha256)
        #expect(manifest.audioMatches(bytes: 27_100_200, sha256: sha))
        #expect(manifest.audioMatches(bytes: 27_100_200, sha256: sha.uppercased()))
        #expect(!manifest.audioMatches(bytes: 27_100_201, sha256: sha))
        #expect(!manifest.audioMatches(bytes: 27_100_200, sha256: String(repeating: "0", count: 64)))
    }

    @Test func anEnhancedManifestWithAudioIsAcceptedWithNoHeadroom() throws {
        let manifest = try CloudAudioFixtures.manifest("manifest.enhanced")
        let audio = try #require(manifest.audio)
        #expect(manifest.profile == nil)
        #expect(manifest.check(for: enhanced) == .success(.audio(audio)))
        #expect(manifest.headroomDb == 0)
        #expect(manifest.restoreApplied)
        #expect(manifest.stemMode == nil)
        #expect(manifest.source?.cutoffHz == 15_900)
        #expect(manifest.check(for: studio) == .failure(.wrongKind("enhanced")))
    }

    @Test func anEnhancedManifestWithoutAudioMeansThereIsNothingToFetch() throws {
        let manifest = try CloudAudioFixtures.manifest("manifest.enhanced.not-needed")
        #expect(manifest.audio == nil && manifest.loudness == nil)
        #expect(manifest.check(for: enhanced) == .success(.noAudio(reason: "full_band")))
        #expect(manifest.restoreReason == .fullBand)
        #expect(manifest.headroomDb == 0)
        #expect(!manifest.audioMatches(bytes: 0, sha256: ""))
        #expect(manifest.keepsSourceTimeline == nil)
    }

    @Test func theRestoreReasonsAndStemModesAreTheSpecs() {
        #expect(CloudRestoreReason.allCases.map(\.rawValue) == ["full_band", "off", "unavailable", "failed"])
        #expect(CloudStemMode.allCases.map(\.rawValue) == ["stems6", "stems4", "mix"])
    }

    @Test func aManifestWrittenBesideTheAudioReadsBackTheSame() throws {
        for name in ["manifest.spatial", "manifest.enhanced", "manifest.enhanced.not-needed"] {
            let manifest = try CloudAudioFixtures.manifest(name)
            #expect(try CloudLibraryManifest.decode(manifest.encoded()) == manifest)
        }
    }

    @Test func aMissingHeadroomFallsBackToFourForSpatialAndNoneForEnhanced() throws {
        var manifest = try CloudAudioFixtures.manifest("manifest.spatial")
        manifest.loudness = nil
        #expect(manifest.headroomDb == 4.0)
        #expect(manifest.isAccepted(for: studio))
        var other = try CloudAudioFixtures.manifest("manifest.enhanced")
        other.loudness = nil
        #expect(other.headroomDb == 0)
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
        #expect(await library.status(key) == .none)
        let request = RenditionRequest(song: song, videoId: key.videoId, kind: key.kind)
        #expect(request.key == key && request.reason == .playing)
        #expect(await library.request(request) == .none)
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
        #expect(snapshot.audible == .stereo(enhanced: false))
        var events = 0
        for await _ in await playback.events() { events += 1 }
        #expect(events == 0)
    }

    @Test func aSnapshotWantsTheSelectedProfilesRenderOnlyWhileActiveAndNotYetPlayingIt() {
        var snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                               selection: .profile(.wide), output: .bluetooth, routePasses: true,
                                               audible: .onDevice(.wide, enhanced: false))
        #expect(snapshot.isActive)
        #expect(snapshot.wantedRender == RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .wide))
        snapshot.audible = .render(.wide)
        #expect(snapshot.wantedRender == nil)
        // The render of another profile still plays (the swap has not happened yet): the new one is wanted.
        snapshot.audible = .render(.studio)
        #expect(snapshot.wantedRender == RenditionKey(videoId: CloudAudioFixtures.videoId, profile: .wide))
        snapshot.audible = .onDevice(.wide, enhanced: true)
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

    @Test func whatIsAudibleSaysItsProfile() {
        #expect(SpatialAudible.stereo(enhanced: true).profile == nil)
        #expect(SpatialAudible.onDevice(.hall, enhanced: false).profile == .hall)
        #expect(SpatialAudible.render(.night).profile == .night)
        #expect(SpatialAudible.render(.night).isCloudRender && !SpatialAudible.render(.night).isOnDevice)
        #expect(SpatialAudible.onDevice(.hall, enhanced: true).isOnDevice)
    }

    @Test func theStatusLineIsTheSpecsThreeSentences() {
        #expect(SpatialStatusLine.onDeviceForNow.text == "On your phone for now. The cloud version takes about a minute.")
        #expect(SpatialStatusLine.cloudVersion.text == "Playing the cloud version.")
        #expect(SpatialStatusLine.headphonesOnly.text == "Headphones only. Plug in to hear it.")
        #expect(SpatialStatusLine.none.text == nil && SpatialStatusLine.onDeviceOnly.text == nil
            && SpatialStatusLine.pausedForSing.text == nil)
    }

    @Test func theStatusLineFollowsWhatPlays() {
        var snapshot = SpatialPlaybackSnapshot(songId: "sp:1", videoId: CloudAudioFixtures.videoId,
                                               selection: .profile(.studio), output: .wiredHeadphones, routePasses: true,
                                               audible: .onDevice(.studio, enhanced: false))
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .preview) == .onDeviceForNow)
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .processing) == .onDeviceForNow)
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .failed) == .onDeviceOnly)
        #expect(SpatialStatusLine.line(for: snapshot, cloud: false, status: .none) == .onDeviceOnly)
        snapshot.audible = .render(.studio)
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .ready) == .cloudVersion)
        snapshot.output = .phoneSpeaker
        snapshot.routePasses = false
        snapshot.audible = .stereo(enhanced: false)
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .ready) == .headphonesOnly)
        snapshot.routePasses = true
        snapshot.singInstrumentalOn = true
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .ready) == .pausedForSing)
        snapshot.singInstrumentalOn = false
        snapshot.selection = .off
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .none) == .none)
        snapshot.selection = .profile(.studio)
        snapshot.songId = nil
        #expect(SpatialStatusLine.line(for: snapshot, cloud: true, status: .none) == .none)
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
