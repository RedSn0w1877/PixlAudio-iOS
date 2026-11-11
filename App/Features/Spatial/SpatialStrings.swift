import Foundation

// Spatial audio's words (cloud audio spec of 2026-11-10, section 6.5): the full player's button, the sheet and the rows
// in Settings › Playback. English only, written here and not in the String Catalog (integration map 8.5). The keys are
// the Android app's (`res/values/strings_spatial_ui.xml`, branch `audio-ui`), so a catalog generated from Android later
// brings the same words; placeholders are in Swift's form (`%1$@` for Android's `%1$s`, `%1$lld` for `%1$d`), which is
// what `tools/localization/android_strings_to_xcstrings.py` converts them to.
//
// The profile names, their one-liners, the status lines and the quiet line are the spec's words: the same text as
// PixlModel's `SpatialProfile.displayName` / `.summary`, `SpatialStatusLine.text` and `SpatialCopy.levelNote`
// (`AppTests/SpatialAudioUITests.swift` checks them word for word). Change them in the spec first.
// None of the words spec 1 rules out appears here (the test checks that too); outside developer mode no row says codec,
// stems or LUFS.
nonisolated extension L10n {
    // MARK: The feature

    static let spatialAudio = String(localized: "spatial_ui_audio", defaultValue: "Spatial audio")
    static let spatialForHeadphones = String(localized: "spatial_ui_for_headphones", defaultValue: "For headphones.")
    static let spatialOff = String(localized: "spatial_ui_off", defaultValue: "Off")
    static let spatialOffLine = String(localized: "spatial_ui_off_line", defaultValue: "The normal stereo sound.")

    // MARK: The six profiles (spec 1 and 6.5), in the spec's order

    static let spatialProfileStudio = String(localized: "spatial_ui_profile_studio", defaultValue: "Studio")
    static let spatialProfileStudioLine = String(localized: "spatial_ui_profile_studio_line",
                                                 defaultValue: "Clean and close, like good speakers in a quiet room.")
    static let spatialProfileWide = String(localized: "spatial_ui_profile_wide", defaultValue: "Wide")
    static let spatialProfileWideLine = String(localized: "spatial_ui_profile_wide_line",
                                               defaultValue: "Instruments pushed out to the sides.")
    static let spatialProfileIntimate = String(localized: "spatial_ui_profile_intimate", defaultValue: "Intimate")
    static let spatialProfileIntimateLine = String(localized: "spatial_ui_profile_intimate_line",
                                                   defaultValue: "The voice right in front of you.")
    static let spatialProfileHall = String(localized: "spatial_ui_profile_hall", defaultValue: "Concert Hall")
    static let spatialProfileHallLine = String(localized: "spatial_ui_profile_hall_line",
                                               defaultValue: "A big room, a few rows back.")
    static let spatialProfileSurround = String(localized: "spatial_ui_profile_surround", defaultValue: "Surround")
    static let spatialProfileSurroundLine = String(localized: "spatial_ui_profile_surround_line",
                                                   defaultValue: "Sound beside and behind you.")
    static let spatialProfileNight = String(localized: "spatial_ui_profile_night", defaultValue: "Night")
    static let spatialProfileNightLine = String(localized: "spatial_ui_profile_night_line",
                                                defaultValue: "Softer and gentler for late listening.")

    // MARK: The sheet's status line for the current song: one per row of 6.5's table

    static let spatialStatusOnPhoneForNow = String(
        localized: "spatial_ui_status_on_phone_for_now",
        defaultValue: "On your phone for now. The cloud version takes about a minute.")
    static let spatialStatusWaitingForWifi = String(
        localized: "spatial_ui_status_waiting_for_wifi",
        defaultValue: "On your phone for now. The cloud version waits for Wi-Fi.")
    static let spatialStatusCloudLimitReached = String(
        localized: "spatial_ui_status_cloud_limit_reached",
        defaultValue: "On your phone only. This month's cloud limit is reached.")
    static let spatialStatusGettingCloudVersion = String(localized: "spatial_ui_status_getting_cloud_version",
                                                         defaultValue: "Getting the cloud version.")
    static let spatialStatusCloudVersion = String(localized: "spatial_ui_status_cloud_version",
                                                  defaultValue: "Playing the cloud version.")
    static let spatialStatusOnPhoneOnly = String(
        localized: "spatial_ui_status_on_phone_only",
        defaultValue: "On your phone only. Turn on cloud renders for the full version.")
    static let spatialStatusCloudFailed = String(
        localized: "spatial_ui_status_cloud_failed",
        defaultValue: "The cloud version didn't work this time. Still playing on your phone.")
    static let spatialStatusHeadphonesOnly = String(localized: "spatial_ui_status_headphones_only",
                                                    defaultValue: "Headphones only. Plug in to hear it.")
    static let spatialStatusPausedForSing = String(localized: "spatial_ui_status_paused_for_sing",
                                                   defaultValue: "Paused while Sing is on.")
    /// Under the profile list, always (spec 6.3 "Level", 6.5).
    static let spatialQuieterNote = String(localized: "spatial_ui_quieter_note",
                                           defaultValue: "Spatial plays a little quieter so the peaks stay clean.")

    // MARK: The sheet's "This song" switch (Hoa, 2026-11-11; Android's `spatial_ui_this_song*`)

    static let spatialThisSong = String(localized: "spatial_ui_this_song", defaultValue: "This song")
    static let spatialThisSongOn = String(localized: "spatial_ui_this_song_on",
                                          defaultValue: "Spatial audio is on for this song.")
    static let spatialThisSongOff = String(localized: "spatial_ui_this_song_off",
                                           defaultValue: "Off for this song. It plays the original, at full quality.")

    // MARK: The full player's button (VoiceOver: the label is "Spatial audio", the value "Off" or the profile's name)

    /// A selected profile that can't be heard right now (the route rule or Sing; the sheet's line says why).
    static func spatialHeldValue(_ name: String) -> String {
        String(format: String(localized: "spatial_ui_ax_held_value", defaultValue: "%1$@. Not playing right now."), name)
    }

    // MARK: Developer mode: the full player's file-info label while Spatial audio plays

    static func spatialFileInfoOnDevice(_ name: String) -> String {
        String(format: String(localized: "spatial_ui_file_info_on_device", defaultValue: "Spatial %1$@ on phone"), name)
    }
    static func spatialFileInfoRender(_ name: String) -> String {
        String(format: String(localized: "spatial_ui_file_info_render", defaultValue: "Spatial %1$@ cloud render"), name)
    }

    // MARK: Settings › Playback › Sound

    /// "Studio · Clean and close, like good speakers in a quiet room."
    static func spatialSettingsProfileSubtitle(_ name: String, _ line: String) -> String {
        String(format: String(localized: "spatial_ui_settings_profile_subtitle", defaultValue: "%1$@ · %2$@"), name, line)
    }
    static let spatialSettingsCloudTitle = String(localized: "spatial_ui_settings_cloud_title",
                                                  defaultValue: "Cloud renders")
    static let spatialSettingsCloudSubtitle = String(
        localized: "spatial_ui_settings_cloud_subtitle",
        defaultValue: "The cloud makes the full version of each song. When this is off, Spatial audio stays on your phone.")
    static let spatialSettingsMasterOffTitle = String(localized: "spatial_ui_settings_master_off_title",
                                                      defaultValue: "Cloud processing is off")
    static let spatialSettingsMasterOffSubtitle = String(localized: "spatial_ui_settings_master_off_subtitle",
                                                         defaultValue: "Cloud renders need it. Tap to turn it on.")
    static let spatialSettingsPrepareTitle = String(localized: "spatial_ui_settings_prepare_title",
                                                    defaultValue: "Prepare ahead")
    static let spatialSettingsPrepareSubtitle = String(
        localized: "spatial_ui_settings_prepare_subtitle",
        defaultValue: "Gets favourites and most-played songs ready on Wi-Fi, when the battery isn't low.")
    static let spatialSettingsPrepareNeedsCloud = String(localized: "spatial_ui_settings_prepare_needs_cloud",
                                                         defaultValue: "Needs cloud renders.")
    /// "Songs ready: 12 · 1.4 GB on this phone"
    static func spatialSettingsSongsReady(_ songs: Int, _ gigabytes: String) -> String {
        String(format: String(localized: "spatial_ui_settings_songs_ready",
                              defaultValue: "Songs ready: %1$lld · %2$@ GB on this phone"), songs, gigabytes)
    }
    static let spatialSettingsSongsReadySubtitle = String(
        localized: "spatial_ui_settings_songs_ready_subtitle",
        defaultValue: "Cloud versions saved for Spatial audio. The least played go first when the space runs out.")
    static let spatialSettingsRemove = String(localized: "spatial_ui_settings_remove",
                                              defaultValue: "Remove downloaded renders")
    static let spatialSettingsRemoveConfirmTitle = String(localized: "spatial_ui_settings_remove_confirm_title",
                                                          defaultValue: "Remove downloaded renders?")
    static let spatialSettingsRemoveConfirmText = String(
        localized: "spatial_ui_settings_remove_confirm_text",
        defaultValue: "This clears the cloud versions saved on this phone. Songs get them again the next time they play.")

    // MARK: Settings › Playback › Advanced (Developer mode)

    static let spatialDevRouteTitle = String(localized: "spatial_ui_dev_route_title", defaultValue: "Spatial audio route")
    static let spatialDevRouteSubtitle = String(localized: "spatial_ui_dev_route_subtitle",
                                                defaultValue: "Where Spatial audio may play.")
    static let spatialDevRouteHeadphones = String(localized: "spatial_ui_dev_route_headphones",
                                                  defaultValue: "Headphones only")
    static let spatialDevRouteAlways = String(localized: "spatial_ui_dev_route_always", defaultValue: "Always")
    static let spatialDevCapTitle = String(localized: "spatial_ui_dev_cap_title",
                                           defaultValue: "Spatial cloud limit per month")
    /// "Spatial renders only, apart from Sing. Spent this month: $1.24."
    static func spatialDevCapSubtitle(_ spent: String) -> String {
        String(format: String(localized: "spatial_ui_dev_cap_subtitle",
                              defaultValue: "Spatial renders only, apart from Sing. Spent this month: %1$@."), spent)
    }
    /// "$30"
    static func spatialDevCapUSD(_ dollars: Int) -> String {
        String(format: String(localized: "spatial_ui_dev_cap_usd", defaultValue: "$%1$lld"), dollars)
    }
    static let spatialDevCapNone = String(localized: "spatial_ui_dev_cap_none", defaultValue: "No limit")
    static let spatialDevStorageTitle = String(localized: "spatial_ui_dev_storage_title",
                                               defaultValue: "Storage for Spatial renders")
    static let spatialDevStorageCaption = String(localized: "spatial_ui_dev_storage_caption",
                                                 defaultValue: "The least played are removed first when it is full.")
    /// "512 MB"
    static func spatialDevStorageMB(_ megabytes: Int) -> String {
        String(format: String(localized: "spatial_ui_dev_storage_mb", defaultValue: "%1$lld MB"), megabytes)
    }
    /// "3 GB", "1.5 GB"
    static func spatialDevStorageGB(_ gigabytes: String) -> String {
        String(format: String(localized: "spatial_ui_dev_storage_gb", defaultValue: "%1$@ GB"), gigabytes)
    }
    static let spatialDevDailyTitle = String(localized: "spatial_ui_dev_daily_title",
                                             defaultValue: "Spatial songs a day ahead")
    /// "Sent today: 4."
    static func spatialDevDailyCaption(_ sent: Int) -> String {
        String(format: String(localized: "spatial_ui_dev_daily_caption", defaultValue: "Sent today: %1$lld."), sent)
    }
    static let spatialDevDiagTitle = String(localized: "spatial_ui_dev_diag_title", defaultValue: "Spatial audio: this song")
    static let spatialDevDiagNothing = String(localized: "spatial_ui_dev_diag_nothing", defaultValue: "Nothing is playing.")
    static let spatialDevDiagRendition = String(localized: "spatial_ui_dev_diag_rendition", defaultValue: "Rendition")
    static let spatialDevDiagHeld = String(localized: "spatial_ui_dev_diag_held", defaultValue: "Held back by")
    static let spatialDevDiagStatus = String(localized: "spatial_ui_dev_diag_status", defaultValue: "Status")
    static let spatialDevDiagRender = String(localized: "spatial_ui_dev_diag_render",
                                             defaultValue: "Cloud render on this phone")
    static let spatialDevDiagCodec = String(localized: "spatial_ui_dev_diag_codec", defaultValue: "Source codec")
    static let spatialDevDiagStems = String(localized: "spatial_ui_dev_diag_stems", defaultValue: "Stem mode")
    static let spatialDevDiagLoudness = String(localized: "spatial_ui_dev_diag_loudness", defaultValue: "Loudness")
    static let spatialDevDiagRate = String(localized: "spatial_ui_dev_diag_rate", defaultValue: "Sample rate")
}
