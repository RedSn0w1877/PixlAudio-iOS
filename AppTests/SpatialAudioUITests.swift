import Foundation
import PixlModel
import XCTest
@testable import PixlAudio

/// What the Spatial audio screens show for each state of `env.spatial` (cloud audio spec 6.5): the words against the
/// spec's and PixlModel's, the sheet's list, the player's button for every block, the Settings rows for the two cloud
/// switches and the usage, the number formats and the developer controls, the per-song diagnostics, and the demo states
/// the screenshots use. The same checks as the Android app's `SpatialAudioUiTest`.
@MainActor
final class SpatialAudioUITests: XCTestCase {
    // MARK: Words

    /// The profile names and one-liners, every status line and the quiet line are the spec's words, the same text as
    /// the contract's (`SpatialProfile`, `SpatialStatusLine.text`, `SpatialCopy`).
    func testTheWordsAreTheSpecsAndTheContracts() {
        let names: [SpatialProfile: String] = [.studio: "Studio", .wide: "Wide", .intimate: "Intimate",
                                               .hall: "Concert Hall", .surround: "Surround", .night: "Night"]
        let lines: [SpatialProfile: String] = [
            .studio: "Clean and close, like good speakers in a quiet room.",
            .wide: "Instruments pushed out to the sides.",
            .intimate: "The voice right in front of you.",
            .hall: "A big room, a few rows back.",
            .surround: "Sound beside and behind you.",
            .night: "Softer and gentler for late listening.",
        ]
        // "This song" (Hoa, 2026-11-11): Android's `spatial_ui_this_song*`, word for word.
        XCTAssertEqual(L10n.spatialThisSong, "This song")
        XCTAssertEqual(L10n.spatialThisSongOn, "Spatial audio is on for this song.")
        XCTAssertEqual(L10n.spatialThisSongOff, "Off for this song. It plays the original, at full quality.")
        for profile in SpatialProfile.allCases {
            XCTAssertEqual(SpatialAudioUI.name(profile), names[profile], "\(profile)")
            XCTAssertEqual(SpatialAudioUI.name(profile), profile.displayName, "\(profile)")
            XCTAssertEqual(SpatialAudioUI.line(.profile(profile)), lines[profile], "\(profile)")
            XCTAssertEqual(SpatialAudioUI.line(.profile(profile)), profile.summary, "\(profile)")
        }
        XCTAssertEqual(SpatialAudioUI.name(.off), "Off")
        XCTAssertEqual(SpatialAudioUI.line(.off), "The normal stereo sound.")

        let sentences: [SpatialStatusLine: String] = [
            .onPhoneForNow: "On your phone for now. The cloud version takes about a minute.",
            .waitingForWifi: "On your phone for now. The cloud version waits for Wi-Fi.",
            .cloudLimitReached: "On your phone only. This month's cloud limit is reached.",
            .gettingCloudVersion: "Getting the cloud version.",
            .cloudVersion: "Playing the cloud version.",
            .onPhoneOnly: "On your phone only. Turn on cloud renders for the full version.",
            .cloudFailed: "The cloud version didn't work this time. Still playing on your phone.",
            .headphonesOnly: "Headphones only. Plug in to hear it.",
            .pausedForSing: "Paused while Sing is on.",
        ]
        for line in SpatialStatusLine.allCases {
            XCTAssertEqual(SpatialAudioUI.statusText(line), line.text, "\(line)")
            XCTAssertEqual(SpatialAudioUI.statusText(line), sentences[line], "\(line)")
        }
        XCTAssertNil(SpatialAudioUI.statusText(SpatialStatusLine.none))
        XCTAssertEqual(L10n.spatialQuieterNote, "Spatial plays a little quieter so the peaks stay clean.")
        XCTAssertEqual(L10n.spatialQuieterNote, SpatialCopy.levelNote)
        XCTAssertEqual(L10n.spatialAudio, "Spatial audio")
    }

