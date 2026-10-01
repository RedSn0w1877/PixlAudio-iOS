import com.theveloper.pixelplay.data.lyrics.sync.LyricsExport;
import com.theveloper.pixelplay.data.lyrics.sync.LyricsSyncDraftStore;
import com.theveloper.pixelplay.data.lyrics.sync.LyricsTapSync;
import com.theveloper.pixelplay.data.lyrics.sync.SyncDraft;
import com.theveloper.pixelplay.data.lyrics.sync.SyncResult;
import com.theveloper.pixelplay.data.lyrics.sync.SyncStep;
import com.theveloper.pixelplay.data.model.Lyrics;
import com.theveloper.pixelplay.data.model.LyricsDoc;
import com.theveloper.pixelplay.data.model.LyricsDocCodec;
import com.theveloper.pixelplay.data.model.LyricsMetadata;
import com.theveloper.pixelplay.data.model.SyncedLine;
import com.theveloper.pixelplay.data.model.SyncedWord;
import com.theveloper.pixelplay.data.model.TimedLine;
import com.theveloper.pixelplay.data.model.TimedSyllable;
import com.theveloper.pixelplay.data.model.Voice;
import kotlin.random.Random;
import kotlin.random.RandomKt;
import kotlinx.serialization.json.JsonArray;
import kotlinx.serialization.json.JsonElement;
import kotlinx.serialization.json.JsonElementKt;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.TreeSet;

/**
 * Golden vectors for the PixlLyrics tap-sync port (stage 2d), produced by running the Android app's compiled
 * LyricsTapSync / LyricsExport / LyricsSyncDraftStore codec on the JVM. Writes
 * Packages/PixlCore/Tests/PixlLyricsTests/Fixtures/tapsync-android-golden.txt (see TapSyncGoldenTests.swift).
 *
 *   javac -cp "$CP" TapSyncGen.java && java -cp "$CP;." TapSyncGen > tapsync-android-golden.txt
 *   java -cp "$CP;." TapSyncGen debug <seed>     # every step of one property-test seed, for diffing a mismatch
 *
 * Classpath: the app's compileDebugKotlin/classes, kotlin-stdlib, kotlinx-serialization-core-jvm and -json-jvm
 * (1.11.0), kotlinx-collections-immutable-jvm (0.5.0) and timber's classes.jar (only referenced, never planted).
 *
 * Line kinds:
 *   R <seed> <values…>               kotlin.random.Random(seed) outputs (the sequence is fixed in TapSyncGoldenTests)
 *   T <json input> <json tokens>     LyricsTapSync.tokenize
 *   S <seed> <steps> <fnv64 hex>     the 500-seed random-session property test, every step hashed (see stepRecord)
 *   D <json draft>                   LyricsSyncDraftStore.encode of the store test's draft, savedAtMs 1234567890123
 *   DIN <json input> / DOUT <json re-encoded draft | null>   LyricsSyncDraftStore.decode
 *   H <json id> <sha1 hex>           LyricsSyncDraftStore.sha1
 *   L <name> <json lrc> / X <name> <json ttml>                 LyricsExport of the export test documents
 */
public class TapSyncGen {
    static final LyricsTapSync S = LyricsTapSync.INSTANCE;
    static final LyricsSyncDraftStore.Companion STORE = LyricsSyncDraftStore.Companion;
    static Method buildResult;
    static Class<?> failure;

    static String q(String s) { return JsonElementKt.JsonPrimitive(s).toString(); }

    static String qList(List<String> items) {
        List<JsonElement> out = new ArrayList<>();
        for (String s : items) out.add(JsonElementKt.JsonPrimitive(s));
        return new JsonArray(out).toString();
    }

    static long fnv(long h, String s) {
        for (byte b : s.getBytes(StandardCharsets.UTF_8)) {
            h ^= (b & 0xff);
            h *= 0x100000001b3L;
        }
        return h;
    }

    static final long FNV_OFFSET = 0xcbf29ce484222325L;

