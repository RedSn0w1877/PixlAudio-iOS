import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;
import com.google.gson.reflect.TypeToken;
import com.theveloper.pixelplay.data.database.FolderSongRow;
import com.theveloper.pixelplay.data.model.ArtistRef;
import com.theveloper.pixelplay.data.model.MusicFolder;
import com.theveloper.pixelplay.data.model.Song;
import com.theveloper.pixelplay.data.premium.ListeningInsights;
import com.theveloper.pixelplay.data.premium.PremiumInsightEngine;
import com.theveloper.pixelplay.data.premium.PremiumSmartPlaylistEngine;
import com.theveloper.pixelplay.data.premium.PremiumSmartToolsKt;
import com.theveloper.pixelplay.data.premium.SmartPlaylistPreset;
import com.theveloper.pixelplay.data.premium.SmartPlaylistResult;
import com.theveloper.pixelplay.data.recommendation.HomeMusicSection;
import com.theveloper.pixelplay.data.recommendation.HomeRecommendationPlanner;
import com.theveloper.pixelplay.data.recommendation.HomeRecommendations;
import com.theveloper.pixelplay.data.recommendation.Muselle2;
import com.theveloper.pixelplay.data.recommendation.MuselleVariant;
import com.theveloper.pixelplay.data.recommendation.MusicRecommendationEngine;
import com.theveloper.pixelplay.data.repository.FolderTreeBuilder;
import com.theveloper.pixelplay.data.stats.PlaybackStatsRepository;
import com.theveloper.pixelplay.data.stats.StatsTimeRange;
import com.theveloper.pixelplay.data.worker.ArtistParsingUtilsKt;
import com.theveloper.pixelplay.utils.DirectoryRuleResolver;
import com.theveloper.pixelplay.utils.ExtensionsKt;
import com.theveloper.pixelplay.utils.QueueUtils;
import java.io.PrintStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.Set;

/**
 * Golden vectors for PixlLibrary (stage 3a). Runs the Android app's compiled classes on a desktop JVM and writes
 * one JSON object per line ({"in": …, "out": …}) into Packages/PixlCore/Tests/PixlLibraryTests/Fixtures/.
 * The SQLite part runs the real songs_fts (FTS4, unicode61) queries through xerial sqlite-jdbc and also dumps the
 * unicode61 tokenizer tables into Sources/PixlLibrary/Unicode61Tables.swift (SQLite is public domain).
 *
 * Classpath (Windows separators): the app's compileDebugKotlin/classes, android.jar (platforms/android-37.0),
 * kotlin-stdlib 2.4.0, kotlinx-collections-immutable-jvm 0.5.0, kotlinx-coroutines-core-jvm, gson 2.14.0,
 * org.xerial sqlite-jdbc 3.41.2.2.
 *   javac -cp "$CP" LibGen.java && java -Duser.language=en -Duser.country=US -cp "$CP;." LibGen <repo root>
 */
