import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.theveloper.pixelplay.data.model.Lyrics;
import com.theveloper.pixelplay.data.model.LyricsDoc;
import com.theveloper.pixelplay.data.model.LyricsDocCodec;
import com.theveloper.pixelplay.data.model.LyricsMetadata;
import com.theveloper.pixelplay.data.model.Song;
import com.theveloper.pixelplay.data.model.SyncedLine;
import com.theveloper.pixelplay.data.model.SyncedWord;
import com.theveloper.pixelplay.data.network.lyrics.LrcLibResponse;
import com.theveloper.pixelplay.data.network.lyrics.LyricsfileParser;
import com.theveloper.pixelplay.data.network.lyrics.WordSyncTranspilers;
import com.theveloper.pixelplay.utils.LyricsImportSecurity;
import com.theveloper.pixelplay.utils.LyricsImportValidationResult;
import com.theveloper.pixelplay.utils.LyricsUtils;
import com.theveloper.pixelplay.utils.MultiLangRomanizer;
import com.theveloper.pixelplay.utils.TtmlLyricsParser;
import kotlinx.serialization.json.JsonElementKt;
import net.sourceforge.pinyin4j.PinyinHelper;
import net.sourceforge.pinyin4j.format.HanyuPinyinCaseType;
import net.sourceforge.pinyin4j.format.HanyuPinyinOutputFormat;
import net.sourceforge.pinyin4j.format.HanyuPinyinToneType;

import java.io.ByteArrayInputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/**
 * Runs the Android app's real lyrics parsers (LyricsUtils, TtmlLyricsParser, WordSyncTranspilers,
 * LyricsfileParser, LyricsImportSecurity, MultiLangRomanizer, the LRCLIB ranking in LyricsRepositoryImpl and the
 * AMLL/NetEase matchers) over every case in lyrics-cases.txt and prints "IN <kind> <json args>" /
 * "OUT <json result>" pairs for PixlLyricsTests.
 *
 * Case lines: KIND, a TAB, then TAB-separated arguments. In arguments "\n" "\r" "\t" "\\" and "\\uXXXX" are
 * unescaped; an argument "@name" is replaced by the content of that file (relative to the cases file), and the
 * literal argument "<null>" passes null. Blank lines and lines starting with '#' are skipped.
 */
public class LyricsGen {
    static String q(String s) { return s == null ? "null" : JsonElementKt.JsonPrimitive(s).toString(); }

