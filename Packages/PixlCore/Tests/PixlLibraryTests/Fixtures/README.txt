Test fixtures for PixlLibrary. Files in this folder are bundled with the test target (Bundle.module, subdirectory "Fixtures").

The *-golden.jsonl files are written by tools/android-reference/LibGen.java, which runs the Android app's compiled
classes (and, for search, the real songs_fts SQL through SQLite) on a desktop JVM. One JSON object per line:
{"fn": <case kind>, "in": <inputs>, "out": <Android's result>}. Regenerate them there; never edit by hand.

- artist-parsing-golden.jsonl  splitArtistsByDelimiters, extractArtistsFromTitle, collectArtistNames,
                               choosePreferredArtistName, normalizeMetadataText
- queue-golden.jsonl           Kotlin Random(seed), java.util.Random, String.hashCode, QueueUtils shuffles
- folder-golden.jsonl          FolderTreeBuilder trees and inferred storage roots, DirectoryRuleResolver
- recommendation-golden.jsonl  MusicRecommendationEngine rank/select/record, Muselle 2, HomeRecommendationPlanner,
                               PremiumSmartPlaylistEngine, PremiumInsightEngine, isRecentRelease
- stats-golden.jsonl           PlaybackStatsRepository.buildSummaryFromEvents in six time zones
- history-codec-golden.jsonl   playback_history.json parse/serialize (Gson)
- search-golden.jsonl          songs_fts MATCH + LIKE queries, album/artist LIKE, playlist contains
