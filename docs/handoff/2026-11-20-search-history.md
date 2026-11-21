# Search history (iOS)

Branch `brain-search-history`, cut from `origin/music-brain` (5c1cade). The Android twin is built in parallel in its own folder; the
contract between the two apps is the requirement list (schema, constants, behaviour) and `docs/test-parity.md`, not each other's code.

**Nothing below has been run on a phone.** Only `Packages/PixlCore` compiles and tests on the Windows machine; `App/` is compiled and
tested by GitHub CI alone.

## What the listener gets (once checked on a phone)

- Search keeps a history of up to **50** rows, one per folded query (`Beyonce`, `BEYONCÉ` and `beyonce` are one row; Vietnamese
  diacritics fold too). A row has the text as typed (trimmed, 100 characters at most, 2 at least), how many times it was used, when,
  and, when it came from opening a result, what was opened (song, album, artist, playlist) with its name and picture.
- **Field not focused, blank:** the genre grid as before, with a **Recent** strip above it when there is history (up to 10 tiles:
  artist circle, album / playlist / song square, a chip for a typed search; long-press a tile to remove it).
- **Field focused, blank:** the grid swaps (the same `.easeOut(0.3)` as before) for the **Recent searches** list: a clock row per typed
  search, artwork and a kind subtitle for opened results, an arrow that puts the text in the field, an X that removes the row, and
  **Clear all** in the header. Removing or clearing shows an Undo bar for five seconds (no confirmation).
- **Typing:** up to 5 history rows whose key starts with the folded text come first, above the live results; tapping one fills the field,
  runs the search and drops the keyboard; its arrow only fills the field.
- **Private session** (`BrainActions.isPrivate`): nothing is recorded (no row, no count bump), the strip, the list and the matching rows are
  hidden, and one line under the title says searches aren't saved. Stored rows are untouched.

## Where it lives

| What | File |
|---|---|
| The decisions: key, upsert, 50 cap, prefix suggestions, private rule, merge, constants | `Packages/PixlCore/Sources/PixlLibrary/SearchHistoryRules.swift` |
| `SearchHistoryItem` (new fields, defaults) and `SearchHistoryKind` | `Packages/PixlCore/Sources/PixlModel/LibraryValues.swift` |
| Backup entity and module (new optional fields, old payloads unchanged) | `PixlBackup/Model/AndroidRecords.swift`, `PixlBackup/Modules/DataModules.swift` |
| SwiftData v2 model, migration stage | `App/Persistence/SchemaV2.swift`, `SchemaV1.swift` (`PixlMigrationPlan`), `PersistenceActor.makeContainer` |
| Store functions (read once, record, remove, clear, restore) | `App/Features/Search/PersistenceActor+SearchHistory.swift` |
| State (history, suggestions, strip, Undo) | `App/Features/Search/SearchModel.swift` |
| Views | `App/Features/Search/SearchHistoryViews.swift`, `SearchView.swift`, `GenreBrowseView.swift` (a `header` slot) |
| Field focus out of the bar | `App/Shell/Router.swift` (`isSearchFieldFocused`, `searchBlurRequests`), `RootView.swift` |
| Tests | `Packages/PixlCore/Tests/PixlLibraryTests/SearchHistoryRulesTests.swift`, `PixlBackupTests/SearchHistoryModuleTests.swift`, `AppTests/SearchHistoryTests.swift` |

## Decisions and deviations

1. **The query is the typed text; the opened result is an annotation.** A result tap records the typed query with `kind`, `targetId`,
   `targetTitle`, `imageUrl`. Two results opened from the same typed text therefore share one row (the later one wins). A plain submit of a
   text that already has an opened result keeps it.
2. **No `@Attribute(.unique)` on `key`.** A lightweight migration cannot give old rows distinct keys, so uniqueness is kept by the write path
   (`SearchHistoryRules.record` and the diff in `PersistenceActor.write`). `key` and `timestamp` are indexed.
3. **Keys are filled on the first history read, which now happens when the Search tab is selected, not at launch and not when the hidden tab is prebuilt.** The v1 to v2 stage is lightweight (every new property has a default). The
   first `searchHistory()` after the update folds the old rows, merges the ones that fold alike (counts added) and trims to 50. Rows that
   fold to nothing (only punctuation) are dropped; one-letter old rows survive.
4. **`kind` is nil for a submitted search** (the IME key, the voice result); `query` is a legal kind in the type and in payloads but the app
   writes nil. Unknown kinds in a payload become nil.