    static String unescape(String line) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '\\' && i + 1 < line.length()) {
                char n = line.charAt(i + 1);
                if (n == 'n') { sb.append('\n'); i++; continue; }
                if (n == 'r') { sb.append('\r'); i++; continue; }
                if (n == 't') { sb.append('\t'); i++; continue; }
                if (n == '\\') { sb.append('\\'); i++; continue; }
                if (n == 'u' && i + 5 < line.length()) {
                    sb.append((char) Integer.parseInt(line.substring(i + 2, i + 6), 16));
                    i += 5;
                    continue;
                }
            }
            sb.append(c);
        }
        return sb.toString();
    }

    static String lyricsJson(Lyrics l) {
        if (l == null) return "null";
        StringBuilder sb = new StringBuilder("{\"plain\":");
        if (l.getPlain() == null) sb.append("null"); else {
            sb.append('[');
            for (int i = 0; i < l.getPlain().size(); i++) { if (i > 0) sb.append(','); sb.append(q(l.getPlain().get(i))); }
            sb.append(']');
        }
        sb.append(",\"synced\":");
        if (l.getSynced() == null) sb.append("null"); else {
            sb.append('[');
            for (int i = 0; i < l.getSynced().size(); i++) {
                if (i > 0) sb.append(',');
                SyncedLine s = l.getSynced().get(i);
                sb.append("{\"time\":").append(s.getTime()).append(",\"line\":").append(q(s.getLine())).append(",\"words\":");
                if (s.getWords() == null) sb.append("null"); else {
                    sb.append('[');
                    for (int j = 0; j < s.getWords().size(); j++) {
                        if (j > 0) sb.append(',');
                        SyncedWord w = s.getWords().get(j);
                        sb.append("{\"time\":").append(w.getTime()).append(",\"word\":").append(q(w.getWord()))
                            .append(",\"startsNewWord\":").append(w.getStartsNewWord())
                            .append(",\"endTime\":").append(w.getEndTime() == null ? "null" : w.getEndTime().toString()).append('}');
                    }
                    sb.append(']');
                }
                sb.append(",\"translation\":").append(q(s.getTranslation()))
                    .append(",\"romanization\":").append(q(s.getRomanization()))
                    .append(",\"endTime\":").append(s.getEndTime() == null ? "null" : s.getEndTime().toString())
                    .append(",\"voiceRole\":").append(q(s.getVoiceRole())).append('}');
            }
            sb.append(']');
        }
        sb.append(",\"areFromRemote\":").append(l.getAreFromRemote());
        sb.append(",\"document\":").append(l.getDocument() == null ? "null" : q(LyricsDocCodec.INSTANCE.encode(l.getDocument())));
        return sb.append('}').toString();
    }

    static String docJson(LyricsDoc d) { return d == null ? "null" : q(LyricsDocCodec.INSTANCE.encode(d)); }

    static String importJson(LyricsImportValidationResult r) {
        if (r instanceof LyricsImportValidationResult.Valid v) {
            return "{\"valid\":true,\"sanitized\":" + q(v.getValue().getSanitizedContent()) + ",\"lyrics\":"
                + lyricsJson(v.getValue().getParsedLyrics()) + "}";
        }
        return "{\"valid\":false,\"reason\":" + q(((LyricsImportValidationResult.Invalid) r).getReason().name()) + "}";
    }

    static String setJson(java.util.Collection<?> set) {
        StringBuilder sb = new StringBuilder("[");
        int i = 0;
        for (Object o : new TreeSet<>(set.stream().map(Object::toString).toList())) {
            if (i++ > 0) sb.append(',');
            sb.append(q(o.toString()));
        }
        return sb.append(']').toString();
    }

    static Song song(String title, String artist, String album, String path, long duration) {
        return new Song("1", title, artist, 1L, List.of(), album, 1L, null, path, "", null, duration, null, null,
            false, 0, null, 0, 0L, 0L, null, null, null, null);
    }

    static List<String> strings(String json) {
        List<String> out = new ArrayList<>();
        for (var e : JsonParser.parseString(json).getAsJsonArray()) out.add(e.getAsString());
        return out;
    }

    static Object repo;
    static Class<?> modeClass;

    static Object repo() throws Exception {
        if (repo == null) {
            Field f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
            f.setAccessible(true);
            Object unsafe = f.get(null);
            Class<?> cls = Class.forName("com.theveloper.pixelplay.data.repository.LyricsRepositoryImpl");
            repo = unsafe.getClass().getMethod("allocateInstance", Class.class).invoke(unsafe, cls);
            modeClass = Class.forName("com.theveloper.pixelplay.data.repository.RemoteLyricsMatchMode");
        }
        return repo;
    }

    static Object call(String name, Object... args) throws Exception {
        Object r = repo();
        for (Method m : r.getClass().getDeclaredMethods()) {
            if (m.getName().equals(name) && m.getParameterCount() == args.length) {
                m.setAccessible(true);
                return m.invoke(r, args);
            }
        }
        throw new NoSuchMethodException(name);
    }

    static Object companionCall(String className, String prefix, Object... args) throws Exception {
        Class<?> cls = Class.forName(className);
        Object companion = cls.getField("Companion").get(null);
        for (Method m : companion.getClass().getDeclaredMethods()) {
            if (m.getName().startsWith(prefix) && m.getParameterCount() == args.length) {
                m.setAccessible(true);
                return m.invoke(companion, args);
            }
        }
        throw new NoSuchMethodException(prefix);
    }

    static Object mode(String name) throws Exception {
        repo();
        for (Object c : modeClass.getEnumConstants()) if (((Enum<?>) c).name().equals(name)) return c;
        throw new IllegalArgumentException(name);
    }

    static String run(String kind, List<String> a) throws Exception {
        switch (kind) {
            case "P": return lyricsJson(LyricsUtils.INSTANCE.parseLyrics(a.get(0)));
            case "Z": {
                Lyrics l = LyricsUtils.INSTANCE.parseLyrics(a.get(0));
                return "[" + q(LyricsUtils.INSTANCE.toLrcString(l, true)) + "," + q(LyricsUtils.INSTANCE.toLrcString(l, false)) + "]";
            }
            case "T": return q(TtmlLyricsParser.INSTANCE.parseToEnhancedLrc(a.get(0)));
            case "Y": return docJson(WordSyncTranspilers.INSTANCE.yrc(a.get(0), new LyricsMetadata("", "", "", null, "NetEase")));
            case "R": return docJson(WordSyncTranspilers.INSTANCE.richSync(a.get(0), new LyricsMetadata("", "", "", null, "Musixmatch")));
            case "L": return lyricsJson(LyricsfileParser.INSTANCE.parse(a.get(0)));
            case "I": {
                byte[] bytes = a.get(2).getBytes(StandardCharsets.UTF_8);
                return importJson(LyricsImportSecurity.INSTANCE.validateImportedLyricsFile(a.get(0), a.get(1),
                    new ByteArrayInputStream(bytes), a.size() > 3 && a.get(3) != null ? Long.parseLong(a.get(3)) : null));
            }
            case "IH": {
                String hex = a.get(2);
                byte[] bytes = new byte[hex.length() / 2];
                for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
                return importJson(LyricsImportSecurity.INSTANCE.validateImportedLyricsFile(a.get(0), a.get(1),
                    new ByteArrayInputStream(bytes), null));
            }
            case "IC": return importJson(LyricsImportSecurity.INSTANCE.validateImportedLrcContent(a.get(0)));
            case "RO": {
                MultiLangRomanizer r = MultiLangRomanizer.INSTANCE;
                String t = a.get(0);
                return "{\"zh\":" + q(r.romanizeChinese(t)) + ",\"ko\":" + q(r.romanizeKorean(t)) + ",\"hi\":" + q(r.romanizeHindi(t))
                    + ",\"pa\":" + q(r.romanizePunjabi(t)) + ",\"cyr\":" + q(r.romanizeCyrillic(t))
                    + ",\"needs\":" + r.isScriptThatNeedsRomanization(t) + "}";
            }
            case "NM": {
                String v = a.get(0);
                return "{\"normalize\":" + q((String) call("normalizeForMatch", v))
                    + ",\"base\":" + q((String) call("baseTitleForMatching", v))
                    + ",\"variants\":" + setJson((java.util.Set<?>) call("timingVariantTokens", v))
                    + ",\"smart\":" + q((String) call("cleanTitleSmart", v))
                    + ",\"roman\":" + q((String) call("romanizeForMatch", v)) + "}";
            }
            case "TS": {
                Object t = call("titleMatchScore", a.get(1), a.get(2), mode(a.get(0)));
                Object r = call("artistMatchScore", a.get(1), a.get(2));
                return "{\"title\":" + t + ",\"artist\":" + r + "}";
            }
            case "M": {
                Song s = song(a.get(1), a.get(2), "Album", a.get(3), Long.parseLong(a.get(4)));
                LrcLibResponse[] responses = new Gson().fromJson(a.get(5), LrcLibResponse[].class);
                List<?> ranked = (List<?>) call("rankRemoteLyricsMatches", s, Arrays.asList(responses), mode(a.get(0)));
                StringBuilder sb = new StringBuilder("[");
                for (int i = 0; i < ranked.size(); i++) {
                    Object m = ranked.get(i);
                    Method resp = m.getClass().getMethod("getResponse");
                    Method score = m.getClass().getMethod("getScore");
                    resp.setAccessible(true);
                    score.setAccessible(true);
                    if (i > 0) sb.append(',');
                    sb.append("{\"id\":").append(((LrcLibResponse) resp.invoke(m)).getId()).append(",\"score\":").append(score.invoke(m))
                        .append(",\"raw\":").append(q((String) call("remoteRawLyrics", resp.invoke(m)))).append('}');
                }
                return sb.append(']').toString();
            }
            case "A": {
                Song s = song(a.get(0), a.get(1), a.get(2), "", 0L);
                return String.valueOf(companionCall("com.theveloper.pixelplay.data.network.lyrics.AmllLyricsSource", "matchesMetadata",
                    s, strings(a.get(3)), strings(a.get(4)), strings(a.get(5))));
            }
            case "N": {
                Song s = song(a.get(0), a.get(1), a.get(2), "", Long.parseLong(a.get(3)));
                JsonObject track = JsonParser.parseString(a.get(4)).getAsJsonObject();
                return String.valueOf(companionCall("com.theveloper.pixelplay.data.network.lyrics.NeteaseLyricsSource", "matchesRecording", s, track));
            }
            case "E": {
                Map<String, String[]> map = new LinkedHashMap<>();
                JsonObject o = JsonParser.parseString(a.get(0)).getAsJsonObject();
                for (var e : o.entrySet()) map.put(e.getKey(), strings(e.getValue().toString()).toArray(new String[0]));
                Class<?> kt = Class.forName("com.theveloper.pixelplay.data.repository.LyricsRepositoryImplKt");
                return lyricsJson((Lyrics) kt.getMethod("parseBestEmbeddedLyricsField", Map.class).invoke(null, map));
            }
            case "RAW": {
                Lyrics l = LyricsUtils.INSTANCE.parseLyrics(a.get(0));
                return "{\"raw\":" + q((String) call("lyricsToRawContent", l)) + ",\"flattened\":" + call("looksLikeFlattenedWordByWordCache", l) + "}";
            }
            default: throw new IllegalArgumentException("Unknown kind " + kind);
        }
    }

    public static void main(String[] args) throws Exception {
        Path casesPath = Path.of(args[0]);
        List<String> lines = Files.readAllLines(casesPath, StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder();
        TreeSet<Character> han = new TreeSet<>();
        for (String raw : lines) {
            if (raw.isBlank() || raw.startsWith("#")) continue;
            String[] parts = raw.split("\t", -1);
            String kind = parts[0];
            List<String> a = new ArrayList<>();
            for (int i = 1; i < parts.length; i++) {
                String p = parts[i];
                if (p.equals("<null>")) { a.add(null); continue; }
                if (p.startsWith("@")) { a.add(Files.readString(casesPath.resolveSibling(p.substring(1)), StandardCharsets.UTF_8)); continue; }
                a.add(unescape(p));
            }
            for (String s : a) if (s != null) for (char c : s.toCharArray()) if (c >= '一' && c <= '龥') han.add(c);
            StringBuilder in = new StringBuilder("[");
            for (int i = 0; i < a.size(); i++) { if (i > 0) in.append(','); in.append(q(a.get(i))); }
            in.append(']');
            String out;
            try {
                out = run(kind, a);
            } catch (Throwable t) {
                out = "{\"error\":" + q(t.toString()) + "}";
            }
            sb.append("IN ").append(kind).append(' ').append(in).append('\n');
            sb.append("OUT ").append(out).append('\n');
        }
        // pinyin4j's reading for every Han character used, so Swift can inject the same per-character fallback.
        HanyuPinyinOutputFormat format = new HanyuPinyinOutputFormat();
        format.setCaseType(HanyuPinyinCaseType.LOWERCASE);
        format.setToneType(HanyuPinyinToneType.WITHOUT_TONE);
        StringBuilder pinyin = new StringBuilder("PINYIN {");
        int n = 0;
        for (char c : han) {
            String[] readings = PinyinHelper.toHanyuPinyinStringArray(c, format);
            String first = readings == null || readings.length == 0 ? null : readings[0];
            if (n++ > 0) pinyin.append(',');
            pinyin.append(q(String.valueOf(c))).append(':').append(q(first));
        }
        pinyin.append("}\n");
        System.out.write((pinyin + sb.toString()).getBytes(StandardCharsets.UTF_8));
        System.out.flush();
    }
}
