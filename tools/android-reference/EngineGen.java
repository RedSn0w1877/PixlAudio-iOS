import com.theveloper.pixelplay.data.model.*;
import com.theveloper.pixelplay.presentation.lyrics.*;
import com.theveloper.pixelplay.presentation.lyrics.background.*;
import com.theveloper.pixelplay.presentation.lyrics.model.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/**
 * Runs the Android app's compiled PreparedLyricsBuilder, LyricsEngine, LyricsClock and the lyrics maths
 * (EmphasisMath, InterludeTimeline, LyricsBlurMath, LyricsCascade, LyricsSprings, KaraokeAlpha, LyricsBackgroundGrade,
 * SpriteBlur, ArtworkSpriteBaker, the LyricsSheet line helpers) on the JVM and writes the PixlLyrics golden fixtures.
 *
 *   java -cp "$CP;." EngineGen lyrics-engine-cases.txt <fixtures-dir>
 *
 * Writes lyrics-prepared-golden.txt, lyrics-engine-golden.txt and lyrics-math-golden.txt (copy them into
 * Packages/PixlCore/Tests/PixlLyricsTests/Fixtures/). Every input line is echoed ("I<TAB>line") so the Swift tests
 * replay the same inputs; floats are IEEE-754 bit patterns.
 *
 * Classpath (Windows separator ';'), all from the Android project's Gradle cache / build output:
 *   stubs/            this folder's android/util/LruCache.java, compiled (`javac -d stubs stubs/android/util/LruCache.java`)
 *   app classes       app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes
 *   classes.jar of    androidx.compose.runtime:runtime-android, androidx.compose.animation:animation-core-android,
 *                     androidx.compose.ui:ui-graphics-android, androidx.compose.ui:ui-util-android (all 1.12.1)
 *   jars              androidx.collection:collection-jvm 1.6.0, kotlin-stdlib 2.4.0, kotlinx-collections-immutable-jvm
 *                     0.5.0, kotlinx-serialization-core/json-jvm 1.11.0, kotlinx-coroutines-core-jvm 1.11.0
 *   android.jar       $ANDROID_SDK/platforms/android-36/android.jar (stubs; Compose's Parcelable state needs it)
 * The stub folder must come before android.jar. Generated with JDK 26.
 */
public class EngineGen {
    static String f(float v) { return String.format("%08X", Float.floatToRawIntBits(v)); }
    static String b(boolean v) { return v ? "1" : "0"; }