5. **Backup field names** are the Gson names of the twin's entity as the contract implies: `key`, `kind`, `targetId`, `targetTitle`, `imageUrl`,
   `count` next to `id`, `query`, `timestamp`. **If Android names a field differently, change `AndroidBackup.SearchHistoryEntity` only.** Old
   payloads decode with defaults and re-encode without the new members (the Android golden files still match byte for byte). A restored `key` is
   never trusted. Restore merges with what is stored (counts: the larger), never clears, caps at 50. Rows without a query still fail the module.
6. **"Fill without searching"** puts the text in the field only. The page searches live on every text change (as it always did), so the results
   appear as if typed; nothing is recorded and the keyboard stays.
7. **Row tap in the focused list:** an artist, album or playlist that is still in the library opens its page; anything else (a song, a text,
   something deleted) runs its text as the search. Song rows do not start playback by themselves.
8. **Catalogue and YouTube Music rows** record their imported song when Play succeeds (kind `song`).
9. **The X is a `GlassCircleButton`** (32 pt) on the list's one glass shape, as the requirement says (a review asked for a plain fill; kept, the
   requirement names the glass button); this is glass on glass inside one
   element, the exception AGENTS.md otherwise forbids. Only visible rows exist (lazy stack). Drop it for a fill if it costs frames.
10. **The Undo bar is local to Search** (`SearchUndoBar`): `LibraryToast` has no action button.
11. The minimum length (2 UTF-16 units) is applied when writing, not to rows that already exist. A query of two or more units that folds to
    nothing (`!!`) is not stored.
12. **The review pass (2026-11-20)** changed these: history is read when the Search tab is selected and after a backup restore (a notification
    `searchHistoryRestored` posted from `BackupService.onRestored`), never at launch; the model's writes run in order on one chain (`settled()` awaits
    them in tests) and only the newest answer is shown; Clear all asks the store for the rows it removes, so Undo brings back what the store held, not what
    the list showed; a second removal adds to the open Undo; the strip and the list show one row per opened thing (`collapseByTarget`, as Android);
    restore follows Android's `toEntityOrNull` + `mergeRestore` (under two characters dropped, a target needs a known kind and an id, title cut to 200,
    count held to 1,000,000, spellings inside one payload add up); a write in the same millisecond as another row gets the next millisecond (no tied
    order on read back); Search's results area is one scroll view so the matching rows stay put while loading, empty and results swap; the atlas query
    for the browse tiles runs once per engine choice, not per grid rebuild; VoiceOver hears the Undo offer and tiles have a Remove action.
13. **Not changed from Android:** a one-letter row already stored survives the first read (Android's migration drops it); a matching row whose key
    equals the typed text is still shown above the results (Android shows it too).
14. No Settings toggle ("Save search history") was added; the requirement list does not ask for one.

## Unverified (needs CI, then the phone)

- Everything under `App/`: compile, Swift 6 strict concurrency, layout, the swap animation, the keyboard behaviour (the list while focused,
  the keyboard dropping on a tap, the strip's long-press menu), Dynamic Type, VoiceOver.
- The lightweight migration on a real store: `SearchHistoryTests.testRowsOfSchemaV1SurviveTheMigrationAndGetKeys` creates a version-1 store on
  disk and opens it through the plan; CI ran it with the rest (see the CI result at the end). The classes of the 18 unchanged models are shared by
  both versions (only `SearchHistoryRecord` is a second class); if SwiftData objects to that, give `SchemaV2` its own copies.
- Glass cost of the list with the X buttons, and whether the one-glass-shape container looks right over a tall list.
- The twin's field names (decision 5).
- The genre grid is rebuilt on a focus toggle and loses its scroll offset (Android keeps it with a remembered grid state); cosmetic, needs the phone.
- The single results scroll view (decision 12): the empty / loading states now sit inside a scroll view (`scrollBounceBehavior(.basedOnSize)`); the UI tests' ids are unchanged (`search.results` while a list shows, `search.state` otherwise).

## CI result

Run 44736583747 on 3dbb592 (`ci` workflow): `core` (PixlCore swift test) success, `app` (build + unit tests) success with 675 app tests and 0
failures, `ipa` skipped (the workflow skips it off the release branches). The log prints suite totals only, so the individual
`SearchHistoryTests` names are not in it; they compile into the same test target and the total has no failure. UI tests and the phone are
still to do.

### After the review pass

Run 44742639890 on ff6de1d (`ci` workflow): `core` (PixlCore swift test) success, `app` (build + unit tests) success with 680 app tests and 0
failures (675 before, plus the new `SearchHistoryTests` cases), `ipa` skipped. PixlCore also passed locally on Windows (all targets, the
search history suites included). UI tests and the phone are still to do.