    /** buildResult(draft, offset) → the SyncResult, or null on failure. */
    static SyncResult result(SyncDraft d, int offset) throws Exception {
        Object r = buildResult.invoke(S, d, offset);
        return failure.isInstance(r) ? null : (SyncResult) r;
    }

    static String resultRecord(SyncDraft d, int offset) throws Exception {
        SyncResult r = result(d, offset);
        if (r == null) return "F";
        StringBuilder sb = new StringBuilder(LyricsDocCodec.INSTANCE.encode(r.getDoc()));
        sb.append('\u0001');
        boolean first = true;
        for (Integer i : new TreeSet<>(r.getRoughLineIndices())) {
            if (!first) sb.append(',');
            sb.append(i);
            first = false;
        }
        return sb.toString();
    }

    static String stepInfo(SyncStep s) {
        if (s == null) return "-";
        return (s.getSeekToMs() == null ? "n" : s.getSeekToMs().toString()) + "," + s.getClearedCount() + ","
            + (s.getPastNextLine() ? 1 : 0) + "," + (s.getTapBeforeAnchor() ? 1 : 0);
    }

    /** What one step contributes to the seed's hash: draft JSON, reducer outcome, consistency, finished document. */
    static String stepRecord(SyncDraft d, SyncStep step, int offset) throws Exception {
        return STORE.encode$app(d, 0L) + '\u0001' + stepInfo(step) + '\u0001' + (S.isConsistent(d) ? "C1" : "C0")
            + '\u0001' + resultRecord(d, offset) + '\n';
    }

    static <T> T pick(List<T> list, Random random) { return list.get(random.nextInt(list.size())); }

    static final List<String> WORD_POOL = Arrays.asList(
        "love", "you", "twenty-one", "rock'n'roll", "(oh", "yeah,", "—", "&", "…", "君が", "好き", "ラーメン",
        "きょう", "「愛」", "사랑해", "👨‍👩‍👧", "❤️", "OK。", "a",
        "night-time", "don't", "x".repeat(45));