    /// No word the feature must never show (spec 1; integration map 8.5), in any of its strings.
    func testNoForbiddenWordInAnyString() {
        var texts: [String] = [
            L10n.spatialAudio, L10n.spatialForHeadphones, L10n.spatialOff, L10n.spatialOffLine, L10n.spatialQuieterNote,
            L10n.spatialHeldValue("Studio"), L10n.spatialFileInfoOnDevice("Studio"), L10n.spatialFileInfoRender("Studio"),
            L10n.spatialSettingsProfileSubtitle("Studio", "line"), L10n.spatialSettingsCloudTitle,
            L10n.spatialSettingsCloudSubtitle, L10n.spatialSettingsMasterOffTitle, L10n.spatialSettingsMasterOffSubtitle,
            L10n.spatialSettingsPrepareTitle, L10n.spatialSettingsPrepareSubtitle, L10n.spatialSettingsPrepareNeedsCloud,
            L10n.spatialSettingsSongsReady(3, "1.0"), L10n.spatialSettingsSongsReadySubtitle, L10n.spatialSettingsRemove,
            L10n.spatialSettingsRemoveConfirmTitle, L10n.spatialSettingsRemoveConfirmText, L10n.spatialDevRouteTitle,
            L10n.spatialDevRouteSubtitle, L10n.spatialDevRouteHeadphones, L10n.spatialDevRouteAlways,
            L10n.spatialDevCapTitle, L10n.spatialDevCapSubtitle("$0.00"), L10n.spatialDevCapUSD(30),
            L10n.spatialDevCapNone, L10n.spatialDevStorageTitle, L10n.spatialDevStorageCaption,
            L10n.spatialDevStorageMB(512), L10n.spatialDevStorageGB("3"), L10n.spatialDevDailyTitle,
            L10n.spatialDevDailyCaption(4), L10n.spatialDevDiagTitle, L10n.spatialDevDiagNothing,
            L10n.spatialDevDiagRendition, L10n.spatialDevDiagHeld, L10n.spatialDevDiagStatus, L10n.spatialDevDiagRender,
            L10n.spatialDevDiagCodec, L10n.spatialDevDiagStems, L10n.spatialDevDiagLoudness, L10n.spatialDevDiagRate,
            L10n.spatialThisSong, L10n.spatialThisSongOn, L10n.spatialThisSongOff,
        ]
        texts += SpatialSelection.allChoices.flatMap { [SpatialAudioUI.name($0), SpatialAudioUI.line($0)] }
        texts += SpatialStatusLine.allCases.compactMap(SpatialAudioUI.statusText)
        let forbidden = ["lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic",
                         "binilyrics", "enhanced", "apple"]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            let lower = text.lowercased()
            for word in forbidden {
                XCTAssertFalse(lower.contains(word), "\"\(text)\" says \(word)")
            }
        }
    }

    // MARK: The sheet

    /// Off first, then the six profiles in the spec's order, exactly one of them selected: the stored one.
    func testTheListIsOffThenTheSixProfilesWithOneSelected() {
        let expected: [SpatialSelection] = [.off, .profile(.studio), .profile(.wide), .profile(.intimate),
                                            .profile(.hall), .profile(.surround), .profile(.night)]
        XCTAssertEqual(SpatialAudioUI.choiceOrder, expected)
        for selected in expected {
            let choices = SpatialAudioUI.choices(selected: selected)
            XCTAssertEqual(choices.map(\.selection), expected)
            XCTAssertEqual(choices.filter(\.isSelected).map(\.selection), [selected])
            XCTAssertEqual(Set(choices.map(\.id)).count, 7, "row ids are unique")
        }
        XCTAssertEqual(SpatialAudioUI.choices(selected: .profile(.hall))[4].name, "Concert Hall")
        XCTAssertEqual(SpatialAudioUI.choices(selected: .off)[0].id, "off")
        XCTAssertEqual(SpatialAudioUI.choices(selected: .off)[1].id, "studio")
    }

    // MARK: The player's button

    /// "Off", or the profile's name; dimmed only by the blocks the sheet has a line for (the route rule, Sing).
    func testTheButtonForEveryBlock() {
        let blocks: [SpatialBlock?] = [nil] + SpatialBlock.allCases.map(Optional.some)
        for block in blocks {
            let off = SpatialButtonUI.of(selection: .off, blockedBy: block)
            XCTAssertEqual(off, .off, "\(String(describing: block))")
            XCTAssertFalse(off.isEmphasized)
            XCTAssertEqual(off.label, "Off")
            XCTAssertEqual(off.accessibilityValue, "Off")
        }
        for block in blocks {
            let button = SpatialButtonUI.of(selection: .profile(.hall), blockedBy: block)
            let held = block == .route || block == .sing
            XCTAssertEqual(button.isHeldBack, held, "\(String(describing: block))")
            XCTAssertEqual(button.isEmphasized, !held, "\(String(describing: block))")
            XCTAssertEqual(button.label, "Concert Hall")
            XCTAssertEqual(button.accessibilityValue, held ? "Concert Hall. Not playing right now." : "Concert Hall")
        }
    }

    /// Developer mode's file-info label adds what plays while Spatial audio is audible.
    func testTheFileInfoLabel() {
        XCTAssertNil(SpatialAudioUI.fileInfo(.stereo))
        XCTAssertEqual(SpatialAudioUI.fileInfo(.onDevice(.studio)), "Spatial Studio on phone")
        XCTAssertEqual(SpatialAudioUI.fileInfo(.render(.hall)), "Spatial Concert Hall cloud render")
    }

    // MARK: Settings › Playback › Sound

    func testTheRowsForTheTwoSwitches() {
        var settings = CloudAudioSettings(builtInCloudKeys: true)
        settings.profile = .profile(.studio)

        // Both switches on.
        var ui = SpatialSettingsUI.of(settings: settings, usage: .empty, cloudRendersOn: true)
        XCTAssertTrue(ui.cloudChecked)
        XCTAssertFalse(ui.masterOff)
        XCTAssertTrue(ui.prepareAheadChecked)
        XCTAssertTrue(ui.prepareAheadEnabled)
        XCTAssertEqual(ui.prepareAheadSubtitle,
                       "Gets favourites and most-played songs ready on Wi-Fi, when the battery isn't low.")
        XCTAssertEqual(ui.profileSubtitle, "Studio · Clean and close, like good speakers in a quiet room.")

        // "Cloud renders" on, Cloud Studio's master off: the row that leads to the master shows.
        ui = SpatialSettingsUI.of(settings: settings, usage: .empty, cloudRendersOn: false)
        XCTAssertTrue(ui.cloudChecked)
        XCTAssertTrue(ui.masterOff)
        XCTAssertTrue(ui.prepareAheadEnabled)

        // "Cloud renders" off: no master row; Prepare ahead keeps its value but can't be switched.
        settings.cloud = false
        ui = SpatialSettingsUI.of(settings: settings, usage: .empty, cloudRendersOn: false)
        XCTAssertFalse(ui.cloudChecked)
        XCTAssertFalse(ui.masterOff)
        XCTAssertTrue(ui.prepareAheadChecked)
        XCTAssertFalse(ui.prepareAheadEnabled)
        XCTAssertEqual(ui.prepareAheadSubtitle, "Needs cloud renders.")

        settings.profile = .off
        ui = SpatialSettingsUI.of(settings: settings, usage: .empty, cloudRendersOn: false)
        XCTAssertEqual(ui.profileSubtitle, "Off · The normal stereo sound.")
    }

    func testSongsReadyAndRemove() {
        let settings = CloudAudioSettings(builtInCloudKeys: true)
        var ui = SpatialSettingsUI.of(settings: settings, usage: .empty, cloudRendersOn: true)
        XCTAssertEqual(ui.songsReadyTitle, "Songs ready: 0 · 0 GB on this phone")
        XCTAssertFalse(ui.canRemove)

        let usage = CloudAudioUsage(songsReady: 12, bytes: 1_503_238_553)
        ui = SpatialSettingsUI.of(settings: settings, usage: usage, cloudRendersOn: true)
        XCTAssertEqual(ui.songsReadyTitle, "Songs ready: 12 · 1.4 GB on this phone")
        XCTAssertTrue(ui.canRemove)
        ui = SpatialSettingsUI.of(settings: settings, usage: usage, cloudRendersOn: true, isRemoving: true)
        XCTAssertFalse(ui.canRemove, "nothing to press while the renders are being removed")

        // Bytes without a counted song (a file whose manifest is gone) can still be removed.
        ui = SpatialSettingsUI.of(settings: settings, usage: CloudAudioUsage(songsReady: 0, bytes: 10), cloudRendersOn: true)
        XCTAssertTrue(ui.canRemove)
        XCTAssertEqual(ui.songsReadyTitle, "Songs ready: 0 · 0.1 GB on this phone")
    }

    // MARK: Numbers

    func testGigabytes() {
        XCTAssertEqual(SpatialFormat.gigabytes(0), "0")
        XCTAssertEqual(SpatialFormat.gigabytes(-5), "0")
        XCTAssertEqual(SpatialFormat.gigabytes(1), "0.1", "something on the phone never reads 0.0")
        XCTAssertEqual(SpatialFormat.gigabytes(1_073_741_824), "1.0")
        XCTAssertEqual(SpatialFormat.gigabytes(1_503_238_553), "1.4")
        XCTAssertEqual(SpatialFormat.gigabytes(268_435_456), "0.3", "a quarter rounds up, as on Android")
        XCTAssertEqual(SpatialFormat.gigabytes(3 * 1_073_741_824), "3.0")
    }

    func testStorageStopsAndLabels() {
        XCTAssertEqual(SpatialFormat.storage(megabytes: 256), "256 MB")
        XCTAssertEqual(SpatialFormat.storage(megabytes: 512), "512 MB")
        XCTAssertEqual(SpatialFormat.storage(megabytes: 1024), "1 GB")
        XCTAssertEqual(SpatialFormat.storage(megabytes: 1536), "1.5 GB")
        XCTAssertEqual(SpatialFormat.storage(megabytes: 3072), "3 GB")
        XCTAssertEqual(SpatialFormat.storage(megabytes: 65_536), "64 GB")

        let stops = SpatialStorageStops.megabytes
        XCTAssertEqual(stops.count, 14)
        XCTAssertEqual(stops.first, CloudAudioSettings.storageMBRange.lowerBound)
        XCTAssertEqual(stops.last, CloudAudioSettings.storageMBRange.upperBound)
        XCTAssertEqual(stops, stops.sorted())
        XCTAssertTrue(stops.contains(CloudAudioSettings.defaultStorageMB), "the default is a stop")
        XCTAssertEqual(SpatialStorageStops.index(ofStored: 3072), 4)
        XCTAssertEqual(SpatialStorageStops.index(ofStored: 3000), 4, "a value between stops shows the nearest")
        XCTAssertEqual(SpatialStorageStops.index(ofStored: 100), 0)
        XCTAssertEqual(SpatialStorageStops.index(ofStored: 1_000_000), SpatialStorageStops.lastIndex)
        XCTAssertEqual(SpatialStorageStops.megabytes(at: 4.4), 3072)
        XCTAssertEqual(SpatialStorageStops.megabytes(at: -3), 256)
        XCTAssertEqual(SpatialStorageStops.megabytes(at: 99), 65_536)
        XCTAssertEqual(SpatialStorageStops.megabytes(at: .nan), 256)
        for (index, megabytes) in stops.enumerated() {
            XCTAssertEqual(SpatialStorageStops.megabytes(at: Double(index)), megabytes)
            XCTAssertEqual(SpatialStorageStops.index(ofStored: megabytes), index)
        }
    }

    /// The monthly limit: $5 … $200 and No limit, the default among them; a stored amount the list lacks is shown in
    /// its place; every choice picks back what it shows.
    func testCapChoicesAndPicks() {
        let standard = SpatialCapOptions.dollars.map { Optional($0) } + [nil]
        XCTAssertEqual(SpatialCapOptions.choices(stored: 30), standard)
        XCTAssertEqual(SpatialCapOptions.choices(stored: nil), standard)
        XCTAssertTrue(SpatialCapOptions.dollars.contains(CloudAudioSettings.defaultMonthlyCapUSD))
        XCTAssertEqual(SpatialCapOptions.dollars.last, CloudAudioSettings.maxMonthlyCapUSD)
        XCTAssertEqual(SpatialCapOptions.choices(stored: 42),
                       [5, 10, 15, 20, 30, 42, 50, 75, 100, 150, 200, nil])

        XCTAssertEqual(SpatialCapOptions.key(of: nil), "none")
        XCTAssertEqual(SpatialCapOptions.key(of: 30), "30")
        XCTAssertEqual(SpatialCapOptions.key(of: 12.5), "12.5")
        XCTAssertEqual(SpatialCapOptions.label(of: 30), "$30")
        XCTAssertEqual(SpatialCapOptions.label(of: 200), "$200")
        XCTAssertEqual(SpatialCapOptions.label(of: 12.5), "$12.50")
        XCTAssertEqual(SpatialCapOptions.label(of: nil), "No limit")

        XCTAssertEqual(SpatialCapOptions.pick("none"), SpatialCapOptions.Pick(usd: nil))
        XCTAssertEqual(SpatialCapOptions.pick("30"), SpatialCapOptions.Pick(usd: 30))
        XCTAssertNil(SpatialCapOptions.pick("250"))
        XCTAssertNil(SpatialCapOptions.pick("-1"))
        XCTAssertNil(SpatialCapOptions.pick("thirty"))
        for choice in SpatialCapOptions.choices(stored: 12.5) {
            XCTAssertEqual(SpatialCapOptions.pick(SpatialCapOptions.key(of: choice))?.usd, choice)
        }
        let options = SpatialCapOptions.options(stored: 30)
        XCTAssertEqual(options.map(\.label).first, "$5")
        XCTAssertEqual(options.map(\.label).last, "No limit")
        XCTAssertEqual(Set(options.map(\.key)).count, options.count)
    }

    func testDailyAhead() {
        XCTAssertEqual(SpatialDailyAhead.range, 1...100)
        XCTAssertEqual(SpatialDailyAhead.songs(at: 0), 1)
        XCTAssertEqual(SpatialDailyAhead.songs(at: 25.4), 25)
        XCTAssertEqual(SpatialDailyAhead.songs(at: 100.6), 100)
        XCTAssertEqual(SpatialDailyAhead.songs(at: .nan), 1)
    }

    // MARK: Diagnostics (Developer mode)

    func testDiagnosticsRows() {
        XCTAssertEqual(SpatialDiagnostics.rows(snapshot: .idle, status: RenditionStatus.none, rendition: nil), [],
                       "nothing loaded: \"Nothing is playing.\"")

        let playing = SpatialPlaybackSnapshot(songId: "song", videoId: "dQw4w9WgXcQ", selection: .profile(.studio),
                                              output: .bluetooth, routePasses: true, audible: .onDevice(.studio))
        XCTAssertEqual(SpatialDiagnostics.rows(snapshot: playing, status: .preview, rendition: nil).map(\.text),
                       ["Rendition: on device · studio", "Status: preview", "Cloud render on this phone: none"])

        let speaker = SpatialPlaybackSnapshot(songId: "song", videoId: "dQw4w9WgXcQ", selection: .profile(.hall),
                                              output: .phoneSpeaker, routePasses: false, audible: .stereo)
        XCTAssertEqual(SpatialDiagnostics.rows(snapshot: speaker, status: .waitingForNetwork, rendition: nil).map(\.text),
                       ["Rendition: stereo", "Held back by: route", "Status: waiting for network",
                        "Cloud render on this phone: none"])

        let key = RenditionKey(videoId: "dQw4w9WgXcQ", profile: .studio)
        let manifest = CloudLibraryManifest(
            videoId: key.videoId, profile: "studio",
            audio: .init(key: "lib/v1/dQw4w9WgXcQ/sp-studio.flac", bytes: 30_000_000, sha256: "00", sampleRate: 44_100),
            loudness: .init(integratedLufs: -14.04, sourceLufs: -9.75, headroomDb: 4.0),
            source: .init(itag: 140, codec: "aac"), render: .init(engine: "pixl-spatial-1", stemMode: "stems6"))
        let rendition = LocalRendition(key: key, fileURL: URL(fileURLWithPath: "/tmp/sp-studio.flac"), manifest: manifest)
        let rendered = SpatialPlaybackSnapshot(songId: "song", videoId: "dQw4w9WgXcQ", selection: .profile(.studio),
                                               output: .bluetooth, routePasses: true, audible: .render(.studio))
        XCTAssertEqual(SpatialDiagnostics.rows(snapshot: rendered, status: .ready, rendition: rendition).map(\.text),
                       ["Rendition: cloud render · studio", "Status: ready", "Cloud render on this phone: studio",
                        "Source codec: aac", "Stem mode: stems6", "Loudness: -14.0 LUFS, source -9.8, headroom 4.0 dB",
                        "Sample rate: 44100 Hz"])

        // A manifest that leaves things out says so instead of guessing.
        let sparse = LocalRendition(key: key, fileURL: rendition.fileURL,
                                    manifest: CloudLibraryManifest(videoId: key.videoId, profile: "studio", audio: nil))
        XCTAssertEqual(SpatialDiagnostics.rows(snapshot: rendered, status: .ready, rendition: sparse).map(\.text).suffix(4),
                       ["Source codec: ?", "Stem mode: ?", "Loudness: ? LUFS, headroom 4.0 dB", "Sample rate: ? Hz"])

        // The selected profile's render, and only once it is ready.
        let other = LocalRendition(key: RenditionKey(videoId: key.videoId, profile: .night), fileURL: rendition.fileURL,
                                   manifest: manifest)
        XCTAssertEqual(SpatialDiagnostics.currentRendition(among: [other, rendition], selection: .profile(.studio),
                                                           status: .ready), rendition)
        XCTAssertNil(SpatialDiagnostics.currentRendition(among: [other], selection: .profile(.studio), status: .ready))
        XCTAssertNil(SpatialDiagnostics.currentRendition(among: [rendition], selection: .profile(.studio),
                                                         status: .downloading))
        XCTAssertNil(SpatialDiagnostics.currentRendition(among: [rendition], selection: .off, status: .ready))
    }

    func testStatusAndBlockWords() {
        let words = RenditionStatus.allCases.map(SpatialDiagnostics.statusWords)
        XCTAssertEqual(words, ["none", "preview", "queued", "waiting for network", "cap reached", "processing",
                               "downloading", "ready", "failed"])
        XCTAssertEqual(SpatialBlock.allCases.map(SpatialDiagnostics.blockWords),
                       ["route", "sing", "another device", "sample rate"])
    }

    // MARK: The demo states (UI tests)

    /// Every Spatial demo screen shows the line its name says, through the real model (no-op services, both cloud
    /// switches on as the screenshot tests launch them), and together they show every line.
    func testEveryDemoScreenShowsItsLine() {
        let expected: [DemoScreen: SpatialStatusLine] = [
            .spatialAudio: .onPhoneForNow, .spatialAudioOff: SpatialStatusLine.none,
            .spatialAudioWaitingForWifi: .waitingForWifi,
            .spatialAudioCloudLimit: .cloudLimitReached, .spatialAudioGettingCloudVersion: .gettingCloudVersion,
            .spatialAudioCloudVersion: .cloudVersion, .spatialAudioOnPhoneOnly: .onPhoneOnly,
            .spatialAudioCloudFailed: .cloudFailed, .spatialAudioHeadphonesOnly: .headphonesOnly,
            .spatialAudioPausedForSing: .pausedForSing, .nowPlayingSpatial: .onPhoneForNow,
            .nowPlayingSpatialHeld: .headphonesOnly, .settingsPlaybackSpatial: .onPhoneForNow,
        ]
        XCTAssertEqual(Set(expected.values), Set(SpatialStatusLine.allCases))
        for (screen, line) in expected {
            let model = makeModel(cloudStudioOn: true)
            SpatialDemo.apply(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", screen.rawValue]), to: model)
            XCTAssertEqual(model.statusLine, line, "\(screen)")
            XCTAssertEqual(screen.sheet != nil, screen.rawValue.hasPrefix("spatialAudio"), "\(screen)")
        }

        // Without Cloud Studio's own switch the cloud lines become "On your phone only" (the master-off shot).
        let model = makeModel(cloudStudioOn: false)
        SpatialDemo.apply(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "spatialAudio"]), to: model)
        XCTAssertEqual(model.statusLine, .onPhoneOnly)
        XCTAssertTrue(SpatialSettingsUI.of(settings: model.settings, usage: model.usage,
                                           cloudRendersOn: model.cloudRendersOn).masterOff)

        // Other screens are left alone: Off, nothing pinned.
        let plain = makeModel(cloudStudioOn: true)
        SpatialDemo.apply(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "nowPlaying"]), to: plain)
        XCTAssertEqual(plain.selection, .off)
        XCTAssertEqual(plain.snapshot, .idle)
    }

    /// The held-back player shot dims the button; the Settings shot carries the demo numbers.
    func testDemoButtonAndSettingsNumbers() {
        let held = makeModel(cloudStudioOn: true)
        SpatialDemo.apply(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "nowPlaying.spatialHeld"]), to: held)
        let button = SpatialButtonUI.of(selection: held.selection, blockedBy: held.snapshot.blockedBy)
        XCTAssertTrue(button.isHeldBack)
        XCTAssertEqual(button.label, "Concert Hall")

        let settings = makeModel(cloudStudioOn: true)
        SpatialDemo.apply(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "settingsCategory.playback.spatial"]),
                          to: settings)
        let ui = SpatialSettingsUI.of(settings: settings.settings, usage: settings.usage,
                                      cloudRendersOn: settings.cloudRendersOn)
        XCTAssertEqual(ui.songsReadyTitle, "Songs ready: 12 · 1.4 GB on this phone")
        XCTAssertFalse(ui.masterOff)
        XCTAssertEqual(L10n.spatialDevCapSubtitle("$1.24"), "Spatial renders only, apart from Sing. Spent this month: $1.24.")
        XCTAssertEqual(L10n.spatialDevDailyCaption(settings.usage.sentToday), "Sent today: 4.")
    }

    // MARK: Helpers

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    /// The model the app builds, on the no-op services (the state until ENGINE and CLOUD land), without built-in keys
    /// (as in UI tests) and with Cloud Studio's own switch as given.
    private func makeModel(cloudStudioOn: Bool) -> SpatialAudioModel {
        let name = "spatial.ui.tests.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return SpatialAudioModel(defaults: defaults, library: NoopSpatialLibrary(), playback: NoopSpatialPlayback(),
                                 currentSong: { nil }, builtInCloudKeys: { false },
                                 cloudStudioEnabled: { cloudStudioOn })
    }
}

private extension SpatialDiagnosticRow {
    var text: String { label + ": " + value }
}