public class LibGen {
    static final Gson G = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    static Path fixtures;

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.US);
        Path root = Path.of(args[0]);
        fixtures = root.resolve("Packages/PixlCore/Tests/PixlLibraryTests/Fixtures");
        Files.createDirectories(fixtures);
        artist();
        queue();
        folder();
        recommendation();
        stats();
        history();
        search(root);
    }

    // ---------------------------------------------------------------- helpers

    static JsonArray arr(List<String> list) {
        JsonArray a = new JsonArray();
        for (String s : list) a.add(s == null ? JsonNull.INSTANCE : new JsonPrimitive(s));
        return a;
    }

    static JsonElement str(String s) { return s == null ? JsonNull.INSTANCE : new JsonPrimitive(s); }

    static String bits(double d) { return "0x" + Long.toHexString(Double.doubleToRawLongBits(d)); }

    static void write(String name, List<JsonObject> lines) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (JsonObject o : lines) sb.append(G.toJson(o)).append('\n');
        Files.writeString(fixtures.resolve(name), sb.toString(), StandardCharsets.UTF_8);
        System.err.println(name + ": " + lines.size());
    }

    static JsonObject line(String fn, JsonElement in, JsonElement out) {
        JsonObject o = new JsonObject();
        o.addProperty("fn", fn);
        o.add("in", in);
        o.add("out", out);
        return o;
    }

    static Song song(String id, String title, String artist, long artistId, List<ArtistRef> artists, String album,
                     long albumId, String path, String contentUri, String albumArt, long duration, String genre,
                     boolean fav, int track, Integer disc, int year, long dateAdded, long dateModified, String spotifyId) {
        return new Song(id, title, artist, artistId, artists, album, albumId, null, path, contentUri, albumArt,
            duration, genre, null, fav, track, disc, year, dateAdded, dateModified, "audio/mpeg", 0, 0, spotifyId);
    }

    static JsonObject songJson(Song s) {
        JsonObject o = new JsonObject();
        o.addProperty("id", s.getId());
        o.addProperty("title", s.getTitle());
        o.addProperty("artist", s.getArtist());
        o.addProperty("artistId", s.getArtistId());
        JsonArray refs = new JsonArray();
        for (ArtistRef r : s.getArtists()) {
            JsonArray x = new JsonArray();
            x.add(r.getId());
            x.add(r.getName());
            x.add(r.isPrimary());
            refs.add(x);
        }
        o.add("artists", refs);
        o.addProperty("album", s.getAlbum());
        o.addProperty("albumId", s.getAlbumId());
        o.addProperty("path", s.getPath());
        o.addProperty("contentUri", s.getContentUriString());
        o.add("albumArt", str(s.getAlbumArtUriString()));
        o.addProperty("duration", s.getDuration());
        o.add("genre", str(s.getGenre()));
        o.addProperty("isFavorite", s.isFavorite());
        o.addProperty("track", s.getTrackNumber());
        o.add("disc", s.getDiscNumber() == null ? JsonNull.INSTANCE : new JsonPrimitive(s.getDiscNumber()));
        o.addProperty("year", s.getYear());
        o.addProperty("dateAdded", s.getDateAdded());
        o.addProperty("dateModified", s.getDateModified());
        o.add("spotifyId", str(s.getSpotifyId()));
        return o;
    }

    static JsonArray songsJson(List<Song> songs) {
        JsonArray a = new JsonArray();
        for (Song s : songs) a.add(songJson(s));
        return a;
    }

    static JsonArray ids(List<Song> songs) {
        JsonArray a = new JsonArray();
        for (Song s : songs) a.add(s.getId());
        return a;
    }

    static String pick(Random r, String[] pool) { return pool[r.nextInt(pool.length)]; }

    // ---------------------------------------------------------------- A. artist parsing

    static void artist() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        String[] strs = {
            "W&W", "AC/DC", "AC\\\\/DC", "Lost & Found", "Black Country, New Road", "Drake feat. Rihanna",
            "Drake Feat. Rihanna & Future", "Marshmello x Bastille", "A x B", "Ax B", "A X B", "A;B; C ;;D", "A / B",
            "feat. Someone", "Artist feat.", "Artist ft Other", "Artist with Friends", "Withers", "A vs. B vs C",
            "A, B and C", " ", "", "Prodigy", "A prod. B", "A\tfeat.\nB", "Ελληνικά feat. Σοφία",
            "東京事変 feat. 椎名林檎", "A FEAT. B", "Beyoncé & JAY-Z", "A\u0085feat", "A feat ", "A feat\n",
            "A feat\r\n", "AESCAPEDB", "A\\\\;B;C", "A\\\\\\\\;B", "a+b", "Calvin Harris, Pharrell Williams",
            "A;a;A", "  x  ", "A featuring B ft. C feat D", "A&&B", "A ;B", "ÄÖÜ ft. ÆØÅ", "A/B/A/B", "x", "A x",
            "x B", "A  x  B", "A with", "with B", "A feat. B", "Guns N' Roses", "E", "Eee E eE",
            "a\u0000b", "A ESCAPED B", "Ⅻ feat. Ⅷ", "AÄBäC", "aΣbσcς", "xǄyǆzǅ", "1K2k3K", "A wıth B",
            "A ſt B", "Song (wıth X)"
        };
        List<List<String>> delims = List.of(
            List.of(), List.of(";"), List.of("/", ";", ",", "+", "&"), List.of(",", "&"), List.of("E"),
            List.of("e", "ee"), List.of(" "), List.of("x"), List.of("."), List.of(""), List.of("\\"),
            List.of("feat."), List.of("&", "&&"), List.of("ä"), List.of("σ"), List.of("ǆ"), List.of("k"));
        List<List<String>> words = List.of(
            List.of(), ExtensionsKt.getDEFAULT_WORD_DELIMITERS(), List.of("feat."), List.of("x"),
            List.of("with", "x", "&"), List.of("E"), List.of("", "ft"), List.of("vs", "VS."), List.of(" x "));
        for (String s : strs) for (List<String> d : delims) for (List<String> w : words) {
            JsonObject in = new JsonObject();
            in.addProperty("s", s);
            in.add("d", arr(d));
            in.add("w", arr(w));
            out.add(line("split", in, arr(ExtensionsKt.splitArtistsByDelimiters(s, d, w))));
        }
        String[] titles = {
            "Feels (feat. Katy Perry & Big Sean)", "Song [ft. A]", "Song (with B) (feat. C, D)", "Song (Feat.  X)",
            "Song (featuring Y]", "Song (\\feat. Z)", "Song (\\\\feat. Z)", "Song (prod. by W)", "Song (feat.)",
            "Song (feat. )", "Song (feat. A", "(feat. A) Song (feat. A)", "Song (ft.A)", "Song (FT A)",
            "Song (feat. A\nB)", "Song (with)", "Song（feat. A）", "Song (feat. A) - Remix (feat. B)",
            "Song (featuring A (B))", "Song [feat. [A]]", "Song (feat. A; B / C)", "Song (feat\tA)",
            "Song (ft. A) (ft. A)", "Song (with  )", "Song (prod A)", "Song (Prod. A & B)", "", " ", "Plain Song",
            "Song (feat. A)(feat. B)", "Song (feat. A ) x", "Song (feat. Σ)", "Song [WITH A]", "Song (feature A)",
            "Song (feat. A x B)", "Song (feat. A\u0085)", "Song ( feat. A)", "Song (  ft   A  )", "Song (wıth X)",
            "Song (FEAT. A)", "Song (feat. 😀 & 😎)", "[ft. A] Song", "Song (feat. A] (with B)"
        };
        List<List<String>> td = List.of(List.of(), List.of(";"), List.of(",", "&"), List.of("/", ";", ",", "+", "&"));
        List<List<String>> tw = List.of(List.of(), ExtensionsKt.getDEFAULT_WORD_DELIMITERS(), List.of("x"));
        for (String t : titles) for (List<String> d : td) for (List<String> w : tw) {
            JsonObject in = new JsonObject();
            in.addProperty("s", t);
            in.add("d", arr(d));
            in.add("w", arr(w));
            kotlin.Pair<String, List<String>> p = ExtensionsKt.extractArtistsFromTitle(t, d, w);
            JsonObject o = new JsonObject();
            o.addProperty("title", p.getFirst());
            o.add("artists", arr(p.getSecond()));
            out.add(line("title", in, o));
        }
        String[][] collect = {
            {"Calvin Harris, Pharrell Williams", "Feels (feat. Katy Perry & Big Sean)"},
            {"W&W", "Rave Culture"}, {"AC/DC", "Back In Black"}, {"A", "Song (feat. a)"},
            {"A feat. B", "Song (feat. B & C)"}, {"", "Song (feat. X)"}, {"  ", "Song"}, {"Ä", "Song (ft. ä)"},
            {"A", "Song (with A; B)"}, {"Gorillaz feat. Stevie Nicks", "Oil"}, {"A;B", "Song (prod. B)"}
        };
        for (String[] c : collect) for (List<String> d : td) for (List<String> w : tw) for (boolean ex : new boolean[]{true, false}) {
            JsonObject in = new JsonObject();
            in.addProperty("raw", c[0]);
            in.addProperty("title", c[1]);
            in.add("d", arr(d));
            in.add("w", arr(w));
            in.addProperty("extract", ex);
            out.add(line("collect", in, arr(ArtistParsingUtilsKt.collectArtistNames(c[0], c[1], d, w, ex))));
        }
        String[][] prefer = {
            {"Calvin Harris", "Calvin Harris, Pharrell Williams, Katy Perry, Big Sean, Funk Wav"},
            {"Calvin Harris, Pharrell Williams, Katy Perry", "Calvin Harris"}, {"", "B"}, {"A", " "},
            {"  ", "  "}, {"Abc", "Abcd"}, {"Abcd ", "Abc"}, {"A & B", "A, B"}, {"A", "A"}, {" A ", "A"}
        };
        for (String[] c : prefer) for (List<String> d : td) for (List<String> w : tw) {
            JsonObject in = new JsonObject();
            in.addProperty("local", c[0]);
            in.addProperty("media", c[1]);
            in.add("d", arr(d));
            in.add("w", arr(w));
            out.add(line("prefer", in, new JsonPrimitive(ArtistParsingUtilsKt.choosePreferredArtistName(c[0], c[1], d, w))));
        }
        String[] norm = {
            null, "", "   ", " Café ", "CafÃ©", "Ã", "â€™", "BeyoncÃ©", "�abc", "ðŸŽµ Song", "Ÿ",
            "a\u0000b", "é", "Å", "AÌ\u0081", "plain", "Ã©Ã¨ ok", "\u0000", "â", "Ã\u0000", "日本語 â",
            "ﬁ ligature", "Ã€", "x Ÿ y", "ÃƒÂ©"
        };
        for (String s : norm) out.add(line("normalize", str(s), str(ExtensionsKt.normalizeMetadataText(s))));
        write("artist-parsing-golden.jsonl", out);
    }

    // ---------------------------------------------------------------- E. random + queue

    static void queue() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        int[] intSeeds = {0, 1, 7, 42, 99, -1, Integer.MIN_VALUE, Integer.MAX_VALUE, 123456789};
        long[] longSeeds = {0L, 1L, 42L, -1L, 1L << 33, Long.MIN_VALUE, Long.MAX_VALUE, 1_800_000_000_000L};
        int[] bounds = {1, 2, 3, 7, 16, 100, 1000, 1 << 30, Integer.MAX_VALUE, 5, 10_000};
        for (int seed : intSeeds) out.add(line("kotlinRandomInt", new JsonPrimitive(seed), kotlinSeq(kotlin.random.RandomKt.Random(seed), bounds)));
        for (long seed : longSeeds) out.add(line("kotlinRandomLong", new JsonPrimitive(seed), kotlinSeq(kotlin.random.RandomKt.Random(seed), bounds)));
        for (long seed : longSeeds) {
            Random r = new Random(seed);
            JsonArray a = new JsonArray();
            a.add(r.nextInt());
            a.add(bits(r.nextDouble()));
            a.add(Long.toString(r.nextLong()));
            for (int b : bounds) a.add(r.nextInt(b));
            a.add(bits(r.nextDouble()));
            a.add(Long.toString(r.nextLong()));
            out.add(line("javaRandom", new JsonPrimitive(Long.toString(seed)), a));
        }
        String[] hashes = {"", "a", "Artist|Track", "東京事変|女の子", "😀", "artist a|song 1", "x".repeat(100)};
        for (String h : hashes) out.add(line("hashCode", new JsonPrimitive(h), new JsonPrimitive(h.hashCode())));
        int[] sizes = {0, 1, 2, 3, 5, 10, 32, 100, 600, 1500};
        for (int n : sizes) for (int seed : new int[]{1, 42, 99, 7}) {
            List<Integer> list = new ArrayList<>();
            for (int i = 0; i < n; i++) list.add(i);
            JsonObject in = new JsonObject();
            in.addProperty("n", n);
            in.addProperty("seed", seed);
            out.add(line("fisherYates", in, intList(QueueUtils.INSTANCE.fisherYatesCopy(list, kotlin.random.RandomKt.Random(seed)))));
            List<Song> songs = new ArrayList<>();
            for (int i = 0; i < n; i++) songs.add(song("song-" + i, "Song " + i, "Artist", 1, List.of(), "Album", 1,
                "/tmp/song-" + i + ".mp3", "content://pixelplay/song/" + i, null, 180_000, null, false, 0, null, 0, 0, 0, null));
            for (int anchor : new int[]{0, n / 2, n - 1, n + 5, -3}) {
                JsonObject in2 = new JsonObject();
                in2.addProperty("n", n);
                in2.addProperty("seed", seed);
                in2.addProperty("anchor", anchor);
                out.add(line("anchored", in2, ids(QueueUtils.INSTANCE.buildAnchoredShuffleQueue(songs, anchor, kotlin.random.RandomKt.Random(seed)))));
                for (boolean zero : new boolean[]{false, true}) {
                    final int a = anchor;
                    final boolean z = zero;
                    @SuppressWarnings("unchecked")
                    List<Song> res = (List<Song>) kotlinx.coroutines.BuildersKt.runBlocking(
                        kotlin.coroutines.EmptyCoroutineContext.INSTANCE,
                        (scope, cont) -> QueueUtils.INSTANCE.buildAnchoredShuffleQueueSuspending(songs, a, z, kotlin.random.RandomKt.Random(seed), cont));
                    JsonObject in3 = in2.deepCopy();
                    in3.addProperty("startAtZero", zero);
                    out.add(line("anchoredSuspending", in3, ids(res)));
                }
            }
        }
        write("queue-golden.jsonl", out);
    }

    static JsonArray intList(List<Integer> l) {
        JsonArray a = new JsonArray();
        for (Integer i : l) a.add(i);
        return a;
    }

    static JsonArray kotlinSeq(kotlin.random.Random r, int[] bounds) {
        JsonArray a = new JsonArray();
        for (int i = 0; i < 4; i++) a.add(r.nextInt());
        for (int b : bounds) a.add(r.nextInt(b));
        for (int b : bounds) a.add(r.nextInt(b));
        return a;
    }

    // ---------------------------------------------------------------- D. folders

    static void folder() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        FolderTreeBuilder builder = new FolderTreeBuilder();
        Method build = FolderTreeBuilder.class.getMethod("buildFolderTreeForRoots$app", List.class, Set.class);
        Method infer = FolderTreeBuilder.class.getMethod("inferRemovableStorageRoots$app", List.class, String.class, Set.class);
        String[] roots = {"/storage/emulated/0", "/storage/1234-5678", "/mnt/media_rw/ABCD-1234", "/sdcard", "/mnt/usb",
            "/storage/emulated/10", "/data/media", "relative", "/storage/emulated/0-other"};
        String[] segs = {"Music", "music", "MUSIC", "Album", "album", "Ünïcode", "Spaces Dir", "x", "a", "B", "Zed",
            "storage", "emulated", "0", "_hidden", "Ärger", "ä", "10", "2"};
        String[] titles = {"Song", "song", "B Song", "a song", "Ácid", "zeta", "Alpha", "10 Ten", "2 Two", ""};
        for (int k = 0; k < 120; k++) {
            Random r = new Random(5000 + k);
            int n = r.nextInt(30);
            List<FolderSongRow> rows = new ArrayList<>();
            for (int i = 0; i < n; i++) {
                StringBuilder p = new StringBuilder(pick(r, roots));
                int depth = r.nextInt(5);
                for (int d = 0; d < depth; d++) p.append('/').append(pick(r, segs));
                if (r.nextInt(8) == 0) p.append('/');
                if (r.nextInt(25) == 0) p = new StringBuilder(r.nextBoolean() ? "" : "/");
                rows.add(new FolderSongRow(r.nextInt(50) - 5, p.toString(), pick(r, titles) + (r.nextBoolean() ? "" : " " + i),
                    r.nextInt(4) == 0 ? "content://art/" + i : null));
            }
            Set<String> sel = new LinkedHashSet<>();
            int m = 1 + r.nextInt(3);
            for (int i = 0; i < m; i++) {
                String root = pick(r, roots);
                if (r.nextInt(6) == 0) root = root + "/Music";
                if (r.nextInt(8) == 0) root = root + "/";
                if (r.nextInt(15) == 0) root = "";
                sel.add(root);
            }
            JsonObject in = new JsonObject();
            JsonArray rs = new JsonArray();
            for (FolderSongRow row : rows) {
                JsonArray x = new JsonArray();
                x.add(row.getId());
                x.add(row.getParentDirectoryPath());
                x.add(row.getTitle());
                x.add(str(row.getAlbumArtUriString()));
                rs.add(x);
            }
            in.add("rows", rs);
            in.add("roots", arr(new ArrayList<>(sel)));
            @SuppressWarnings("unchecked")
            List<MusicFolder> tree = (List<MusicFolder>) build.invoke(builder, rows, sel);
            out.add(line("tree", in, folders(tree)));
            String internal = r.nextBoolean() ? "/storage/emulated/0" : "/storage/emulated/0/";
            Set<String> known = new LinkedHashSet<>();
            if (r.nextBoolean()) known.add("/storage/1234-5678");
            if (r.nextInt(3) == 0) known.add("/mnt/media_rw/ABCD-1234/");
            JsonObject in2 = new JsonObject();
            in2.add("rows", rs);
            in2.addProperty("internal", internal);
            in2.add("known", arr(new ArrayList<>(known)));
            @SuppressWarnings("unchecked")
            Set<String> inferred = (Set<String>) infer.invoke(builder, rows, internal, known);
            out.add(line("infer", in2, arr(new ArrayList<>(inferred))));
        }
        String[] rulePaths = {"/storage/emulated/0/Music", "/storage/emulated/0/music", "/storage/emulated/0/Music/Fav",
            "/storage/emulated/0/Music/Favorites", "/storage/emulated/0/Music/Favorites/Chill", "/storage/emulated/0",
            "/storage/emulated/0/Podcasts", "/storage/emulated/0/MusicX", "/STORAGE/EMULATED/0/MUSIC/a", "", "/"};
        for (int k = 0; k < 200; k++) {
            Random r = new Random(9000 + k);
            Set<String> allowed = new LinkedHashSet<>();
            Set<String> blocked = new LinkedHashSet<>();
            for (int i = r.nextInt(3); i > 0; i--) allowed.add(pick(r, rulePaths) + (r.nextInt(5) == 0 ? "/" : ""));
            for (int i = r.nextInt(3); i > 0; i--) blocked.add(pick(r, rulePaths) + (r.nextInt(5) == 0 ? "/" : ""));
            DirectoryRuleResolver resolver = new DirectoryRuleResolver(allowed, blocked);
            JsonArray res = new JsonArray();
            for (String p : rulePaths) res.add(resolver.isBlocked(p));
            JsonObject in = new JsonObject();
            in.add("allowed", arr(new ArrayList<>(allowed)));
            in.add("blocked", arr(new ArrayList<>(blocked)));
            in.add("paths", arr(Arrays.asList(rulePaths)));
            out.add(line("rules", in, res));
        }
        write("folder-golden.jsonl", out);
    }

    static JsonArray folders(List<MusicFolder> list) {
        JsonArray a = new JsonArray();
        for (MusicFolder f : list) {
            JsonObject o = new JsonObject();
            o.addProperty("path", f.getPath());
            o.addProperty("name", f.getName());
            JsonArray songs = new JsonArray();
            for (Song s : f.getSongs()) {
                JsonArray x = new JsonArray();
                x.add(s.getId());
                x.add(s.getTitle());
                x.add(s.getPath());
                x.add(str(s.getAlbumArtUriString()));
                songs.add(x);
            }
            o.add("songs", songs);
            o.add("sub", folders(f.getSubFolders()));
            o.addProperty("total", f.getTotalSongCount());
            o.addProperty("totalSub", f.getTotalSubFolderCount());
            a.add(o);
        }
        return a;
    }

    // ---------------------------------------------------------------- B. recommendation

    static final String[] ARTISTS = {"Artist A", "artist a ", "Ártist", "", "  ", "B", "Ｂ", "C  D", "c d", "Æon",
        "Singer", "Band", "İnci", "Σίσυφος"};
    static final String[] TITLES = {"Track 1", "track  1", "Ｔｒａｃｋ 1", "Song", "song", "Intro", "Outro", "",
        "  ", "Ballad", "Long Song", "Interlude", "Café", "Café", "ﬁre", "fire", "Σ", "Ⅻ", "A\tB", "Theme"};
    static final String[] GENRES = {null, "", "Unknown", "unknown", "Jazz", "jazz ", "Pop", "Rock", "Ambient"};
    static final String[] IDS = {"1", "2", "-42", "spotify_x", "spotify_remote", "local", "remote-1", "abc", "10", "07"};

    static List<Song> randomSongs(Random r, int n, String prefix) {
        List<Song> songs = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            String id = r.nextInt(12) == 0 ? pick(r, IDS) : prefix + i;
            String artist = pick(r, ARTISTS);
            List<ArtistRef> refs = new ArrayList<>();
            if (r.nextInt(4) == 0) {
                refs.add(new ArtistRef(r.nextInt(5), artist.trim().isEmpty() ? "X" : artist, r.nextBoolean()));
                if (r.nextBoolean()) refs.add(new ArtistRef(r.nextInt(5) + 5, pick(r, ARTISTS), r.nextBoolean()));
            }
            long duration = new long[]{0, 1, 60_000, 180_000, 240_000, 240_001, 420_000, 600_000, -5}[r.nextInt(9)];
            long dateAdded = new long[]{0, 1_700_000_000L, 1_799_000_000L, 1_799_500_000_000L, 1_799_990_000_000L, 9_999_999_999L, 10_000_000_000L, -1}[r.nextInt(8)];
            songs.add(song(id, pick(r, TITLES), artist, r.nextInt(3) - 1, refs, r.nextInt(3) == 0 ? "" : "Album " + r.nextInt(4),
                r.nextInt(5), "/m/" + i + ".mp3", "content://" + i, null, duration, pick(r, GENRES), r.nextInt(6) == 0,
                r.nextInt(12), r.nextBoolean() ? null : r.nextInt(3), new int[]{0, 1990, 2005, 2020, 2024}[r.nextInt(5)],
                dateAdded, r.nextInt(1000), r.nextInt(5) == 0 ? (r.nextBoolean() ? "x" : "remote") : null));
        }
        return songs;
    }

    static void recommendation() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        MusicRecommendationEngine E = MusicRecommendationEngine.INSTANCE;
        for (int k = 0; k < 90; k++) {
            Random r = new Random(1000 + k);
            int n = k < 3 ? k : r.nextInt(k < 60 ? 36 : 90);
            List<Song> songs = randomSongs(r, n, "s");
            long now = 1_800_000_000_000L + r.nextInt(1000) * 3_600_000L;
            long seed = k % 3 == 0 ? r.nextLong() : r.nextInt(30_000);
            Set<String> favs = new LinkedHashSet<>();
            Map<String, MusicRecommendationEngine.Signal> signals = new LinkedHashMap<>();
            Map<String, MusicRecommendationEngine.History> history = new LinkedHashMap<>();
            List<MusicRecommendationEngine.Signal> madeS = new ArrayList<>();
            List<MusicRecommendationEngine.History> madeH = new ArrayList<>();
            for (Song s : songs) {
                if (r.nextInt(5) == 0) favs.add(r.nextInt(6) == 0 ? "spotify_" + s.getSpotifyId() : s.getId());
                int c = r.nextInt(10);
                if (c < 5) {
                    MusicRecommendationEngine.Signal sig = new MusicRecommendationEngine.Signal(r.nextInt(30), r.nextInt(20),
                        r.nextInt(15), r.nextInt(10), r.nextInt(4) == 0 ? 0 : now - r.nextInt(40) * 86_400_000L - r.nextInt(86_400_000),
                        r.nextInt(5_000_000));
                    signals.put(s.getId(), sig);
                    madeS.add(sig);
                } else if (c == 5 && !madeS.isEmpty()) {
                    signals.put(s.getId(), madeS.get(r.nextInt(madeS.size())));
                } else if (c == 6) {
                    signals.put(s.getId(), new MusicRecommendationEngine.Signal());
                }
                int h = r.nextInt(10);
                if (h < 5) {
                    MusicRecommendationEngine.History hist = new MusicRecommendationEngine.History(r.nextInt(50), r.nextInt(9_000_000),
                        r.nextInt(4) == 0 ? 0 : now - r.nextInt(60) * 86_400_000L - r.nextInt(3_600_000));
                    history.put(s.getId(), hist);
                    madeH.add(hist);
                } else if (h == 5 && !madeH.isEmpty()) {
                    history.put(s.getId(), madeH.get(r.nextInt(madeH.size())));
                }
            }
            List<Song> discoveries = randomSongs(r, r.nextInt(8), "d");
            List<Song> releases = randomSongs(r, r.nextInt(6), "r");
            if (!songs.isEmpty() && r.nextBoolean()) discoveries.add(songs.get(0));
            JsonObject in = new JsonObject();
            in.add("songs", songsJson(songs));
            in.add("favorites", arr(new ArrayList<>(favs)));
            in.add("signals", evidence(signals));
            in.add("history", evidence(history));
            in.addProperty("now", now);
            in.addProperty("seed", Long.toString(seed));
            in.add("discoveries", songsJson(discoveries));
            in.add("releases", songsJson(releases));
            JsonObject o = new JsonObject();
            List<MusicRecommendationEngine.Pick> ranked = E.rank(songs, favs, signals, history, now, seed);
            o.add("rank", picks(ranked));
            JsonArray sel = new JsonArray();
            for (int limit : new int[]{0, 1, 5, 12, 30}) for (float f : new float[]{0f, 0.25f, 0.5f, 0.6f, 0.9f, -1f}) {
                JsonObject x = new JsonObject();
                x.addProperty("limit", limit);
                x.addProperty("fraction", f);
                x.add("ids", ids(map(E.select(ranked, limit, f))));
                sel.add(x);
            }
            o.add("select", sel);
            o.add("muselle2", picks(Muselle2.INSTANCE.rank(songs, favs, signals, history, now, seed)));
            o.add("planBasic", plan(HomeRecommendationPlanner.INSTANCE.plan(songs, favs, signals, history, discoveries, releases, now, seed, MuselleVariant.BASIC)));
            o.add("planPlus", plan(HomeRecommendationPlanner.INSTANCE.plan(songs, favs, signals, history, discoveries, releases, now, seed, MuselleVariant.PLUS)));
            JsonObject smart = new JsonObject();
            int limit = r.nextInt(4) == 0 ? 0 : 1 + r.nextInt(30);
            in.addProperty("smartLimit", limit);
            for (SmartPlaylistPreset p : SmartPlaylistPreset.values()) {
                SmartPlaylistResult res = PremiumSmartPlaylistEngine.INSTANCE.build(p, songs, favs, history, signals, now, seed, limit);
                smart.add(p.name(), ids(res.getSongs()));
            }
            o.add("smart", smart);
            ListeningInsights ins = PremiumInsightEngine.INSTANCE.summarize(songs, history, signals);
            JsonObject io = new JsonObject();
            io.addProperty("songCount", ins.getSongCount());
            io.addProperty("playedSongCount", ins.getPlayedSongCount());
            io.addProperty("totalListeningMs", ins.getTotalListeningMs());
            io.addProperty("completionRatePercent", ins.getCompletionRatePercent());
            io.add("topArtists", pairs(ins.getTopArtists()));
            io.add("topGenres", pairs(ins.getTopGenres()));
            io.addProperty("discoveryRatePercent", ins.getDiscoveryRatePercent());
            io.addProperty("label", PremiumSmartToolsKt.totalListeningLabel(ins));
            o.add("insights", io);
            JsonArray keys = new JsonArray();
            for (Song s : songs) {
                JsonArray x = new JsonArray();
                x.add(E.artistKey(s));
                x.add(E.recordingKey(s));
                keys.add(x);
            }
            o.add("keys", keys);
            out.add(line("scenario", in, o));
        }
        for (int k = 0; k < 300; k++) {
            Random r = new Random(7000 + k);
            MusicRecommendationEngine.Signal prev = new MusicRecommendationEngine.Signal(r.nextInt(5) == 0 ? 999_999 + r.nextInt(3) : r.nextInt(10),
                r.nextInt(10), r.nextInt(10), r.nextInt(10), r.nextBoolean() ? 0 : 1_800_000_000_000L, r.nextInt(100_000));
            long listened = new long[]{-1, 0, 4_999, 5_000, 8_000, 29_999, 30_000, 59_999, 60_000, 144_000, 170_000, 400_000}[r.nextInt(12)];
            long duration = new long[]{-1, 0, 10_000, 90_000, 180_000, 600_000}[r.nextInt(6)];
            boolean vol = r.nextBoolean(), changed = r.nextBoolean();
            long now = 1_800_000_000_000L + (r.nextInt(3) - 1) * 60_000L;
            MusicRecommendationEngine.Signal res = E.record(prev, listened, duration, vol, changed, now);
            JsonObject in = new JsonObject();
            in.add("prev", signalJson(prev));
            in.addProperty("listened", listened);
            in.addProperty("duration", duration);
            in.addProperty("voluntary", vol);
            in.addProperty("changedTrack", changed);
            in.addProperty("now", now);
            out.add(line("record", in, signalJson(res)));
        }
        LocalDate today = LocalDate.of(2026, 9, 8);
        String[] dates = {"2026-09-08", "2026-03-12", "2026-03-11", "2026-09-09", "2026", "2026-08", "2026-02-30",
            null, "2026-9-08", "2026-09-8 ", "+2026-09-0", "2025-12-31", "2024-02-29", "2023-02-29", "0000-01-01",
            "2026-13-01", "2026-00-10", "2026-09-00", "abcd-ef-gh", "2026/09/08", "2026-03-13"};
        for (String d : dates) {
            JsonObject in = new JsonObject();
            in.add("value", str(d));
            in.addProperty("today", today.toString());
            out.add(line("recentRelease", in, new JsonPrimitive(HomeRecommendationPlanner.INSTANCE.isRecentRelease(d, today))));
        }
        write("recommendation-golden.jsonl", out);
    }

    static JsonArray pairs(List<kotlin.Pair<String, Integer>> list) {
        JsonArray a = new JsonArray();
        for (kotlin.Pair<String, Integer> p : list) {
            JsonArray x = new JsonArray();
            x.add(p.getFirst());
            x.add(p.getSecond());
            a.add(x);
        }
        return a;
    }

    static List<Song> map(List<MusicRecommendationEngine.Pick> picks) {
        List<Song> s = new ArrayList<>();
        for (MusicRecommendationEngine.Pick p : picks) s.add(p.getSong());
        return s;
    }

    static JsonObject signalJson(MusicRecommendationEngine.Signal s) {
        JsonObject o = new JsonObject();
        o.addProperty("sessions", s.getSessions());
        o.addProperty("completions", s.getCompletions());
        o.addProperty("earlySkips", s.getEarlySkips());
        o.addProperty("voluntaryPlays", s.getVoluntaryPlays());
        o.addProperty("lastPlayedMs", s.getLastPlayedMs());
        o.addProperty("listenedMs", s.getListenedMs());
        return o;
    }

    static <T> JsonArray evidence(Map<String, T> map) {
        IdentityHashMap<Object, Integer> idents = new IdentityHashMap<>();
        JsonArray a = new JsonArray();
        for (Map.Entry<String, T> e : map.entrySet()) {
            Integer src = idents.get(e.getValue());
            if (src == null) {
                src = idents.size();
                idents.put(e.getValue(), src);
            }
            JsonObject o;
            if (e.getValue() instanceof MusicRecommendationEngine.Signal s) {
                o = signalJson(s);
            } else {
                MusicRecommendationEngine.History h = (MusicRecommendationEngine.History) e.getValue();
                o = new JsonObject();
                o.addProperty("plays", h.getPlays());
                o.addProperty("listenedMs", h.getListenedMs());
                o.addProperty("lastPlayedMs", h.getLastPlayedMs());
            }
            o.addProperty("key", e.getKey());
            o.addProperty("src", src);
            a.add(o);
        }
        return a;
    }

    static JsonArray picks(List<MusicRecommendationEngine.Pick> picks) {
        JsonArray a = new JsonArray();
        for (MusicRecommendationEngine.Pick p : picks) {
            JsonArray x = new JsonArray();
            x.add(p.getSong().getId());
            x.add(bits(p.getScore()));
            x.add(p.getReason());
            x.add(p.getUnheard());
            a.add(x);
        }
        return a;
    }

    static JsonObject plan(HomeRecommendations rec) {
        JsonObject o = new JsonObject();
        o.add("mixes", sections(rec.getMixes()));
        o.add("shelves", sections(rec.getShelves()));
        return o;
    }

    static JsonArray sections(List<HomeMusicSection> list) {
        JsonArray a = new JsonArray();
        for (HomeMusicSection s : list) {
            JsonObject o = new JsonObject();
            o.addProperty("id", s.getId());
            o.addProperty("title", s.getTitle());
            o.addProperty("subtitle", s.getSubtitle());
            o.add("songs", ids(s.getSongs()));
            JsonArray reasons = new JsonArray();
            for (Map.Entry<String, String> e : s.getReasons().entrySet()) {
                JsonArray x = new JsonArray();
                x.add(e.getKey());
                x.add(e.getValue());
                reasons.add(x);
            }
            o.add("reasons", reasons);
            a.add(o);
        }
        return a;
    }

    // ---------------------------------------------------------------- C. stats

    static PlaybackStatsRepository statsRepository() throws Exception {
        Field uf = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        uf.setAccessible(true);
        sun.misc.Unsafe unsafe = (sun.misc.Unsafe) uf.get(null);
        PlaybackStatsRepository repo = (PlaybackStatsRepository) unsafe.allocateInstance(PlaybackStatsRepository.class);
        set(repo, "sessionGapThresholdMs", 30L * 60_000L);
        set(repo, "gson", new Gson());
        set(repo, "eventsType", new TypeToken<List<PlaybackStatsRepository.PlaybackEvent>>() {}.getType());
        return repo;
    }

    static void set(Object o, String name, Object value) throws Exception {
        Field f = o.getClass().getDeclaredField(name);
        f.setAccessible(true);
        f.set(o, value);
    }

    static void stats() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        PlaybackStatsRepository repo = statsRepository();
        Method build = PlaybackStatsRepository.class.getMethod("buildSummaryFromEvents$app", StatsTimeRange.class, List.class,
            long.class, List.class, ZoneId.class);
        String[] zones = {"UTC", "America/New_York", "Asia/Kolkata", "Australia/Lord_Howe", "America/Sao_Paulo", "Pacific/Chatham"};
        long[] nows = {1_775_779_200_000L, 1_541_300_000_000L, 1_711_846_800_000L, 1_798_761_599_000L, 1_600_000_000_000L,
            1_759_640_400_000L, 1_552_788_000_000L};
        String[] genres = {null, "", "Pop", "pop", "Rock", "Jazz"};
        String[] albums = {"", "Album A", "Album B", "Album A"};
        for (int k = 0; k < 160; k++) {
            Random r = new Random(3000 + k);
            String zone = zones[k % zones.length];
            long now = nows[r.nextInt(nows.length)] + r.nextInt(48) * 3_600_000L;
            int songCount = 1 + r.nextInt(8);
            List<Song> songs = new ArrayList<>();
            for (int i = 0; i < songCount; i++) {
                List<ArtistRef> refs = new ArrayList<>();
                int nr = r.nextInt(4);
                for (int j = 0; j < nr; j++) refs.add(new ArtistRef(j, new String[]{"Artist A", " artist a", "Artist B", "", "Ünï", "  "}[r.nextInt(6)], r.nextBoolean()));
                String title = r.nextInt(6) == 0 ? (r.nextBoolean() ? "" : " ") : "Song " + i;
                String path = r.nextInt(5) == 0 ? (r.nextBoolean() ? "" : "/music/dir/") : "/music/file" + i + ".mp3";
                songs.add(song("song-" + i, title, new String[]{"Artist", "", " ", "Solo"}[r.nextInt(4)], 1, refs,
                    albums[r.nextInt(albums.length)], 1, path, "content://" + i, r.nextBoolean() ? null : "art://" + i,
                    300_000, genres[r.nextInt(genres.length)], false, 0, null, 0, 0, 0, null));
            }
            int eventCount = r.nextInt(26);
            List<PlaybackStatsRepository.PlaybackEvent> events = new ArrayList<>();
            long span = new long[]{86_400_000L, 7 * 86_400_000L, 40 * 86_400_000L, 400 * 86_400_000L, 3 * 365 * 86_400_000L}[r.nextInt(5)];
            for (int i = 0; i < eventCount; i++) {
                long end = now - (long) (r.nextDouble() * span) + (r.nextInt(10) == 0 ? 3_600_000L : 0);
                long dur = new long[]{0, 1_000, 10_000, 59_999, 180_000, 900_000, 3_600_000, 10_000_000}[r.nextInt(8)];
                Long start = r.nextInt(4) == 0 ? null : end - dur + (r.nextInt(6) == 0 ? 5_000 : 0);
                Long endTs = r.nextInt(5) == 0 ? null : end;
                long ts = endTs == null ? end : end + (r.nextInt(5) == 0 ? 1_000 : 0);
                String id = r.nextInt(10) == 0 ? "unknown-" + i : "song-" + r.nextInt(songCount);
                events.add(new PlaybackStatsRepository.PlaybackEvent(id, ts, dur, start, endTs));
                if (r.nextInt(6) == 0) events.add(new PlaybackStatsRepository.PlaybackEvent(id, ts + 2_000, 30_000, ts - 28_000, ts + 2_000));
            }
            JsonObject in = new JsonObject();
            in.addProperty("zone", zone);
            in.addProperty("now", now);
            in.add("songs", songsJson(songs));
            in.add("events", eventsJson(events));
            JsonObject o = new JsonObject();
            for (StatsTimeRange range : StatsTimeRange.values()) {
                try {
                    Object s = build.invoke(repo, range, songs, now, events, ZoneId.of(zone));
                    o.add(range.name(), summary((PlaybackStatsRepository.PlaybackStatsSummary) s));
                } catch (Exception e) {
                    // MONTH needs an Android Context for its labels; covered by hand-written Swift tests.
                }
            }
            out.add(line("summary", in, o));
        }
        write("stats-golden.jsonl", out);
    }

    static JsonArray eventsJson(List<PlaybackStatsRepository.PlaybackEvent> events) {
        JsonArray a = new JsonArray();
        for (PlaybackStatsRepository.PlaybackEvent e : events) {
            JsonArray x = new JsonArray();
            x.add(e.getSongId());
            x.add(e.getTimestamp());
            x.add(e.getDurationMs());
            x.add(e.getStartTimestamp() == null ? JsonNull.INSTANCE : new JsonPrimitive(e.getStartTimestamp()));
            x.add(e.getEndTimestamp() == null ? JsonNull.INSTANCE : new JsonPrimitive(e.getEndTimestamp()));
            a.add(x);
        }
        return a;
    }

    static JsonObject summary(PlaybackStatsRepository.PlaybackStatsSummary s) {
        JsonObject o = new JsonObject();
        o.add("start", s.getStartTimestamp() == null ? JsonNull.INSTANCE : new JsonPrimitive(s.getStartTimestamp()));
        o.addProperty("end", s.getEndTimestamp());
        o.addProperty("totalDurationMs", s.getTotalDurationMs());
        o.addProperty("totalPlayCount", s.getTotalPlayCount());
        o.addProperty("uniqueSongs", s.getUniqueSongs());
        o.addProperty("averageDailyDurationMs", s.getAverageDailyDurationMs());
        JsonArray songs = new JsonArray();
        for (PlaybackStatsRepository.SongPlaybackSummary x : s.getSongs()) {
            JsonArray a = new JsonArray();
            a.add(x.getSongId()); a.add(x.getTitle()); a.add(x.getArtist()); a.add(str(x.getAlbumArtUri()));
            a.add(x.getTotalDurationMs()); a.add(x.getPlayCount());
            songs.add(a);
        }
        o.add("songs", songs);
        o.addProperty("topSongs", s.getTopSongs().size());
        JsonArray genres = new JsonArray();
        for (PlaybackStatsRepository.GenrePlaybackSummary x : s.getTopGenres()) {
            JsonArray a = new JsonArray();
            a.add(x.getGenre()); a.add(x.getTotalDurationMs()); a.add(x.getPlayCount()); a.add(x.getUniqueArtists());
            genres.add(a);
        }
        o.add("topGenres", genres);
        o.add("timeline", timeline(s.getTimeline()));
        JsonArray artists = new JsonArray();
        for (PlaybackStatsRepository.ArtistPlaybackSummary x : s.getTopArtists()) {
            JsonArray a = new JsonArray();
            a.add(x.getArtist()); a.add(x.getTotalDurationMs()); a.add(x.getPlayCount()); a.add(x.getUniqueSongs());
            artists.add(a);
        }
        o.add("topArtists", artists);
        JsonArray albums = new JsonArray();
        for (PlaybackStatsRepository.AlbumPlaybackSummary x : s.getTopAlbums()) {
            JsonArray a = new JsonArray();
            a.add(x.getAlbum()); a.add(str(x.getAlbumArtUri())); a.add(x.getTotalDurationMs()); a.add(x.getPlayCount()); a.add(x.getUniqueSongs());
            albums.add(a);
        }
        o.add("topAlbums", albums);
        o.addProperty("activeDays", s.getActiveDays());
        o.addProperty("longestStreakDays", s.getLongestStreakDays());
        o.addProperty("totalSessions", s.getTotalSessions());
        o.addProperty("averageSessionDurationMs", s.getAverageSessionDurationMs());
        o.addProperty("longestSessionDurationMs", s.getLongestSessionDurationMs());
        o.addProperty("averageSessionsPerDay", bits(s.getAverageSessionsPerDay()));
        PlaybackStatsRepository.DayListeningDistribution d = s.getDayListeningDistribution();
        if (d == null) {
            o.add("distribution", JsonNull.INSTANCE);
        } else {
            JsonObject dj = new JsonObject();
            dj.addProperty("bucketSizeMinutes", d.getBucketSizeMinutes());
            dj.add("buckets", buckets(d.getBuckets()));
            dj.addProperty("max", d.getMaxBucketDurationMs());
            JsonArray days = new JsonArray();
            for (PlaybackStatsRepository.DailyListeningDay day : d.getDays()) {
                JsonObject x = new JsonObject();
                x.addProperty("date", day.getDate().toString());
                x.add("buckets", buckets(day.getBuckets()));
                x.addProperty("total", day.getTotalDurationMs());
                days.add(x);
            }
            dj.add("days", days);
            o.add("distribution", dj);
        }
        PlaybackStatsRepository.TimelineEntry peak = s.getPeakTimeline();
        o.add("peakTimeline", peak == null ? JsonNull.INSTANCE : timeline(List.of(peak)).get(0));
        o.add("peakDayLabel", str(s.getPeakDayLabel()));
        o.addProperty("peakDayDurationMs", s.getPeakDayDurationMs());
        return o;
    }

    static JsonArray timeline(List<PlaybackStatsRepository.TimelineEntry> list) {
        JsonArray a = new JsonArray();
        for (PlaybackStatsRepository.TimelineEntry t : list) {
            JsonArray x = new JsonArray();
            x.add(t.getLabel()); x.add(t.getTotalDurationMs()); x.add(t.getPlayCount());
            a.add(x);
        }
        return a;
    }

    static JsonArray buckets(List<PlaybackStatsRepository.DailyListeningBucket> list) {
        JsonArray a = new JsonArray();
        for (PlaybackStatsRepository.DailyListeningBucket b : list) {
            JsonArray x = new JsonArray();
            x.add(b.getStartMinute()); x.add(b.getEndMinuteExclusive()); x.add(b.getTotalDurationMs());
            a.add(x);
        }
        return a;
    }

    // ---------------------------------------------------------------- G. playback_history.json codec

    static void history() throws Exception {
        List<JsonObject> out = new ArrayList<>();
        PlaybackStatsRepository repo = statsRepository();
        Method parse = PlaybackStatsRepository.class.getDeclaredMethod("parseEvents", String.class);
        parse.setAccessible(true);
        Method serialize = PlaybackStatsRepository.class.getDeclaredMethod("serializeEvents", List.class);
        serialize.setAccessible(true);
        String[] inputs = {
            null, "", "   ", "[]", "{}", "null", "[null]", "42", "\"x\"",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":500,\"startTimestamp\":500,\"endTimestamp\":1000}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":500}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":0}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":5000}]",
            "[{\"songId\":\"a\",\"timestamp\":-5,\"durationMs\":-7}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":100,\"startTimestamp\":2000}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":100,\"startTimestamp\":-20}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":100,\"endTimestamp\":3000}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":100,\"startTimestamp\":null,\"endTimestamp\":null}]",
            "[{\"songId\":\"a\",\"timestamp\":\"1000\",\"durationMs\":\"100\"}]",
            "[{\"songId\":\"a\",\"timestamp\":1000.0,\"durationMs\":1.5e2}]",
            "[{\"songId\":\"a\",\"timestamp\":1000.7,\"durationMs\":2}]",
            "[{\"songId\":\"a\",\"timestamp\":1e3,\"durationMs\":2}]",
            "[{\"songId\":\"a\",\"timestamp\":\"1e3\",\"durationMs\":2}]",
            "[{\"songId\":\"a\",\"timestamp\":\"abc\",\"durationMs\":2}]",
            "[{\"songId\":\"a\",\"timestamp\":true,\"durationMs\":2}]",
            "[{\"songId\":\"a\",\"timestamp\":null,\"durationMs\":2}]",
            "[{\"songId\":\"a\"}]",
            "[{\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":null,\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":123,\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":12.50,\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":true,\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,\"extra\":{\"x\":[1,2]}}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1},{\"songId\":\"b\",\"timestamp\":2000,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1},7]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1},null]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,\"timestamp\":5}]",
            "[{\"songId\":\"a\",\"timestamp\":9223372036854775807,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":9223372036854775808,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":18446744073709551617,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":-9223372036854775808,\"durationMs\":1}]",
            "[{\"songId\":\"<b>&'=\\u2028\\u0001\\\"\\\\\",\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":\"日本\",\"timestamp\":1000,\"durationMs\":1}]",
            "[{'songId':'a','timestamp':1000,'durationMs':1}]",
            "[{songId:a,timestamp:1000,durationMs:1}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1}] trailing",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1}]   ",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1} // c\n]",
            "[{\"songId\":\"a\",\"timestamp\":NaN,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":0x10,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":-0,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1}",
            "[[1,2]]", "[\"a\"]",
            "[{\"songId\":\"\",\"timestamp\":1000,\"durationMs\":1}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,\"startTimestamp\":\"900\"}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,\"startTimestamp\":900.9}]",
            "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1,\"startTimestamp\":{}}]",
        };
        for (String s : inputs) {
            String outJson;
            try {
                @SuppressWarnings("unchecked")
                List<PlaybackStatsRepository.PlaybackEvent> events = (List<PlaybackStatsRepository.PlaybackEvent>) parse.invoke(repo, s);
                outJson = new String((byte[]) serialize.invoke(repo, events), StandardCharsets.UTF_8);
            } catch (Exception e) {
                outJson = "ERROR " + e.getCause();
            }
            out.add(line("parse", str(s), new JsonPrimitive(outJson)));
        }
        Random r = new Random(77);
        for (int k = 0; k < 40; k++) {
            List<PlaybackStatsRepository.PlaybackEvent> events = new ArrayList<>();
            for (int i = r.nextInt(6); i > 0; i--) {
                long ts = r.nextInt(3) == 0 ? -r.nextInt(1000) : 1_700_000_000_000L + r.nextInt(1_000_000);
                Long st = r.nextBoolean() ? null : ts - r.nextInt(400_000) + (r.nextInt(5) == 0 ? 900_000 : 0);
                Long en = r.nextBoolean() ? null : ts + (r.nextInt(3) - 1) * r.nextInt(100_000);
                String id = new String[]{"a", "b\"c", "<&>", "é", "\n\t", "x "}[r.nextInt(6)];
                events.add(new PlaybackStatsRepository.PlaybackEvent(id, ts, r.nextInt(3) == 0 ? -r.nextInt(50) : r.nextInt(600_000), st, en));
            }
            out.add(line("serialize", eventsJson(events), new JsonPrimitive(new String((byte[]) serialize.invoke(repo, events), StandardCharsets.UTF_8))));
        }
        write("history-codec-golden.jsonl", out);
    }

    // ---------------------------------------------------------------- F. search (SQLite FTS4 unicode61)

    static void search(Path root) throws Exception {
        Class.forName("org.sqlite.JDBC");
        try (Connection c = DriverManager.getConnection("jdbc:sqlite::memory:")) {
            unicodeTables(c, root.resolve("Packages/PixlCore/Sources/PixlLibrary/Unicode61Tables.swift"));
            searchGolden(c);
        }
    }

    /** Dumps unicode61 (remove_diacritics=1) token classes and case/diacritic folds for every scalar. */
    static void unicodeTables(Connection c, Path target) throws Exception {
        try (Statement st = c.createStatement()) {
            st.execute("CREATE VIRTUAL TABLE tok USING fts3tokenize(unicode61)");
        }
        int max = 0x10FFFF;
        int[] cls = new int[max + 1];   // 0 separator, 1 token char, 2 continues a token only
        int[] fold = new int[max + 1];  // folded scalar, 0 = dropped
        PreparedStatement ps = c.prepareStatement("SELECT token, start, \"end\" FROM tok WHERE input = ?");
        int batch = 1500;
        for (int base = 0; base <= max; base += batch) {
            StringBuilder sb = new StringBuilder();
            List<Integer> cps = new ArrayList<>();
            List<Integer> starts = new ArrayList<>();
            for (int cp = base; cp < Math.min(max + 1, base + batch); cp++) {
                if (cp >= 0xD800 && cp <= 0xDFFF) continue;
                if (cp == 0) continue;
                starts.add(sb.toString().getBytes(StandardCharsets.UTF_8).length);
                cps.add(cp);
                sb.append('a').appendCodePoint(cp).append("a ");
            }
            // tokens of "a<c>a": one token "a<f>a" (or "aa") means c continues a token; two tokens "a","a" means separator.
            ps.setString(1, sb.toString());
            Map<Integer, List<String>> tokensByGroup = new LinkedHashMap<>();
            Map<Integer, List<int[]>> spansByGroup = new LinkedHashMap<>();
            try (ResultSet rs = ps.executeQuery()) {
                int g = 0;
                while (rs.next()) {
                    int s = rs.getInt(2);
                    while (g + 1 < starts.size() && starts.get(g + 1) <= s) g++;
                    tokensByGroup.computeIfAbsent(g, x -> new ArrayList<>()).add(rs.getString(1));
                    spansByGroup.computeIfAbsent(g, x -> new ArrayList<>()).add(new int[]{s, rs.getInt(3)});
                }
            }
            for (int i = 0; i < cps.size(); i++) {
                int cp = cps.get(i);
                List<String> toks = tokensByGroup.getOrDefault(i, List.of());
                if (toks.size() == 1) {
                    String t = toks.get(0);
                    int[] inner = t.codePoints().toArray();
                    if (inner.length == 2) { cls[cp] = 2; fold[cp] = 0; }
                    else if (inner.length == 3) { cls[cp] = 2; fold[cp] = inner[1]; }
                    else throw new IllegalStateException("U+" + Integer.toHexString(cp) + " -> " + t);
                } else if (toks.size() == 2) {
                    cls[cp] = 0; fold[cp] = 0;
                } else {
                    throw new IllegalStateException("U+" + Integer.toHexString(cp) + " tokens " + toks);
                }
            }
        }
        // Which continuing characters may also start a token: tokenize "<c>a".
        for (int base = 0; base <= max; base += batch) {
            StringBuilder sb = new StringBuilder();
            List<Integer> cps = new ArrayList<>();
            List<Integer> starts = new ArrayList<>();
            for (int cp = base; cp < Math.min(max + 1, base + batch); cp++) {
                if (cls[cp] != 2) continue;
                starts.add(sb.toString().getBytes(StandardCharsets.UTF_8).length);
                cps.add(cp);
                sb.appendCodePoint(cp).append("a ");
            }
            if (cps.isEmpty()) continue;
            ps.setString(1, sb.toString());
            Set<Integer> startsToken = new java.util.HashSet<>();
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    int s = rs.getInt(2);
                    int g = java.util.Collections.binarySearch(starts, s);
                    if (g >= 0) startsToken.add(g);
                }
            }
            for (int i = 0; i < cps.size(); i++) if (startsToken.contains(i)) cls[cps.get(i)] = 1;
        }
        // Run-length encode: class runs, and fold runs (start, length, delta) where fold == cp + delta (fold != 0),
        // plus dropped runs (fold == 0 for continuing characters).
        StringBuilder sw = new StringBuilder();
        sw.append("// GENERATED by tools/android-reference/LibGen.java from SQLite's unicode61 tokenizer (SQLite is public domain).\n");
        sw.append("// Do not edit by hand. Token classes and folds (remove_diacritics=1) for every Unicode scalar.\n\n");
        sw.append("enum Unicode61Tables {\n");
        sw.append("    /// Runs of token classes as (first scalar, class): 0 separator, 1 token character, 2 continues a token only.\n");
        sw.append("    static let classRuns: [(UInt32, UInt8)] = [\n");
        int prev = -1;
        StringBuilder row = new StringBuilder();
        int count = 0;
        for (int cp = 0; cp <= max; cp++) {
            int k = (cp >= 0xD800 && cp <= 0xDFFF) ? 0 : cls[cp];
            if (cp == 0) k = 0;
            if (k != prev) {
                row.append("(0x").append(Integer.toHexString(cp).toUpperCase()).append(", ").append(k).append("), ");
                prev = k;
                if (++count % 8 == 0) { sw.append("        ").append(row.toString().stripTrailing()).append('\n'); row.setLength(0); }
            }
        }
        if (row.length() > 0) sw.append("        ").append(row.toString().stripTrailing()).append('\n');
        sw.append("    ]\n\n");
        sw.append("    /// Fold runs as (first scalar, count, delta): scalars in the run fold to scalar + delta; delta == Int32.min\n");
        sw.append("    /// means the scalar is dropped from the token. Scalars outside every run fold to themselves.\n");
        sw.append("    static let foldRuns: [(UInt32, UInt32, Int32)] = [\n");
        row.setLength(0);
        count = 0;
        int cp = 0;
        while (cp <= max) {
            int k = (cp >= 0xD800 && cp <= 0xDFFF) || cp == 0 ? 0 : cls[cp];
            boolean changes = k != 0 && fold[cp] != cp;
            if (!changes) { cp++; continue; }
            long delta = fold[cp] == 0 ? Integer.MIN_VALUE : (long) fold[cp] - cp;
            int start = cp;
            int len = 0;
            while (cp <= max) {
                int k2 = (cp >= 0xD800 && cp <= 0xDFFF) || cp == 0 ? 0 : cls[cp];
                if (k2 == 0 || fold[cp] == cp) break;
                long d2 = fold[cp] == 0 ? Integer.MIN_VALUE : (long) fold[cp] - cp;
                if (d2 != delta) break;
                len++;
                cp++;
            }
            row.append("(0x").append(Integer.toHexString(start).toUpperCase()).append(", ").append(len).append(", ")
                .append(delta == Integer.MIN_VALUE ? "Int32.min" : Long.toString(delta)).append("), ");
            if (++count % 6 == 0) { sw.append("        ").append(row.toString().stripTrailing()).append('\n'); row.setLength(0); }
        }
        if (row.length() > 0) sw.append("        ").append(row.toString().stripTrailing()).append('\n');
        sw.append("    ]\n}\n");
        Files.writeString(target, sw.toString(), StandardCharsets.UTF_8);
        System.err.println("Unicode61Tables.swift written");
    }

    static void searchGolden(Connection c) throws Exception {
        List<JsonObject> out = new ArrayList<>();
        try (Statement st = c.createStatement()) {
            st.execute("CREATE TABLE songs(id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist_name TEXT NOT NULL, genre TEXT, album_id INTEGER NOT NULL, artist_id INTEGER NOT NULL)");
            st.execute("CREATE VIRTUAL TABLE songs_fts USING fts4(title, artist_name, genre, tokenize=unicode61)");
            st.execute("CREATE TABLE albums(id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist_name TEXT NOT NULL)");
            st.execute("CREATE TABLE artists(id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
            st.execute("CREATE TABLE song_artist_cross_ref(song_id INTEGER NOT NULL, artist_id INTEGER NOT NULL)");
            ResultSet rs = st.executeQuery("PRAGMA compile_options");
            JsonArray opts = new JsonArray();
            while (rs.next()) opts.add(rs.getString(1));
            System.err.println("sqlite compile options: " + opts);
        }
        String[][] songs = {
            {"Café del Mar", "Energy 52", "Chillout"}, {"Cafe Racer", "Ünïcode Band", null}, {"CAFÉ", "Beyoncé", "Pop"},
            {"Halo", "Beyoncé", "R&B"}, {"Crazy in Love", "Beyoncé feat. JAY-Z", "Pop"}, {"Über Alles", "Die Band", "Rock"},
            {"uber eats", "x", ""}, {"東京事変", "椎名林檎", "J-Pop"}, {"女の子", "東京事変", "J-Pop"},
            {"50% Off", "Discount", "Electronic"}, {"a_b_c", "Under Score", null}, {"Rock & Roll", "Led Zeppelin", "Rock"},
            {"Straße", "Rammstein", "Metal"}, {"Strasse", "Rammstein", "Metal"}, {"İstanbul", "Sezen Aksu", "Pop"},
            {"istanbul", "They Might Be Giants", "Rock"}, {"ΆΣΜΑ", "Ελληνικά", "Λαϊκά"}, {"Tiếng Việt", "Sơn Tùng", "V-Pop"},
            {"Ǆungla", "Ǳ", null}, {"Café NFD", "Énfd", null}, {"Ø Lake", "Øystein", "Folk"}, {"Æther", "Ærø", null},
            {"Ångström", "Åsa", "Jazz"}, {"Йога", "Йорш", "Rock"}, {"ﬁre", "Ligature", null}, {"Ⅻ", "Roman", null},
            {"😀 Emoji Song", "Smile", "Pop"}, {"Hello-World", "Dash", null}, {"hello world", "Space", null},
            {"Zeta", "Alpha", "Ambient"}, {"zeta", "alpha", "ambient"}, {"Alpha", "Zeta", null}, {"alpha", "zeta", null},
            {"Mañana", "Niño", "Latin"}, {"Ça va", "Ça", "French"}, {"Ğ", "ğ", null}, {"x²", "Math", null},
            {"Nº 5", "Chanel", null}, {"İİ", "ıı", null}, {"ǅ", "ǆ", null}, {"Ⓐ circle", "Ⓑ", null}, {"ｆｕｌｌ", "ＷＩＤＴＨ", null},
            {"pixelplayemptyquery", "Trap", null}, {"The Song", "The Band", "Pop"}, {"Song", "Band", "Pop"},
            {"Love & Hate", "Lovers", "Pop"}, {"lovely", "Love", "Soul"}, {"Ģirts", "Ķīlis", null},
        };
        Map<Integer, String[]> albums = new LinkedHashMap<>();
        try (PreparedStatement ins = c.prepareStatement("INSERT INTO songs(id,title,artist_name,genre,album_id,artist_id) VALUES(?,?,?,?,?,?)");
             PreparedStatement fts = c.prepareStatement("INSERT INTO songs_fts(rowid,title,artist_name,genre) VALUES(?,?,?,?)");
             PreparedStatement art = c.prepareStatement("INSERT OR IGNORE INTO artists(id,name) VALUES(?,?)");
             PreparedStatement xref = c.prepareStatement("INSERT INTO song_artist_cross_ref(song_id,artist_id) VALUES(?,?)")) {
            for (int i = 0; i < songs.length; i++) {
                int id = i + 1;
                int albumId = 1 + i % 9;
                int artistId = 100 + Math.abs(songs[i][1].hashCode() % 1000);
                ins.setInt(1, id); ins.setString(2, songs[i][0]); ins.setString(3, songs[i][1]);
                ins.setString(4, songs[i][2]); ins.setInt(5, albumId); ins.setInt(6, artistId);
                ins.executeUpdate();
                fts.setInt(1, id); fts.setString(2, songs[i][0]); fts.setString(3, songs[i][1]);
                fts.setString(4, songs[i][2] == null ? "" : songs[i][2]);
                fts.executeUpdate();
                art.setInt(1, artistId); art.setString(2, songs[i][1]); art.executeUpdate();
                xref.setInt(1, id); xref.setInt(2, artistId); xref.executeUpdate();
            }
        }
        String[][] albumRows = {{"1", "Café Album", "Beyoncé"}, {"2", "Rock Hits", "Various"}, {"3", "東京", "椎名林檎"},
            {"4", "50% Sale", "Discount"}, {"5", "a_b", "x"}, {"6", "Über", "Die Band"}, {"7", "Love Songs", "Lovers"},
            {"8", "ÆON", "Ærø"}, {"9", "Single", "Solo"}, {"10", "Orphan Album", "Nobody"}};
        try (PreparedStatement ins = c.prepareStatement("INSERT INTO albums(id,title,artist_name) VALUES(?,?,?)")) {
            for (String[] a : albumRows) { ins.setInt(1, Integer.parseInt(a[0])); ins.setString(2, a[1]); ins.setString(3, a[2]); ins.executeUpdate(); }
        }
        JsonObject lib = new JsonObject();
        JsonArray sj = new JsonArray();
        try (Statement st = c.createStatement(); ResultSet rs = st.executeQuery("SELECT id,title,artist_name,genre,album_id,artist_id FROM songs ORDER BY id")) {
            while (rs.next()) {
                JsonArray x = new JsonArray();
                x.add(rs.getInt(1)); x.add(rs.getString(2)); x.add(rs.getString(3)); x.add(str(rs.getString(4)));
                x.add(rs.getInt(5)); x.add(rs.getInt(6));
                sj.add(x);
            }
        }
        lib.add("songs", sj);
        JsonArray aj = new JsonArray();
        for (String[] a : albumRows) { JsonArray x = new JsonArray(); x.add(Integer.parseInt(a[0])); x.add(a[1]); x.add(a[2]); aj.add(x); }
        lib.add("albums", aj);
        JsonArray arj = new JsonArray();
        try (Statement st = c.createStatement(); ResultSet rs = st.executeQuery("SELECT id,name FROM artists ORDER BY id")) {
            while (rs.next()) { JsonArray x = new JsonArray(); x.add(rs.getInt(1)); x.add(rs.getString(2)); arj.add(x); }
        }
        lib.add("artists", arj);
        out.add(line("library", lib, JsonNull.INSTANCE));

        Method full = Class.forName("com.theveloper.pixelplay.data.database.MusicDaoKt").getDeclaredMethod("buildSongSearchMatchQuery", String.class);
        full.setAccessible(true);
        Method title = Class.forName("com.theveloper.pixelplay.data.database.MusicDaoKt").getDeclaredMethod("buildSongTitleSearchMatchQuery", String.class);
        title.setAccessible(true);
        String[] queries = {"cafe", "Café", "CAF", "café", "café", "beyo", "beyonce", "jay z", "jay-z", "über",
            "uber", "UBER", "東京", "京", "東京事変", "%", "_", "a_b", "50%", "50", "rock & roll", "rock roll", "", "  ",
            "ß", "ss", "straße", "strasse", "İstanbul", "istanbul", "ISTANBUL", "ασμα", "άσμα", "ΑΣΜΑ", "tieng", "tiếng",
            "viet", "dz", "ǆ", "o lake", "ø", "aether", "æ", "angstrom", "ångström", "йога", "иога", "fire", "ﬁ",
            "ⅻ", "xii", "😀", "emoji", "hello world", "hello-world", "hello", "zeta", "alpha", "a", "z", "mañana",
            "manana", "nino", "ca va", "ça", "g", "ğ", "x2", "x²", "no 5", "nº", "ⓐ", "full", "ｆｕｌｌ", "width",
            "pixelplayemptyquery", "the", "song band", "pop", "jpop", "j-pop", "love", "lov", "a b c d e f g", "rock pop metal jazz soul folk latin",
            "'", "\"", "*", "OR", "NOT", "AND", "x OR y", "-rock", "rock*", "girts", "ģirts", "kilis", "e e", "1", "s"};
        for (String q : queries) {
            for (boolean titleOnly : new boolean[]{false, true}) {
                String match = (String) (titleOnly ? title : full).invoke(null, q);
                List<Integer> ftsIds = new ArrayList<>();
                String ftsError = null;
                try (PreparedStatement ps = c.prepareStatement(
                    "SELECT songs.id FROM songs INNER JOIN songs_fts ON songs_fts.rowid = songs.id WHERE songs_fts MATCH ? ORDER BY songs.title ASC LIMIT ?")) {
                    ps.setString(1, match);
                    ps.setInt(2, 100);
                    try (ResultSet rs = ps.executeQuery()) { while (rs.next()) ftsIds.add(rs.getInt(1)); }
                } catch (Exception e) {
                    ftsError = e.getMessage();
                }
                String likeSql = titleOnly
                    ? "SELECT id FROM songs WHERE title LIKE '%' || ? || '%' ORDER BY title ASC LIMIT ?"
                    : "SELECT id FROM songs WHERE (title LIKE '%' || ?1 || '%' OR artist_name LIKE '%' || ?1 || '%' OR genre LIKE '%' || ?1 || '%') ORDER BY title ASC LIMIT ?2";
                List<Integer> likeIds = new ArrayList<>();
                String trimmed = kotlin.text.StringsKt.trim((CharSequence) q).toString();
                try (PreparedStatement ps = c.prepareStatement(likeSql)) {
                    ps.setString(1, trimmed);
                    ps.setInt(2, 100);
                    try (ResultSet rs = ps.executeQuery()) { while (rs.next()) likeIds.add(rs.getInt(1)); }
                }
                LinkedHashSet<Integer> merged = new LinkedHashSet<>(ftsIds);
                merged.addAll(likeIds);
                JsonObject in = new JsonObject();
                in.addProperty("q", q);
                in.addProperty("titleOnly", titleOnly);
                JsonObject o = new JsonObject();
                o.addProperty("match", match);
                JsonArray f = new JsonArray(); ftsIds.forEach(f::add);
                o.add("fts", f);
                o.add("ftsError", str(ftsError));
                JsonArray l = new JsonArray(); likeIds.forEach(l::add);
                o.add("like", l);
                JsonArray m = new JsonArray(); merged.forEach(m::add);
                o.add("merged", m);
                out.add(line("songs", in, o));
            }
            String trimmed = kotlin.text.StringsKt.trim((CharSequence) q).toString();
            for (int minTracks : new int[]{1, 2, 6}) {
                List<Integer> ids = new ArrayList<>();
                try (PreparedStatement ps = c.prepareStatement(
                    "SELECT albums.id FROM albums INNER JOIN songs ON songs.album_id = albums.id WHERE (albums.title LIKE '%' || ?1 || '%' OR albums.artist_name LIKE '%' || ?1 || '%') GROUP BY albums.id HAVING COUNT(songs.id) >= ?2 ORDER BY albums.title ASC LIMIT ?3")) {
                    ps.setString(1, trimmed.isBlank() ? q : q);
                    ps.setInt(2, minTracks);
                    ps.setInt(3, 100);
                    try (ResultSet rs = ps.executeQuery()) { while (rs.next()) ids.add(rs.getInt(1)); }
                }
                JsonObject in = new JsonObject();
                in.addProperty("q", q);
                in.addProperty("minTracks", minTracks);
                JsonArray a = new JsonArray(); ids.forEach(a::add);
                out.add(line("albums", in, a));
            }
            List<Integer> artistIds = new ArrayList<>();
            try (PreparedStatement ps = c.prepareStatement(
                "SELECT artists.id FROM artists INNER JOIN song_artist_cross_ref ON song_artist_cross_ref.artist_id = artists.id INNER JOIN songs ON songs.id = song_artist_cross_ref.song_id WHERE artists.name LIKE '%' || ? || '%' GROUP BY artists.id ORDER BY artists.name ASC LIMIT ?")) {
                ps.setString(1, q);
                ps.setInt(2, 100);
                try (ResultSet rs = ps.executeQuery()) { while (rs.next()) artistIds.add(rs.getInt(1)); }
            }
            JsonArray a = new JsonArray(); artistIds.forEach(a::add);
            out.add(line("artists", new JsonPrimitive(q), a));
            String[] names = {"Chill Café", "ROCK", "rock", "Straße", "İstanbul", "ǅ", "Σ", "Ünï", "日本"};
            JsonArray pl = new JsonArray();
            for (String n : names) pl.add(kotlin.text.StringsKt.contains(n, q, true));
            JsonObject in = new JsonObject();
            in.addProperty("q", q);
            in.add("names", arr(Arrays.asList(names)));
            out.add(line("playlists", in, pl));
        }
        write("search-golden.jsonl", out);
    }
}