    static String randomText(Random random) {
        int n = random.nextInt(1, 9);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append(' ');
            sb.append(pick(WORD_POOL, random));
        }
        return sb.toString();
    }

    static SyncDraft randomDraft(Random random) {
        long duration = pick(Arrays.asList(0L, 500L, 20_000L, 60_000L, 240_000L), random);
        int textCount = random.nextInt(1, 12);
        List<String> texts = new ArrayList<>();
        for (int i = 0; i < textCount; i++) texts.add(randomText(random));
        List<String> roles = Arrays.asList("lead", "background", "duet");
        long time = random.nextLong(0L, 8_000L);
        Lyrics lyrics;
        String paste;
        switch (random.nextInt(4)) {
            case 0: {
                lyrics = null;
                paste = String.join("\n", texts);
                break;
            }
            case 1: {
                paste = null;
                List<SyncedLine> synced = new ArrayList<>();
                for (String text : texts) {
                    time += random.nextLong(500L, 9_000L);
                    String translation = random.nextBoolean() ? "tr" : null;
                    String role = pick(roles, random);
                    synced.add(new SyncedLine((int) time, text, null, translation, null, null, role));
                }
                lyrics = new Lyrics(null, synced, false, null);
                break;
            }
            case 2: {
                paste = null;
                List<SyncedLine> synced = new ArrayList<>();
                for (String text : texts) {
                    time += random.nextLong(500L, 6_000L);
                    long lineStart = time;
                    List<String> tokens = S.tokenize(text);
                    List<SyncedWord> words;
                    if (random.nextInt(5) == 0) {
                        words = null;
                    } else {
                        words = new ArrayList<>();
                        for (int k = 0; k < tokens.size(); k++) {
                            String token = tokens.get(k);
                            time += random.nextLong(0L, 700L);
                            boolean startsNew = k == 0 || tokens.get(k - 1).endsWith(" ");
                            Integer end = random.nextBoolean() ? (int) (time + random.nextLong(-100L, 900L)) : null;
                            words.add(new SyncedWord((int) time, kotlin.text.StringsKt.trim(token).toString(), startsNew, end));
                        }
                    }
                    String role = pick(roles, random);
                    synced.add(new SyncedLine((int) lineStart, text, words, null, null, null, role));
                }
                lyrics = new Lyrics(null, synced, false, null);
                break;
            }
            default: {
                paste = null;
                List<Voice> voices = Arrays.asList(new Voice("lead", "lead", null), new Voice("bg", "background", null),
                    new Voice("v2", "duet", null));
                List<TimedLine> lines = new ArrayList<>();
                for (String text : texts) {
                    time += random.nextLong(300L, 6_000L);
                    long lineStart = time;
                    List<String> tokens = S.tokenize(text);
                    List<TimedSyllable> syllables = new ArrayList<>();
                    if (random.nextInt(4) != 0) {
                        for (String token : tokens) {
                            long s = time;
                            long length = random.nextLong(1L, 800L);
                            time += random.nextLong(0L, 700L);
                            syllables.add(new TimedSyllable(s, length, token));
                        }
                    }
                    long maxEnd = Long.MIN_VALUE;
                    for (TimedSyllable s : syllables) maxEnd = Math.max(maxEnd, s.getStartMs() + s.getDurationMs());
                    long end = Math.max(lineStart + 1, syllables.isEmpty() ? lineStart + 2_000L : maxEnd);
                    String voiceId = pick(voices, random).getId();
                    lines.add(new TimedLine(lineStart, end, String.join("", tokens), voiceId, syllables));
                }
                String source = random.nextBoolean() ? "user" : null;
                lyrics = new Lyrics(null, null, false,
                    new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("", "", "", null, source), voices, lines));
                break;
            }
        }
        return S.buildDraft("seed", "T", "A", "Al", duration, lyrics, paste).getDraft();
    }

    static SyncDraft tapAll(SyncDraft draft, long startMs, long stepMs, float speed, int offsetMs) {
        SyncDraft d = draft;
        long t = startMs;
        while (!d.isFinished()) {
            d = S.tap(d, t, speed, offsetMs, null).getDraft();
            t += stepMs;
        }
        return d;
    }

    /** Hash of one property-test seed (LyricsTapSyncTest.toLyricsDoc_isAlwaysValidForRandomSessions). */
    static String runSeed(int seed, boolean debug) throws Exception {
        Random random = RandomKt.Random(seed);
        int offset = random.nextInt(0, 401);
        SyncDraft draft = randomDraft(random);
        long position = random.nextLong(0L, 5_000L);
        int actions = random.nextInt(1, 120);
        long h = FNV_OFFSET;
        String record = stepRecord(draft, null, offset);
        if (debug) System.out.print("init " + record);
        h = fnv(h, record);
        List<Float> speeds = Arrays.asList(0.5f, 0.75f, 1f);
        for (int step = 0; step < actions; step++) {
            position = Math.max(0L, position + random.nextLong(-400L, 2_000L));
            float speed = pick(speeds, random);
            Integer scope = random.nextInt(8) == 0 ? draft.getCurrentLineIndex() : null;
            int action = random.nextInt(100);
            SyncStep s = null;
            if (action <= 59) {
                s = S.tap(draft, position, speed, offset, scope);
                draft = s.getDraft();
            } else if (action <= 64) {
                Integer last = null;
                for (int i = draft.getCursor() - 1; i >= 0; i--) {
                    if (i < draft.getTokens().size() && draft.getTokens().get(i).getRawStartMs() != null) { last = i; break; }
                }
                if (last != null) draft = S.release(draft, last, position + random.nextLong(0L, 3_000L), speed, offset);
            } else if (action <= 71) {
                s = S.undo(draft, speed, offset, scope);
                draft = s.getDraft();
            } else if (action <= 76) {
                s = S.rewind(draft, position, offset, 5_000L, scope);
                draft = s.getDraft();
            } else if (action <= 80) {
                s = S.jumpToLine(draft, random.nextInt(draft.getLines().size()), speed, offset);
                draft = s.getDraft();
            } else if (action <= 83) {
                s = S.fixLine(draft, random.nextInt(draft.getLines().size()), speed, offset);
                draft = s.getDraft();
            } else if (action <= 87) {
                s = S.skipLine(draft, offset);
                draft = s.getDraft();
            } else if (action <= 89) {
                s = S.fillRest(draft, offset);
                draft = s.getDraft();
            } else if (action <= 96) {
                draft = S.setNudge(draft, random.nextInt(-500, 501));
            } else {
                if (random.nextInt(4) == 0) draft = S.clearAll(draft);
            }
            record = stepRecord(draft, s, offset);
            if (debug) System.out.print(step + " a" + action + " " + record);
            h = fnv(h, record);
        }
        long stepMs = random.nextLong(1L, 900L);
        SyncDraft done = tapAll(draft, position, stepMs, 1f, offset);
        record = stepRecord(done, null, offset);
        SyncResult r = result(done, offset);
        if (r != null) {
            record += LyricsExport.INSTANCE.toEnhancedLrc(r.getDoc()) + '\u0001' + LyricsExport.INSTANCE.toTtml(r.getDoc());
        }
        if (debug) System.out.print("final " + record + "\n");
        h = fnv(h, record);
        return actions + " " + String.format("%016x", h);
    }

    static SyncDraft storeDraft(String songId) {
        SyncDraft d = S.buildDraft(songId, "Title", "Artist", "Album", 200_000L, null, "Hello world\n君が好き").getDraft();
        d = S.tap(d, 1_000L, 0.75f, 100, null).getDraft();
        d = S.tap(d, 1_400L, 1f, 100, null).getDraft();
        d = S.release(d, 1, 2_600L, 1f, 100);
        return S.setNudge(d, -20);
    }

    static List<String> decodeCases(String base) {
        List<String> c = new ArrayList<>();
        c.add(base);
        c.add(base.replace("\"format\":", "\"extra\":{\"a\":[1,2,{\"b\":null}]},\"format\":"));
        c.add(base.replace("\"cursor\":2", "\"cursor\":\"2\""));
        c.add(base.replace("\"durationMs\":200000", "\"durationMs\":\"200000\""));
        c.add(base.replace("\"durationMs\":200000", "\"durationMs\":2e5"));
        c.add(base.replace("\"durationMs\":200000", "\"durationMs\":-5"));
        c.add(base.replace("\"nudgeMs\":-20", "\"nudgeMs\":999"));
        c.add(base.replace("\"nudgeMs\":-20", "\"nudgeMs\":-999"));
        c.add(base.replaceFirst("\"exact\":false", "\"exact\":\"true\""));
        c.add(base.replaceFirst("\"exact\":false", "\"exact\":TRUE"));
        c.add(base.replaceFirst("\"exact\":false", "\"exact\":\"False\""));
        c.add(base.replaceFirst("\"exact\":false", "\"exact\":null"));
        c.add(base.replaceFirst("\"exact\":false", "\"exact\":1"));
        c.add(base.replaceFirst("\"locked\":false", "\"locked\":\"yes\""));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":\" 0.75 \""));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":\"0.5f\""));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":7.5e-1"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":1"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":0.1"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":1.0E-4"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":12345678"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":0"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":-1"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":\"NaN\""));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":\"Infinity\""));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":1e39"));
        c.add(base.replaceFirst("\"startSpeed\":0.75", "\"startSpeed\":null"));
        c.add(base.replaceFirst("\"rawStartMs\":900", "\"rawStartMs\":\"900\""));
        c.add(base.replaceFirst("\"anchorMs\":null", "\"anchorMs\":\"null\""));
        c.add(base.replaceFirst("\"anchorMs\":null", "\"anchorMs\":-3"));
        c.add(base.replaceFirst("\"translation\":null", "\"translation\":\"hola\""));
        c.add(base.replaceFirst("\"translation\":null", "\"translation\":5"));
        c.add(base.replace("\"voices\":[{\"id\":\"lead\",\"role\":\"lead\",\"name\":null}],", ""));
        c.add(base.replace("\"voices\":[{\"id\":\"lead\",\"role\":\"lead\",\"name\":null}]", "\"voices\":[]"));
        c.add(base.replace("\"voices\":[{\"id\":\"lead\",\"role\":\"lead\",\"name\":null}]", "\"voices\":null"));
        c.add(base.replace("\"voices\":[{\"id\":\"lead\",\"role\":\"lead\",\"name\":null}]", "\"voices\":[{}]"));
        c.add(base.replace("\"voices\":[{\"id\":\"lead\",\"role\":\"lead\",\"name\":null}]", "\"voices\":[{\"id\":\"x\",\"role\":\"choir\",\"name\":\"N\",\"z\":1}]"));
        c.add(base.replace("\"format\":\"pixelplay-lyrics-sync-draft\"", "\"format\":\"other\""));
        c.add(base.replace("\"formatVersion\":1", "\"formatVersion\":2"));
        c.add(base.replace("\"formatVersion\":1,", ""));
        c.add(base.replace("\"songId\":\"content://media/42\",", ""));
        c.add(base.replace("\"title\":\"Title\",", "\"title\":null,"));
        c.add(base.replace("\"title\":\"Title\",", ""));
        c.add(base.replace("\"savedAtMs\":1234567890123", "\"savedAtMs\":\"x\""));
        c.add(base.replace(",\"savedAtMs\":1234567890123", ""));
        c.add(base.replace("\"Hello world\"", "\"Goodbye world\""));
        c.add(base.replace("\"cursor\":2", "\"cursor\":99"));
        c.add(base.replace("\"cursor\":2", "\"cursor\":-1"));
        c.add(base.replace("\"cursor\":2", "\"cursor\":2.0"));
        c.add(base.replace("\"cursor\":2", "\"cursor\":2,\"cursor\":3"));
        c.add(base.replaceFirst("\"firstToken\":0", "\"firstToken\":1"));
        c.add(base.replaceFirst("\"tokenCount\":2", "\"tokenCount\":0"));
        c.add(base.replaceFirst("\"line\":0", "\"line\":1"));
        c.add(base.replaceFirst("\"text\":\"Hello \"", "\"text\":\"\""));
        c.add(base + " ");
        c.add(base + "x");
        c.add("[" + base + "]");
        c.add("{}");
        c.add("not json");
        c.add(base.replace("\"lines\":[", "\"lines\":[],\"zz\":["));
        return c;
    }

    static LyricsDoc exportDoc() {
        return new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("Song", "Artist", "Album", 200_000L, "user"),
            Arrays.asList(new Voice("lead", "lead", null)),
            Arrays.asList(
                new TimedLine(1_234L, 3_000L, "Hello there, world", "lead", Arrays.asList(
                    new TimedSyllable(1_234L, 400L, "Hello "), new TimedSyllable(1_634L, 500L, "there, "),
                    new TimedSyllable(2_134L, 866L, "world"))),
                new TimedLine(4_005L, 6_000L, "beautiful day", "lead", Arrays.asList(
                    new TimedSyllable(4_005L, 300L, "beau"), new TimedSyllable(4_305L, 300L, "ti"),
                    new TimedSyllable(4_605L, 400L, "ful "), new TimedSyllable(5_005L, 995L, "day")))));
    }

    static LyricsDoc duetDoc() {
        return new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("A & B", "", "", 200_000L, "user"),
            Arrays.asList(new Voice("lead", "lead", null), new Voice("v2", "duet", null), new Voice("bg", "background", null)),
            Arrays.asList(
                new TimedLine(1_000L, 2_500L, "R&B <3 'yes\"", "lead", Arrays.asList(
                    new TimedSyllable(1_000L, 400L, "R&B "), new TimedSyllable(1_500L, 400L, "<3 "),
                    new TimedSyllable(2_000L, 400L, "'yes\""))),
                new TimedLine(1_200L, 2_400L, "(ooh)", "bg", Arrays.asList(new TimedSyllable(1_200L, 1_200L, "(ooh)"))),
                new TimedLine(3_000L, 4_000L, "Hi there", "v2", Arrays.asList(
                    new TimedSyllable(3_000L, 400L, "Hi "), new TimedSyllable(3_400L, 600L, "there")))));
    }

    static LyricsDoc oddDoc() {
        return new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("", "", "", null, null),
            Arrays.asList(new Voice("lead", "lead", null)),
            Arrays.asList(new TimedLine(0L, 500L, "a\u0001b", "lead", Arrays.asList(new TimedSyllable(0L, 500L, "a\u0001b")))));
    }

    static LyricsDoc bareDoc() {
        return new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("Two\nlines", "", "", null, null),
            Arrays.asList(new Voice("lead", "lead", null)),
            Arrays.asList(new TimedLine(0L, 1_000L, "plain words", "lead", new ArrayList<>())));
    }

    /** Background lines before any lead line, a lone duet, CRLF in text and a header, line-only lines. */
    static LyricsDoc edgeDoc() {
        return new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata("  Spaced\r\nTitle ", " ", "Al\rbum", 59_499L, null),
            Arrays.asList(new Voice("bg", "background", null), new Voice("d", "duet", null), new Voice("lead", "lead", null)),
            Arrays.asList(
                new TimedLine(0L, 900L, "(intro)", "bg", Arrays.asList(new TimedSyllable(0L, 900L, "(intro)"))),
                new TimedLine(100L, 800L, "(also)", "bg", new ArrayList<>()),
                new TimedLine(1_000L, 2_000L, "  line only\n ", "d", new ArrayList<>()),
                new TimedLine(2_000L, 3_000L, "ab cd", "missing", Arrays.asList(
                    new TimedSyllable(2_000L, 300L, " "), new TimedSyllable(2_300L, 300L, "ab "),
                    new TimedSyllable(2_600L, 400L, "cd\r\n"))),
                new TimedLine(2_500L, 2_900L, "(echo)", "bg", Arrays.asList(new TimedSyllable(2_500L, 400L, "(echo)")))));
    }

    public static void main(String[] args) throws Exception {
        buildResult = LyricsTapSync.class.getMethod("buildResult-gIAlu-s", SyncDraft.class, int.class);
        failure = Class.forName("kotlin.Result$Failure");
        if (args.length == 2 && args[0].equals("debug")) {
            System.out.println(runSeed(Integer.parseInt(args[1]), true));
            return;
        }
        StringBuilder sb = new StringBuilder();

        // Kotlin's Random (XorWow) and its bounded draws.
        for (int seed : new int[] {0, 1, 3, 7, 42, -1, 499, Integer.MAX_VALUE, Integer.MIN_VALUE}) {
            Random r = RandomKt.Random(seed);
            List<String> v = new ArrayList<>();
            for (int i = 0; i < 3; i++) v.add(Integer.toString(r.nextInt()));
            for (int i = 0; i < 3; i++) v.add(Integer.toString(r.nextInt(1, 14)));
            v.add(Integer.toString(r.nextInt(0, 401)));
            v.add(Integer.toString(r.nextInt(100)));
            v.add(Integer.toString(r.nextInt(8)));
            v.add(Integer.toString(r.nextInt(3)));
            v.add(Integer.toString(r.nextInt(16)));
            v.add(Integer.toString(r.nextInt(-500, 501)));
            v.add(Integer.toString(r.nextInt(Integer.MIN_VALUE, Integer.MAX_VALUE)));
            for (int i = 0; i < 2; i++) v.add(Long.toString(r.nextLong(-400L, 2_000L)));
            v.add(Long.toString(r.nextLong(0L, 5_000L)));
            v.add(Long.toString(r.nextLong(1L, 900L)));
            v.add(Long.toString(r.nextLong(-100L, 900L)));
            v.add(Long.toString(r.nextLong(0L, 4_096L)));
            v.add(Long.toString(r.nextLong(0L, 1L << 32)));
            v.add(Long.toString(r.nextLong(0L, 1L << 40)));
            v.add(Long.toString(r.nextLong(Long.MIN_VALUE, Long.MAX_VALUE)));
            v.add(Long.toString(r.nextLong()));
            for (int i = 0; i < 3; i++) v.add(r.nextBoolean() ? "1" : "0");
            sb.append("R ").append(seed).append(' ').append(String.join(" ", v)).append('\n');
        }

        // tokenize: the test's samples, its 400-line fuzz (Random(7)) and extra edge cases.
        List<String> inputs = new ArrayList<>(Arrays.asList(
            "Hello world", "  spaced   out  ", "— lead", "trail —", "a - b — c … d & e",
            "君が好き", "「愛してる」、", "私はOK です。", "사랑해 너를", "twenty-one rock'n'roll",
            "👨‍👩‍👧 君と", "ゃ小さい", "ーラ", "(oh", "…",
            "  Hello   big\tworld  ", "   \t ", "Hi", "wait - what", "— hey you", "(oh yeah, baby)", "rock & roll…",
            "… …", "so… — yes", "don't night-time", "東京ラーメン", "きょうは", "Loveしてる", "あ".repeat(41),
            "あ".repeat(40), "君👨‍👩‍👧と", "愛❤️", "👍🏽 yes", "Café ok", "Café ok", "君‍a", "a‍b c",
            "x\u0001́y", "君́が", "ァ君", "君ァ", "ｶｧ", "ㇰ君ㇱ", "君️", "　君　", "a b c",
            "\u0085next", "x\u001Cy", "１２３", "，、。", "「」", "(君)", "君-が", "- 君", "𠀋𡈽", "Ünïcödé wörds", "a\r\nb",
            "שלום עולם", "مرحبا بالعالم", "สวัสดีครับ", "नमस्ते दुनिया"));
        List<String> pool = Arrays.asList(
            "love", "君", "が", "ラー", "ょ", "—", "&", "…", "、", "。", "「", "」", "a-b", "it's", " ", "  ", "\t",
            "❤️", "👨‍👩", "사랑", "OK", "(", ")", "é", "　");
        Random fuzzRandom = RandomKt.Random(7);
        for (int i = 0; i < 400; i++) {
            int n = fuzzRandom.nextInt(1, 14);
            StringBuilder line = new StringBuilder();
            for (int k = 0; k < n; k++) line.append(pick(pool, fuzzRandom));
            inputs.add(line.toString());
        }
        for (String input : inputs) sb.append("T ").append(q(input)).append(' ').append(qList(S.tokenize(input))).append('\n');

        // The random-session property test, step by step.
        for (int seed = 0; seed < 500; seed++) sb.append("S ").append(seed).append(' ').append(runSeed(seed, false)).append('\n');

        // Draft JSON.
        String base = STORE.encode$app(storeDraft("content://media/42"), 1_234_567_890_123L);
        sb.append("D ").append(q(base)).append('\n');
        for (String c : decodeCases(base)) {
            SyncDraft d = STORE.decode$app(c);
            sb.append("DIN ").append(q(c)).append('\n');
            sb.append("DOUT ").append(d == null ? "null" : q(STORE.encode$app(d, 0L))).append('\n');
        }
        for (String id : new String[] {"abc", "", "content://media/42", "keep", "old", "君が好き", "yt:dQw4w9WgXcQ",
            "x".repeat(200)}) {
            sb.append("H ").append(q(id)).append(' ').append(STORE.sha1$app(id)).append('\n');
        }

        // Exports.
        String[] names = {"doc", "duet", "odd", "bare", "edge"};
        LyricsDoc[] docs = {exportDoc(), duetDoc(), oddDoc(), bareDoc(), edgeDoc()};
        for (int i = 0; i < docs.length; i++) {
            sb.append("L ").append(names[i]).append(' ').append(q(LyricsExport.INSTANCE.toEnhancedLrc(docs[i]))).append('\n');
            sb.append("X ").append(names[i]).append(' ').append(q(LyricsExport.INSTANCE.toTtml(docs[i]))).append('\n');
        }

        System.out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.flush();
    }
}
