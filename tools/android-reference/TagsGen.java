import com.theveloper.pixelplay.data.media.AudioMetadataReader;
import com.theveloper.pixelplay.data.media.ReplayGainManager;
import com.theveloper.pixelplay.data.media.SongMetadataEditor;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.URLConnection;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Golden vectors for PixlTags (stage 3d). Runs the Android app's compiled tag helpers on a desktop JVM and writes one
 * JSON object per line into Packages/PixlCore/Tests/PixlTagsTests/Fixtures/tags-android-golden.jsonl:
 * ReplayGainManager (parseGainString, gainDbToVolume, getVolumeMultiplier), AudioMetadataReader.parseReplayGainDb,
 * SongMetadataEditor (parseReplayGainUpdate, validateMetadataInput, detectContainerFormat, isProblematicFlacFile),
 * Kotlin toFloatOrNull/toIntOrNull and java.net.URLConnection.guessContentTypeFromStream (AudioMetadataUtils'
 * guessImageMimeType). TagLib itself is a native arm64 library and cannot run here.
 *
 * Classpath (Windows separators): the app's compileDebugKotlin/classes, android.jar (platforms/android-37.0),
 * kotlin-stdlib 2.4.0, timber 5.0.1 classes.jar (from the .aar), com.kyant:taglib 1.0.6 classes.jar (from the .aar).
 *   javac -cp "$CP" TagsGen.java && java -Duser.language=en -Duser.country=US -cp "$CP;." TagsGen <repo root>
 */
