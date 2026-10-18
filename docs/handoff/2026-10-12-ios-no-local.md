# Spotify-only: no local songs (2026-10-12, branch `ios-no-local`, PR #11)

Owner brief: "make the iOS app Spotify-only — remove local/on-device songs completely". Scanning the phone for audio
files, the folder views, importing audio from the device and the media-library permission are gone; downloaded Spotify
songs and everything that works on a Spotify song stay. An earlier agent had done most of the deletion but was
interrupted before committing; this run finished it, checked it statically (no Mac here) and shipped it.

## What is gone

| Area | Removed |
|---|---|
| Scanner | `LocalLibraryImporter`, `LibraryBuilder`, `MediaLibraryImporter`, `ScanState`, `ScanFingerprint`, `LibraryAutoRefresh`, `LibraryScanOptions`, `FolderAccess` (bookmarks), `TagWriteBack`, `AudioMetadataReader` (trimmed to `TagRegionReader`) |
| Library UI | the Folders page, breadcrumbs, the folder back-edge gesture, folder playlists (`folder_playlist:`), `FolderExplorerView` + `AppRoute.folderExplorer`, the M3U `.fileImporter`, the storage-filter cycle |
| Model | the folder tree in `LibraryModel` (`folders`, `folderPlaylists`, `folderContents`, `folderRoots`, `Inputs.folderSort`) and in `LibraryDetailIndex` (`folderTree`) |
| Settings | `MusicFoldersView`, `LibraryImportDebugView`, the music-folder / rescan / excluded-directory rows, the unused `settingsFolderSources` queries |
| Onboarding | the media-permission and music-folders pages; the order is Welcome → Spotify → Backup → Theme → Layout → Finish |
| Info.plist (`project.yml`) | `NSAppleMusicUsageDescription`, `UIFileSharingEnabled`, the `Audio` document type, the `library-sync` BGTask id |

## What stays, and why

- **`TagRegionReader`** (what is left of `AudioMetadataReader`): `SpotifyConnectPlatform` reads a downloaded file's
  ISRC with it and `LyricsService` reads embedded lyrics. Do not delete it with "local file" in mind.
- **`LibraryIdentity`** (`LibraryFiles.swift`): the `f:` / `mp:` id prefixes still tell a song held in a file from a
  streamed one (`DualDeckEngine+Crossfade`, `PersistenceActor+YouTube`, `HiddenSongs`), and `parentDirectory` fills the
  song table's column.
- **`TagOverrideFields`**: song editing writes an override; nothing rewrites a file any more.
- **The `LibraryImporting` seam** (`App/Core/LibraryImporting.swift`, `LibraryImportMode|Progress|Summary`,
  `DemoLibraryImporter`) and `LibraryStore.refresh`: the importer is always `nil`, but `ActiveJobs` and
  `JobFailureHandlingTests` hang off the seam. Removing it is a separate, larger change.
- **`LibraryTab.folders`, `StorageFilter`, `prefs.folderSort`, `settings.library.hideLocalMedia`,
  `folderBackGestureNavigation`**: persisted preference keys and exhaustive switches. `LibraryPreferences.visibleTabs`
  filters `.folders` out of the tab order, so the page is never shown (`page(_:)` returns `EmptyView`).
- `FolderSourceRecord` stays in `SchemaV1` (SwiftData v1, no migration written for this fork).
- PixlCore's `FolderTree` / `LibrarySorting.sortFolders` stay: they are Android-parity ports with golden vectors and
  the package must keep building on Windows.

## Empty state

`App/Features/Spotify/ConnectSpotifyEmptyState.swift` — shown by `LibraryView` when `library.songs.isEmpty`,
`!library.isLoading` and `accounts.needsSpotifyConnection` (a small `AccountsStore` extension in the same file).
Identifiers `connectSpotify.empty` / `connectSpotify.button`; the button pushes `.spotifyDashboard`.

## Tests

- `AppTests/LibraryImportTests.swift` → `AppTests/LibraryFileTests.swift`: only the four cases that outlive the
  scanner (forged 64-bit MP4 box, `ExternalFiles.kind` — audio is `.unsupported` now, the id helpers, the override
  JSON round trip).
- `LibraryScreensTests` / `LibraryRevisionTests`: folder assertions and `testFolderPlaylistIds` dropped.
- `UITests/LibraryImportScreenshotTests.swift` deleted; `LibraryScreenshotTests` lost the folder screens;
  `BackupOnboardingScreenshotTests` lost the `screen.musicFolders` cover probe; `GlassAccessibilityTests` now looks for
  the "Tap timing" row instead of the removed "Excluded Directories" one.

## Checking it without a Mac

- There is **no pbxproj**: XcodeGen generates the project on CI from `project.yml`, whose targets use directory
  sources (`- path: App`), so deleted files need no project-file surgery.
- `powershell -File ci/parse-check.ps1` (swiftc -parse over every file changed vs `origin/main`, untracked included) —
  it caught one real break the earlier agent left: a missing closing brace in `PersistenceActor+Library.swift`.
- `bash ci/check-forbidden.sh`.
- A repo-wide `rg -w` over every top-level declaration of each deleted file (taken from `git show HEAD:<file>`): zero
  hits outside comments.
- ~140 `L10n` entries are unused, most of them from before this change (the catalog mirrors Android's `strings.xml`),
  so unused strings were left alone apart from the setup ones the earlier agent removed.

## Left out on purpose

- The `LibraryImporting` seam and `LibraryStore`'s scan plumbing (see above).
- `StorageFilter` / "Cloud only" still exist in preferences; every song is remote now, so `LibraryView` passes `.all`.
- Historical handoff notes under `docs/handoff/` still describe the scanner; only the living docs (`design.md`,
  `parity.md`, `test-parity.md`, `performance.md`, `api-notes.md`, `research/architecture.md`) were updated.
- Nothing was run on a device or simulator: CI is the only build.