    static String unescape(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                char n = s.charAt(i + 1);
                if (n == 'n') { sb.append('\n'); i++; continue; }
                if (n == 't') { sb.append('\t'); i++; continue; }
                if (n == 's') { sb.append(' '); i++; continue; }
                if (n == '\\') { sb.append('\\'); i++; continue; }
            }
            sb.append(c);
        }
        return sb.toString();
    }

    static String esc(String s) {
        if (s == null) return "-";
        if (s.equals("-")) return "\\-";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '\\' -> sb.append("\\\\");
                case '\t' -> sb.append("\\t");
                case '\n' -> sb.append("\\n");
                case ' ' -> sb.append("\\s");
                default -> {
                    if (Character.isSurrogate(c) && !(Character.isHighSurrogate(c) && i + 1 < s.length() && Character.isLowSurrogate(s.charAt(i + 1)))
                        && !(Character.isLowSurrogate(c) && i > 0 && Character.isHighSurrogate(s.charAt(i - 1)))) {
                        sb.append(String.format("\\u%04X", (int) c)); // lone surrogate (cannot be UTF-8)
                    } else sb.append(c);
                }
            }
        }
        return sb.toString();
    }

    static String field(String[] f, int i) { return i < f.length ? f[i] : ""; }
    static String nullable(String raw) { return raw.equals("-") ? null : unescape(raw); }
    static Integer optInt(String raw) { return raw.equals("-") ? null : Integer.valueOf(raw); }

    // ---- lyrics definitions -----------------------------------------------------------------

    static final class LyricsDef {
        List<String> plain = new ArrayList<>();
        List<Object[]> synced = new ArrayList<>(); // [time, end, role, text, words(List<SyncedWord>), translation, romanization]
        List<Voice> voices = null;
        List<Object[]> docLines = new ArrayList<>(); // [start, end, voiceId, text, syllables]
        boolean hasDoc = false;
        boolean hasSynced = false;
        boolean hasPlain = false;
        Lyrics build() {
            List<SyncedLine> sl = null;
            if (hasSynced || (!hasDoc && !hasPlain)) {
                sl = new ArrayList<>();
                for (Object[] l : synced) {
                    @SuppressWarnings("unchecked") List<SyncedWord> w = (List<SyncedWord>) l[4];
                    sl.add(new SyncedLine((Integer) l[0], (String) l[3], w, (String) l[5], (String) l[6], (Integer) l[1],
                        l[2] == null ? "lead" : (String) l[2]));
                }
            }
            LyricsDoc doc = null;
            if (hasDoc) {
                List<TimedLine> lines = new ArrayList<>();
                for (Object[] l : docLines) {
                    @SuppressWarnings("unchecked") List<TimedSyllable> s = (List<TimedSyllable>) l[4];
                    lines.add(new TimedLine((Long) l[0], (Long) l[1], (String) l[3], (String) l[2], s));
                }
                List<Voice> v = voices != null ? voices : List.of(new Voice());
                doc = new LyricsDoc("pixelplay-lyrics", 1, new LyricsMetadata(), v, lines);
            }
            return new Lyrics(hasPlain ? plain : null, sl, false, doc);
        }
    }

    static final Map<String, LyricsDef> defs = new LinkedHashMap<>();

    /** Parses one LYRICS block line; returns true when the block ended. */
    static boolean parseLyricsLine(LyricsDef d, String[] f) {
        switch (f[0]) {
            case "SL" -> {
                d.hasSynced = true;
                d.synced.add(new Object[]{Integer.valueOf(f[1]), optInt(f[2]), nullable(f[3]), unescape(field(f, 4)), null, null, null});
            }
            case "SW" -> {
                Object[] l = d.synced.get(d.synced.size() - 1);
                @SuppressWarnings("unchecked") List<SyncedWord> w = (List<SyncedWord>) l[4];
                if (w == null) { w = new ArrayList<>(); l[4] = w; }
                w.add(new SyncedWord(Integer.parseInt(f[1]), unescape(field(f, 4)), f[3].equals("1"), optInt(f[2])));
            }
            case "ST" -> d.synced.get(d.synced.size() - 1)[5] = nullable(field(f, 1));
            case "SR" -> d.synced.get(d.synced.size() - 1)[6] = nullable(field(f, 1));
            case "PLAIN" -> { d.hasPlain = true; d.plain.add(unescape(field(f, 1))); }
            case "DVDEFAULT" -> d.hasDoc = true;
            case "DV" -> {
                d.hasDoc = true;
                if (d.voices == null) d.voices = new ArrayList<>();
                d.voices.add(new Voice(unescape(f[1]), unescape(field(f, 2)), null));
            }
            case "DL" -> {
                d.hasDoc = true;
                d.docLines.add(new Object[]{Long.valueOf(f[1]), Long.valueOf(f[2]), unescape(f[3]), unescape(field(f, 4)), new ArrayList<TimedSyllable>()});
            }
            case "DS" -> {
                @SuppressWarnings("unchecked") List<TimedSyllable> s = (List<TimedSyllable>) d.docLines.get(d.docLines.size() - 1)[4];
                s.add(new TimedSyllable(Long.parseLong(f[1]), Long.parseLong(f[2]), unescape(field(f, 3))));
            }
            case "END" -> { return true; }
            default -> throw new IllegalArgumentException("bad lyrics line " + String.join("\t", f));
        }
        return false;
    }

    static void dumpPrepared(StringBuilder sb, String name, PreparedLyrics p) {
        if (p == null) { sb.append("P\t").append(name).append("\tnull\n"); return; }
        sb.append("P\t").append(name).append("\n");
        for (PreparedLine l : p.getLines()) {
            sb.append("PL\t").append(l.getIndex()).append('\t').append(l.getStartMs()).append('\t').append(l.getEndMs())
                .append('\t').append(b(l.getEndIsExplicit())).append('\t').append(l.getRole().name()).append('\t')
                .append(l.getGroupLeadIndex()).append('\t').append(b(l.getBgAbove())).append('\t').append(esc(l.getText()))
                .append('\t').append(esc(l.getTranslation())).append('\t').append(esc(l.getRomanization())).append('\n');
            if (l.getSyllables() == null) { sb.append("PN\n"); continue; }
            for (PreparedSyllable s : l.getSyllables()) {
                sb.append("PS\t").append(s.getCharStart()).append('\t').append(s.getCharEnd()).append('\t').append(s.getStartMs())
                    .append('\t').append(s.getEndMs()).append('\t').append(b(s.getEndIsExplicit())).append('\t')
                    .append(s.getWordIndex()).append('\t').append(b(s.getEmphasis())).append('\n');
            }
        }
        for (Row r : p.getRows()) {
            if (r instanceof Row.Line line) sb.append("PR\tline\t").append(line.getLineIndex()).append('\n');
            else {
                Row.Interlude i = (Row.Interlude) r;
                sb.append("PR\tinterlude\t").append(i.getStartMs()).append('\t').append(i.getEndMs()).append('\t').append(b(i.getAlignEnd())).append('\n');
            }
        }
        sb.append("PM\t").append(b(p.getHasWordTiming())).append('\t').append(b(p.getHasDuet())).append('\t')
            .append(p.getMaxLineDurationMs()).append('\t').append(p.getLastEndMs()).append('\n');
    }

    // ---- scenarios --------------------------------------------------------------------------

    static final long[] frameNanos = {0};
    static final long[] playerNanos = {0};
    static final long[] offsetMs = {0};
    static long stepNanos;
    static LyricsClock clock;
    static LyricsEngine engine;

    static void newEngine() {
        frameNanos[0] = 1_000_000_000L;
        playerNanos[0] = 0;
        offsetMs[0] = 0;
        stepNanos = 16_000_000L;
        clock = new LyricsClock(() -> playerNanos[0] / 1_000_000L, () -> offsetMs[0]);
        engine = new LyricsEngine(clock);
    }

    static void frame() {
        clock.tick(frameNanos[0]);
        engine.step(frameNanos[0]);
    }

    static void dump(StringBuilder sb) {
        sb.append("F\t").append(frameNanos[0]).append('\t').append(clock.getCurrentMs()).append('\t').append(engine.getScrollTargetRow())
            .append('\t').append(f(engine.getScrollOffset())).append('\t').append(b(engine.isUserScrolling())).append('\t')
            .append(b(engine.isAtRest())).append('\t').append(b(engine.getNeedsFrame())).append('\t').append(b(engine.isLaidOut$app()))
            .append('\n');
        List<LyricRowMotion> rows = engine.getRows();
        for (int r = 0; r < rows.size(); r++) {
            LyricRowMotion m = rows.get(r);
            sb.append("R\t").append(r).append('\t').append(f(m.getY())).append('\t').append(f(m.getScale())).append('\t')
                .append(f(m.getBlurRadiusPx())).append('\t').append(f(m.getDepthAlpha())).append('\t').append(f(m.getActiveness()))
                .append('\t').append(b(m.getHot())).append('\t').append(f(m.getExpand())).append('\t').append(f(m.getPresence()))
                .append('\t').append(b(m.getPrefetch())).append('\t').append(f(engine.rowSpringY$app(r))).append('\t')
                .append(engine.rowPendingAtNanos$app(r)).append('\t').append(f(engine.rowSigmaTargetDp$app(r))).append('\n');
        }
    }

    static void runScenarioLine(StringBuilder sb, String[] f) {
        switch (f[0]) {
            case "NEWENGINE" -> newEngine();
            case "CONFIG" -> engine.setConfig(new LyricsEngineConfig(Float.parseFloat(f[1]), f[2].equals("1"), f[3].equals("1"),
                Float.parseFloat(f[4]), f[5].equals("1")));
            case "LYRICS-SET" -> engine.setLyrics(PreparedLyricsBuilder.INSTANCE.build(defs.get(f[1]).build()), f[2].equals("1"));
            case "VIEW" -> engine.setViewport(Float.parseFloat(f[1]), Float.parseFloat(f[2]));
            case "HEIGHTS" -> { for (int r = 0; r < engine.getRows().size(); r++) engine.setRowHeight(r, Float.parseFloat(f[1])); }
            case "HEIGHTLIST" -> { for (int r = 1; r < f.length; r++) engine.setRowHeight(r - 1, Float.parseFloat(f[r])); }
            case "HEIGHT" -> engine.setRowHeight(Integer.parseInt(f[1]), Float.parseFloat(f[2]));
            case "PLAY" -> clock.setPlaying(f[1].equals("1"));
            case "POS" -> playerNanos[0] = Long.parseLong(f[1]) * 1_000_000L;
            case "OFFSET" -> offsetMs[0] = Long.parseLong(f[1]);
            case "STEPNS" -> stepNanos = Long.parseLong(f[1]);
            case "FRAME" -> { frame(); dump(sb); }
            case "ADV" -> {
                long left = Long.parseLong(f[1]) * 1_000_000L;
                int stride = Integer.parseInt(f[2]);
                int i = 0;
                while (left > 0) {
                    long d = Math.min(stepNanos, left);
                    frameNanos[0] += d;
                    if (clock.isPlaying()) playerNanos[0] += d;
                    frame();
                    i++;
                    left -= d;
                    if (i % stride == 0 || left == 0) dump(sb);
                }
            }
            case "GAP" -> frameNanos[0] += Long.parseLong(f[1]) * 1_000_000L;
            case "REBASE" -> clock.rebase();
            case "RESET" -> clock.reset();
            case "MARKSEEK" -> clock.markSeek();
            case "DRAGSTART" -> engine.onDragStart();
            case "DRAG" -> engine.onDrag(Float.parseFloat(f[1]));
            case "DRAGEND" -> engine.onDragEnd(Float.parseFloat(f[1]));
            case "TAP" -> engine.onLineTapped(Integer.parseInt(f[1]));
            case "SCROLLBY" -> engine.scrollBy(Float.parseFloat(f[1]));
            default -> throw new IllegalArgumentException("bad scenario line " + String.join("\t", f));
        }
    }

    // ---- maths ------------------------------------------------------------------------------

    static void maths(StringBuilder sb) {
        LyricsSprings S = LyricsSprings.INSTANCE;
        sb.append("M\tsprings\t").append(f(S.getSlowDampingRatio())).append('\t').append(f(S.getSlowStiffness())).append('\t')
            .append(f(S.getEndedDampingRatio())).append('\t').append(f(S.getEndedStiffness())).append('\t')
            .append(f(S.getScaleDampingRatio())).append('\t').append(f(S.getScaleStiffness())).append('\t')
            .append(f(S.getNormalDampingRatio())).append('\n');
        for (long gap = -50; gap <= 1000; gap += 7) {
            sb.append("M\tnormalStiffness\t").append(gap).append('\t').append(f(S.normalPlaybackStiffness(gap))).append('\n');
        }
        LyricsBlurMath B = LyricsBlurMath.INSTANCE;
        float[] strengths = {0.5f, 1f, 1.2f, 2f, 0f};
        for (int d = -1; d <= 9; d++) {
            for (float s : strengths) sb.append("M\tdepthSigma\t").append(d).append('\t').append(f(s)).append('\t').append(f(B.depthSigmaDp(d, s))).append('\n');
            sb.append("M\tfallbackAlpha\t").append(d).append('\t').append(f(B.fallbackAlphaFactor(d))).append('\n');
        }
        float[] densities = {1f, 2f, 2.75f, 3f};
        for (float density : densities) {
            for (int k = 0; k <= 70; k++) {
                float sigma = k * 0.0731f;
                float r = B.sigmaDpToRadiusPx(sigma, density);
                sb.append("M\tradius\t").append(f(sigma)).append('\t').append(f(density)).append('\t').append(f(r)).append('\t')
                    .append(f(B.quantizeRadiusPx(r))).append('\t').append(f(B.cssShadowBlurToRadiusPx(sigma * 2f, density))).append('\n');
            }
        }
        for (int k = 0; k <= 100; k++) {
            float r = k * 0.375f;
            sb.append("M\tquantize\t").append(f(r)).append('\t').append(f(B.quantizeRadiusPx(r))).append('\n');
        }
        // Cascade
        float[][] tops = {{0, 100, 200, 300, 400}, {-300, -150, 0, 100}, {0, 100, 100, 200}, {-80, -20, 30, 90, 160, 700, 1400, 2000}};
        float[][] heights = {{100, 100, 100, 100, 100}, {100, 100, 100, 100}, {100, 0, 100, 100}, {50, 60, 0.4f, 70, 80, 90, 0, 55}};
        int[] targets = {2, 3, 0, 4};
        for (int c = 0; c < tops.length; c++) {
            for (int t = -1; t <= tops[c].length; t++) {
                float[] out = new float[tops[c].length];
                LyricsCascade.INSTANCE.computeDelays(tops[c], heights[c], tops[c].length, t, out);
                sb.append("M\tcascade\t").append(c).append('\t').append(t);
                for (float v : out) sb.append('\t').append(f(v));
                sb.append('\n');
            }
        }
        // Emphasis
        EmphasisMath E = EmphasisMath.INSTANCE;
        for (long du = -500; du <= 9000; du += 125) {
            for (int last = 0; last <= 1; last++) {
                boolean l = last == 1;
                sb.append("M\temphasis\t").append(du).append('\t').append(last).append('\t').append(f(E.amount(du, l))).append('\t')
                    .append(f(E.glow(du, l))).append('\t').append(f(E.effectiveDurationMs(du, l))).append('\t')
                    .append(f(E.peakScale(du, l))).append('\t').append(f(E.peakGlowAlpha(du, l))).append('\t')
                    .append(f(E.glowBlurEm(E.glow(du, l)))).append('\n');
            }
        }
        for (int k = -10; k <= 1010; k++) {
            float x = k / 1000f;
            sb.append("M\tenvelope\t").append(f(x)).append('\t').append(f(E.envelope(x))).append('\t').append(f(E.strengthCurve(x * 3f)))
                .append('\t').append(f(E.scale(E.envelope(x), 0.84f))).append('\t').append(f(E.offsetXEm(E.envelope(x), 0.84f, 5, k % 5)))
                .append('\t').append(f(E.offsetYEm(E.envelope(x), 0.84f))).append('\t').append(f(E.glowAlpha(E.envelope(x), 0.6f))).append('\n');
        }
        long[] durations = {0, 300, 999, 1000, 1700, 4000};
        for (long dur : durations) {
            for (long t = 900; t <= 6200; t += 97) {
                sb.append("M\tlift\t").append(dur).append('\t').append(t).append('\t').append(f(E.liftEm(t, 1000, dur, false))).append('\t')
                    .append(f(E.liftEm(t, 1000, dur, true))).append('\t').append(f(E.syllableProgress(t, 1000, 1000 + dur))).append('\n');
            }
        }
        float[] dus = {1000f, 1200f, 2400f, 3600f};
        for (float du : dus) {
            for (int n = 1; n <= 7; n += 3) {
                for (int i = 0; i < n; i++) {
                    float cs = E.graphemeStartMs(5000, du, n, i);
                    for (long t = 4400; t <= 10000; t += 211) {
                        sb.append("M\tgrapheme\t").append(f(du)).append('\t').append(n).append('\t').append(i).append('\t').append(t)
                            .append('\t').append(f(cs)).append('\t').append(f(E.graphemeProgress(t, cs, du))).append('\t')
                            .append(f(E.hopEm(t, cs, du))).append('\n');
                    }
                }
            }
        }
        for (int k = 0; k <= 20; k++) {
            float p = k / 20f;
            sb.append("M\tsweep\t").append(f(p)).append('\t').append(f(E.sweepEdgeCenterPx(10.5f, 117.25f, 24.6f, p))).append('\n');
        }
        // Alphas
        float[] inactives = {KaraokeAlpha.INACTIVE, KaraokeAlpha.INACTIVE_BRIGHT_ART, KaraokeAlpha.INACTIVE_HIGH_CONTRAST};
        for (float inactive : inactives) {
            for (int k = 0; k <= 40; k++) {
                float a = k / 40f;
                sb.append("M\talpha\t").append(f(inactive)).append('\t').append(f(a)).append('\t')
                    .append(f(KaraokeAlpha.INSTANCE.unsung(a, inactive))).append('\t').append(f(KaraokeAlpha.INSTANCE.sung(a, inactive)))
                    .append('\t').append(f(KaraokeAlpha.INSTANCE.translation(a, KaraokeAlpha.TRANSLATION_INACTIVE))).append('\n');
            }
        }
        // Interlude
        InterludeTimeline I = InterludeTimeline.INSTANCE;
        long[][] gapsList = {{10_000, 30_000}, {0, 2_000}, {4_000, 13_000}, {5_000, 5_000}, {60_000, 63_100}};
        for (long[] g : gapsList) {
            for (long t = g[0] - 40; t <= g[1] + 40; t += 37) {
                sb.append("M\tinterlude\t").append(g[0]).append('\t').append(g[1]).append('\t').append(t).append('\t')
                    .append(b(I.isActive(t, g[0], g[1]))).append('\t').append(f(I.presence(t, g[0], g[1]))).append('\t')
                    .append(f(I.scale(t, g[0], g[1]))).append('\t').append(f(I.baseScale(t, g[0], g[1]))).append('\t')
                    .append(f(I.dotAlpha(t, g[0], g[1], 0))).append('\t').append(f(I.dotAlpha(t, g[0], g[1], 1))).append('\t')
                    .append(f(I.dotAlpha(t, g[0], g[1], 2))).append('\n');
            }
        }
        // Grade
        float[] grade = LyricsBackgroundGrade.INSTANCE.getGRADE();
        sb.append("M\tgradeMatrix");
        for (float v : grade) sb.append('\t').append(f(v));
        sb.append('\n');
        Random random = new Random(20260930L);
        float[] out = new float[3];
        for (int k = 0; k < 600; k++) {
            float r = random.nextFloat(), g = random.nextFloat(), bl = random.nextFloat();
            if (k < 8) { r = (k & 1); g = (k >> 1) & 1; bl = (k >> 2) & 1; }
            LyricsBackgroundGrade.INSTANCE.gradeReference(r, g, bl, out);
            float luma = LyricsBackgroundGrade.INSTANCE.gradedLuma(r, g, bl, new float[3]);
            sb.append("M\tgrade\t").append(f(r)).append('\t').append(f(g)).append('\t').append(f(bl)).append('\t').append(f(out[0]))
                .append('\t').append(f(out[1])).append('\t').append(f(out[2])).append('\t').append(f(luma)).append('\n');
        }
        // Sprite blur
        for (int k = 0; k <= 60; k++) {
            float sigma = k * 0.31f;
            int[] radii = SpriteBlur.INSTANCE.boxRadiiForGaussian(sigma, 3);
            sb.append("M\tboxRadii\t").append(f(sigma)).append('\t').append(radii[0]).append('\t').append(radii[1]).append('\t').append(radii[2]).append('\n');
        }
        int artSize = 12;
        int[] art = new int[artSize * artSize];
        Random artRandom = new Random(96L);
        for (int i = 0; i < art.length; i++) {
            int a = (i % 7 == 0) ? 0x80 : 0xFF;
            art[i] = (a << 24) | (artRandom.nextInt(256) << 16) | (artRandom.nextInt(256) << 8) | artRandom.nextInt(256);
        }
        sb.append("M\tart");
        for (int v : art) sb.append('\t').append(String.format("%08X", v));
        sb.append('\n');
        Object[][] bakes = {{0, 2.3f, true}, {4, 1.6f, false}, {7, 2.2f, false}, {0, 0.3f, false}};
        for (Object[] bk : bakes) {
            int pad = (Integer) bk[0];
            float sigma = (Float) bk[1];
            boolean opaque = (Boolean) bk[2];
            int[] px = SpriteBlur.INSTANCE.bakeSprite(art, artSize, pad, sigma, opaque);
            sb.append("M\tbake\t").append(pad).append('\t').append(f(sigma)).append('\t').append(b(opaque));
            for (int v : px) sb.append('\t').append(String.format("%08X", v));
            sb.append('\n');
        }
        ArtworkSpriteBaker A = ArtworkSpriteBaker.INSTANCE;
        int[][] views = {{1179, 2556}, {2556, 1179}, {390, 844}, {0, 0}, {100, 5}, {844, 844}};
        for (int[] v : views) {
            sb.append("M\tsprites\t").append(v[0]).append('\t').append(v[1]).append('\t').append(A.aspectBucket(v[0], v[1]));
            for (int k = 0; k < 4; k++) sb.append('\t').append(f(A.spriteArtSize(k, v[0], v[1])));
            sb.append('\n');
        }
        // LyricsSheet line helpers
        String[] raws = {"[00:26.42][01:12.34] Three in the morning, I ain't slept all weekend", "v1: Hello", "V23:\t  Hi",
            "v: no", "[1:23]x[12:345]y[1:23.4567]z[1:23:45] end", "  [00:01.00]  v2:  spaced  ", "[00:01]", "", "vv1: no",
            "[0:00.1]v1:x", "text [00:10.00] mid", "　[00:01.00]ideographic space"};
        for (String raw : raws) {
            sb.append("M\tsanitize\t").append(esc(raw)).append('\t').append(esc(PreparedLyricsBuilderKt.sanitizeLyricLineText(raw)))
                .append('\t').append(esc(com.theveloper.pixelplay.utils.LyricsUtils.INSTANCE.stripLrcTimestamps$app(raw))).append('\n');
        }
        String[] counts = {"hello", "éa", "one two  three", "我爱你", "", "áb", "👨‍👩‍👧 family", "한국어 노래", "😀😀", " \t "};
        for (String c : counts) {
            sb.append("M\tcounts\t").append(esc(c)).append('\t').append(PreparedLyricsBuilder.INSTANCE.graphemeCount$app(c)).append('\t')
                .append(PreparedLyricsBuilder.INSTANCE.estimateWordCount$app(c));
            for (int v : EmphasisMath.INSTANCE.graphemeBoundaries(c)) sb.append('\t').append(v);
            sb.append('\n');
        }
        // (LyricsSheetKt.resolveSeekPositionMs is not run here: loading LyricsSheetKt pulls in the whole Compose UI.)
        String[] shaping = {"Never gonna give you up", "حبيبي يا نور العين", "दिल से रे", "שלום עולם", "  «حبيبي» baby", "baby حبيبي",
            "123 ...", "ﻻ", "ក្ដី", "夜に駆ける", "‏x", "", "Ça plane pour moi"};
        for (String s : shaping) {
            sb.append("M\tshaping\t").append(esc(s)).append('\t').append(b(LyricsRenderStyle.Companion.needsShapedPieces(s))).append('\t')
                .append(b(LyricsRenderStyle.Companion.isRtlText(s))).append('\n');
        }
    }

    public static void main(String[] args) throws Exception {
        List<String> lines = Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8);
        Path outDir = Path.of(args[1]);
        StringBuilder prepared = new StringBuilder("// PreparedLyricsBuilder golden: I = input line, P/PL/PS/PN/PR/PM = Android output\n");
        StringBuilder trace = new StringBuilder("// LyricsEngine golden: I = input line, F/R = Android engine state after a frame\n");
        LyricsDef current = null;
        String currentName = null;
        boolean inScenario = false;
        for (String raw : lines) {
            if (raw.isEmpty() || raw.startsWith("#")) continue;
            String[] f = raw.split("\t", -1);
            if (current != null) {
                prepared.append("I\t").append(raw).append('\n');
                trace.append("I\t").append(raw).append('\n');
                if (parseLyricsLine(current, f)) {
                    defs.put(currentName, current);
                    dumpPrepared(prepared, currentName, PreparedLyricsBuilder.INSTANCE.build(current.build()));
                    current = null;
                }
                continue;
            }
            if (f[0].equals("LYRICS")) {
                current = new LyricsDef();
                currentName = f[1];
                prepared.append("I\t").append(raw).append('\n');
                trace.append("I\t").append(raw).append('\n');
                continue;
            }
            trace.append("I\t").append(raw).append('\n');
            if (f[0].equals("SCENARIO")) { inScenario = true; continue; }
            if (f[0].equals("ENDSCENARIO")) { inScenario = false; continue; }
            if (!inScenario) throw new IllegalArgumentException("line outside a block: " + raw);
            runScenarioLine(trace, f);
        }
        StringBuilder math = new StringBuilder("// Lyrics maths golden: M <function> <inputs…> <outputs…> (floats as bit patterns)\n");
        maths(math);
        Files.writeString(outDir.resolve("lyrics-prepared-golden.txt"), prepared.toString(), StandardCharsets.UTF_8);
        Files.writeString(outDir.resolve("lyrics-engine-golden.txt"), trace.toString(), StandardCharsets.UTF_8);
        Files.writeString(outDir.resolve("lyrics-math-golden.txt"), math.toString(), StandardCharsets.UTF_8);
    }
}