public class TagsGen {
    static final StringBuilder OUT = new StringBuilder();
    static int lines = 0;

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.US);
        Path root = Path.of(args[0]);
        Path fixtures = root.resolve("Packages/PixlCore/Tests/PixlTagsTests/Fixtures");
        Files.createDirectories(fixtures);
        replayGainStrings();
        volumes();
        ints();
        validation();
        containers();
        flacAnalysis();
        contentTypes();
        Files.writeString(fixtures.resolve("tags-android-golden.jsonl"), OUT.toString(), StandardCharsets.UTF_8);
        System.err.println("tags-android-golden.jsonl: " + lines);
    }

    // ---------------------------------------------------------------- JSON helpers

    static String q(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20 || c > 0x7E) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    static String fbits(Float f) { return f == null ? "null" : q("0x" + Integer.toHexString(Float.floatToRawIntBits(f))); }

    static void line(String fn, String in, String out) {
        OUT.append("{\"fn\":").append(q(fn)).append(",\"in\":").append(in).append(",\"out\":").append(out).append("}\n");
        lines++;
    }

    static Method method(Class<?> c, String prefix) {
        for (Method m : c.getDeclaredMethods()) {
            if (m.getName().equals(prefix) || m.getName().startsWith(prefix + "-")) { m.setAccessible(true); return m; }
        }
        throw new IllegalStateException("no method " + prefix + " in " + c);
    }

    static Object allocate(Class<?> c) throws Exception {
        Field f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Object unsafe = f.get(null);
        return unsafe.getClass().getMethod("allocateInstance", Class.class).invoke(unsafe, c);
    }

    // ---------------------------------------------------------------- ReplayGain strings

    static final String[] GAIN_STRINGS = {
        "-6.54 dB", "+3.21 dB", "-6.54dB", "-6,54 dB", "  -6.54   DB  ", "-6.54 db", "-6.54 Db", "-6.54 dB ",
        "1e2", "0x1p3", "0x1.8P-1", "NaN", "Infinity", "-Infinity", "+Infinity", "nan", "infinity", "", " ", "dB",
        "abc", "1.5f", "1.5d", "1.5F dB", ".5", "5.", "-.5e-1", "1,5", "1,5,5", "1.005", "0.125", "-0.001", "0.005",
        "2.675", "1.115", "-1.115", "99999999999", "1e40", "-1e40", "-1e-50", "3.4028235e38", "3.4028236e38",
        "1.4e-45", "1 dB\n", "1 dB\r\n", "1 d b", "1 D B", "1dbdb", "db1", "d1b", "+", "-", "1e", "0x", "1e+",
        "１２", "١٢", " -3 dB", "-3 dB ", "\t-3\t", "−" + "3 dB", "12.345678 dB",
        "-0", "0", "-0.0", "100", "-12.5 dB gain", "1.0E-5", "123456.789", "0.0049999", "0.015", "0.025", "-0.005",
        "7.775", "-6.535", "-6.545", "0.995", "9.995", "-9.995", "1e-3", "5e-3", "0.00999", "16777217",
        "2.5 dB\u0085", "1 dB ", "1\u0000", "\u0000" + "1", "  +0.00 dB", "-0.00 dB", "-1.23 dB dB", "dB -1",
        "1.5 \t dB", "1.5d B", "-6.54 dB\n\n", "1_000", "1.2.3", "--1", "+-1", "1e5f", "0X1P3", "0x.8p1", "0x1",
        "4.9E-324", "1.7976931348623157E308", "  .  ", "-.e1", "0.30000000000000004", "1.10", "-14.33 dB",
        "-8.20 dB", "6.0 dB", "-0.45 LUFS",
    };

    static void replayGainStrings() throws Exception {
        ReplayGainManager manager = new ReplayGainManager();
        Method parseGain = method(ReplayGainManager.class, "parseGainString");
        Method parseDb = method(AudioMetadataReader.class, "parseReplayGainDb");
        Object editor = allocate(SongMetadataEditor.class);
        Method parseUpdate = method(SongMetadataEditor.class, "parseReplayGainUpdate");
        for (String s : GAIN_STRINGS) {
            line("parseGainString", q(s), fbits((Float) parseGain.invoke(manager, s)));
            line("parseReplayGainDb", q(s), fbits((Float) parseDb.invoke(AudioMetadataReader.INSTANCE, s)));
            line("toFloatOrNull", q(s), fbits(kotlin.text.StringsKt.toFloatOrNull(s)));
            Object r = parseUpdate.invoke(editor, s, "Track ReplayGain");
            line("parseReplayGainUpdate", q(s), describeUpdate(r));
        }
        line("parseReplayGainUpdate", "null", describeUpdate(parseUpdate.invoke(editor, null, "Album ReplayGain")));
        line("parseReplayGainUpdateAlbum", q("x"), describeUpdate(parseUpdate.invoke(editor, "x", "Album ReplayGain")));
    }

    static String describeUpdate(Object r) throws Exception {
        if (r != null && r.getClass().getName().equals("kotlin.Result$Failure")) {
            Field f = r.getClass().getDeclaredField("exception");
            f.setAccessible(true);
            Throwable t = (Throwable) f.get(r);
            return "{\"error\":" + q(t.getMessage()) + "}";
        }
        String name = r.getClass().getSimpleName();
        if (name.equals("Set")) {
            Method m = r.getClass().getMethod("getFormattedValue");
            return "{\"set\":" + q((String) m.invoke(r)) + "}";
        }
        return "{\"" + name.toLowerCase(Locale.ROOT) + "\":true}";
    }

    // ---------------------------------------------------------------- volumes

    static void volumes() {
        ReplayGainManager m = new ReplayGainManager();
        float[] preAmps = {0f, -3f, 2.5f, 6f};
        for (float pre : preAmps) {
            for (int i = 0; i <= 120; i++) {
                float gain = -30f + i * 0.37f;
                line("gainDbToVolume", "[" + fbits(gain) + "," + fbits(pre) + "]", fbits(m.gainDbToVolume(gain, pre)));
            }
        }
        float[] specials = {Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, 0f, -0f, 6.0206f, 6.0207f,
            -200f, 200f, 1e-7f};
        for (float g : specials) line("gainDbToVolume", "[" + fbits(g) + "," + fbits(0f) + "]", fbits(m.gainDbToVolume(g, 0f)));
        Float[][] values = {{null, null}, {-6.5f, null}, {null, -8.2f}, {-6.5f, -8.2f}, {3f, 9f}};
        for (Float[] v : values) {
            for (boolean album : new boolean[]{false, true}) {
                for (float pre : new float[]{0f, -2f}) {
                    ReplayGainManager.ReplayGainValues rv = new ReplayGainManager.ReplayGainValues(v[0], v[1]);
                    line("getVolumeMultiplier", "[" + fbits(v[0]) + "," + fbits(v[1]) + "," + album + "," + fbits(pre) + "]",
                        fbits(m.getVolumeMultiplier(rv, album, pre)));
                }
            }
        }
        line("getVolumeMultiplier", "null", fbits(m.getVolumeMultiplier(null, false, 0f)));
    }

    // ---------------------------------------------------------------- ints

    static void ints() {
        String[] in = {"3", "3/12", "+5", "-0", "007", "2147483647", "2147483648", "-2147483648", "-2147483649", "",
            " 3", "3 ", "1.0", "١٢", "３", "๓", "+", "-", "12a", "0x10", "²", "Ⅳ"};
        for (String s : in) {
            Integer r = kotlin.text.StringsKt.toIntOrNull(s);
            line("toIntOrNull", q(s), r == null ? "null" : r.toString());
        }
    }

    // ---------------------------------------------------------------- validation

    static void validation() throws Exception {
        Object editor = allocate(SongMetadataEditor.class);
        Method v = method(SongMetadataEditor.class, "validateMetadataInput");
        String long500 = "a".repeat(500), long501 = "a".repeat(501), long100 = "g".repeat(100), long101 = "g".repeat(101);
        String emoji250 = "🎵".repeat(250), emoji251 = "🎵".repeat(251);
        String lyrics50k = "l".repeat(50_000), lyrics50k1 = "l".repeat(50_001);
        Object[][] cases = {
            {"Title", "Artist", "Album", null, null, "Pop", null},
            {"", "Artist", "Album", null, null, "Pop", null},
            {"   ", "Artist", "Album", null, null, "Pop", null},
            {"　", "A", "B", null, null, "", null},
            {long500, "A", "B", null, null, "", null},
            {long501, "A", "B", null, null, "", null},
            {emoji250, "A", "B", null, null, "", null},
            {emoji251, "A", "B", null, null, "", null},
            {"T", long501, "B", null, null, "", null},
            {"T", "A", long501, null, null, "", null},
            {"T", "A", "B", long501, null, "", null},
            {"T", "A", "B", " ".repeat(501), null, "", null},
            {"T", "A", "B", null, long501, "", null},
            {"T", "A", "B", null, " ".repeat(600), "", null},
            {"T", "A", "B", null, null, long100, null},
            {"T", "A", "B", null, null, long101, null},
            {"T", "A", "B", null, null, "", lyrics50k},
            {"T", "A", "B", null, null, "", lyrics50k1},
            {long501, long501, long501, long501, long501, long101, lyrics50k1},
            {"T", "", "", "", "", "", ""},
        };
        for (Object[] c : cases) {
            String r = (String) v.invoke(editor, c);
            StringBuilder in = new StringBuilder("[");
            for (int i = 0; i < c.length; i++) {
                if (i > 0) in.append(',');
                in.append(compact((String) c[i]));
            }
            line("validateMetadataInput", in.append(']').toString(), q(r));
        }
    }

    /** Long repeated strings as {"repeat": unit, "count": n} to keep the fixture small. */
    static String compact(String s) {
        if (s == null) return "null";
        if (s.length() > 40) {
            int unitLen = Character.charCount(s.codePointAt(0));
            String unit = s.substring(0, unitLen);
            if (unit.repeat(s.length() / unitLen).equals(s)) {
                return "{\"repeat\":" + q(unit) + ",\"count\":" + (s.length() / unitLen) + "}";
            }
        }
        return q(s);
    }

    // ---------------------------------------------------------------- containers

    static byte[] hex(String h) {
        h = h.replace(" ", "");
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    static String toHex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x & 0xFF));
        return s.toString();
    }

    static byte[] ogg(String packetStart, int segments) {
        byte[] b = new byte[27 + segments + packetStart.length() / 2 + 4];
        byte[] magic = "OggS".getBytes(StandardCharsets.US_ASCII);
        System.arraycopy(magic, 0, b, 0, 4);
        b[26] = (byte) segments;
        byte[] p = hex(packetStart);
        System.arraycopy(p, 0, b, 27 + segments, p.length);
        return b;
    }

    static void containers() throws Exception {
        Object editor = allocate(SongMetadataEditor.class);
        Method detect = method(SongMetadataEditor.class, "detectContainerFormat");
        List<byte[]> inputs = new ArrayList<>();
        inputs.add(hex("494433040000000000"));
        inputs.add(hex("4944"));
        inputs.add(hex("494433"));
        inputs.add(hex("49443300"));
        inputs.add(hex("FFFB9064"));
        inputs.add(hex("FFE00000"));
        inputs.add(hex("FFD8FFE0"));
        inputs.add(hex("FF1F0000"));
        inputs.add(hex("000000206674797069736F6D"));
        inputs.add(hex("00000020667479"));
        inputs.add(hex("0000001C667479704D344120"));
        inputs.add(hex("664C614300000022"));
        inputs.add(hex("664C6143"));
        inputs.add(ogg("4F707573486561640102", 1));
        inputs.add(ogg("01766F72626973000000", 1));
        inputs.add(ogg("807468656F7261", 1));
        inputs.add(ogg("4F707573486561640102", 3));
        inputs.add(hex("4F67675300020000"));
        byte[] shortOgg = ogg("4F707573", 1);
        inputs.add(java.util.Arrays.copyOf(shortOgg, 28));
        byte[] tooManySegments = new byte[40];
        System.arraycopy("OggS".getBytes(StandardCharsets.US_ASCII), 0, tooManySegments, 0, 4);
        tooManySegments[26] = (byte) 200;
        inputs.add(tooManySegments);
        inputs.add(hex("52494646240000005741564566"));
        inputs.add(hex("524946462400000041564920"));
        inputs.add(hex("5249464624000000574156"));
        inputs.add(hex("000102"));
        inputs.add(new byte[0]);
        inputs.add(hex("0001020304050607"));
        inputs.add("#EXTM3U\n".getBytes(StandardCharsets.US_ASCII));
        for (byte[] in : inputs) {
            File f = File.createTempFile("tagsgen", ".bin");
            Files.write(f.toPath(), in);
            Object r = detect.invoke(editor, f.getAbsolutePath());
            f.delete();
            line("detectContainerFormat", q(toHex(in)), q(r.toString()));
        }
    }

    static byte[] streamInfoHeader(int sampleRate, int bits, int channels) {
        byte[] b = new byte[42];
        System.arraycopy("fLaC".getBytes(StandardCharsets.US_ASCII), 0, b, 0, 4);
        b[4] = (byte) 0x80; b[7] = 34;
        int base = 8;
        b[base + 10] = (byte) (sampleRate >> 12);
        b[base + 11] = (byte) (sampleRate >> 4);
        b[base + 12] = (byte) (((sampleRate & 0xF) << 4) | (((channels - 1) & 7) << 1) | (((bits - 1) >> 4) & 1));
        b[base + 13] = (byte) (((bits - 1) & 0xF) << 4);
        return b;
    }

    static void flacAnalysis() throws Exception {
        Object editor = allocate(SongMetadataEditor.class);
        Method m = method(SongMetadataEditor.class, "isProblematicFlacFile");
        int[][] formats = {{44100, 16, 2}, {48000, 24, 2}, {96000, 24, 2}, {96001, 16, 1}, {176400, 24, 2},
            {192000, 32, 8}, {44100, 25, 2}, {8000, 8, 1}, {655350, 32, 2}, {1, 4, 1}};
        for (String ext : new String[]{".flac", ".FLAC", ".mp3"}) {
            for (int[] f : formats) {
                byte[] b = streamInfoHeader(f[0], f[1], f[2]);
                File file = File.createTempFile("tagsgen", ext);
                Files.write(file.toPath(), b);
                Object r = m.invoke(editor, file.getAbsolutePath());
                file.delete();
                line("isProblematicFlacFile", "[" + q(ext.substring(1)) + "," + q(toHex(b)) + "]", q(describeFlac(r)));
            }
        }
        byte[] notFlac = streamInfoHeader(44100, 16, 2);
        notFlac[0] = 'F';
        byte[] shortFile = java.util.Arrays.copyOf(streamInfoHeader(44100, 16, 2), 41);
        for (byte[] b : new byte[][]{notFlac, shortFile}) {
            File file = File.createTempFile("tagsgen", ".flac");
            Files.write(file.toPath(), b);
            Object r = m.invoke(editor, file.getAbsolutePath());
            file.delete();
            line("isProblematicFlacFile", "[\"flac\"," + q(toHex(b)) + "]", q(describeFlac(r)));
        }
    }

    static String describeFlac(Object r) {
        String name = r.getClass().getSimpleName();
        if (name.equals("NotFlac") || name.equals("Unknown")) return name;
        return r.toString();
    }

    // ---------------------------------------------------------------- content types

    static void contentTypes() throws Exception {
        String[] in = {
            "FFD8FFE000104A46494600", "FFD8FFEE", "FFD8FFE10000457869660000", "FFD8FFE10000457869660100",
            "FFD8FFDB0043", "FFD8FFE1", "89504E470D0A1A0A0000", "89504E470D0A1A", "4749463839610100", "47494638",
            "474946", "52494646000000005745425056503820", "424D3A000000", "49492A00", "4D4D002A", "2E736E64", "646E732E",
            "CAFEBABE", "ACED0005", "3C21444F43", "3C68746D6C3E", "3C484541443E", "3C626F6479", "3C3F786D6C20",
            "3C3F786D6C3F", "EFBBBF3C3F786D6C", "FEFF003C003F0078", "FFFE3C003F007800", "0000FEFF0000003C0000003F00000078",
            "FFFE00003C0000003F00000078000000", "2364656600", "2120585049324", "D0CF11E0A1B11AE1", "", "00", "0000000C6A502020",
            "000000186674797068656963",
        };
        for (String h : in) {
            byte[] b = hex(h.length() % 2 == 0 ? h : h.substring(0, h.length() - 1));
            String r = URLConnection.guessContentTypeFromStream(new ByteArrayInputStream(b));
            line("guessContentTypeFromStream", q(toHex(b)), q(r));
        }
    }
}
