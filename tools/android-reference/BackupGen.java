import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.google.gson.JsonPrimitive;
import com.google.gson.reflect.TypeToken;
import com.theveloper.pixelplay.data.backup.PlaybackHistoryBackupEntry;
import com.theveloper.pixelplay.data.backup.format.BackupFormatDetector;
import com.theveloper.pixelplay.data.backup.format.LegacyPayloadAdapter;
import com.theveloper.pixelplay.data.backup.model.ArtistImageBackupEntry;
import com.theveloper.pixelplay.data.backup.model.BackupManifest;
import com.theveloper.pixelplay.data.backup.model.BackupModuleInfo;
import com.theveloper.pixelplay.data.backup.model.BackupSection;
import com.theveloper.pixelplay.data.backup.model.BackupValidationResult;
import com.theveloper.pixelplay.data.backup.model.DeviceInfo;
import com.theveloper.pixelplay.data.backup.model.ValidationError;
import com.theveloper.pixelplay.data.backup.module.EngagementStatsModuleHandler;
import com.theveloper.pixelplay.data.backup.module.PlaylistsModuleHandler;
import com.theveloper.pixelplay.data.backup.validation.ContentSanitizer;
import com.theveloper.pixelplay.data.backup.validation.ManifestValidator;
import com.theveloper.pixelplay.data.backup.validation.ModuleSchemaValidator;
import com.theveloper.pixelplay.data.database.AiUsageEntity;
import com.theveloper.pixelplay.data.database.FavoritesEntity;
import com.theveloper.pixelplay.data.database.LyricsEntity;
import com.theveloper.pixelplay.data.database.SearchHistoryEntity;
import com.theveloper.pixelplay.data.database.SongEngagementEntity;
import com.theveloper.pixelplay.data.database.SongSummary;
import com.theveloper.pixelplay.data.database.TransitionRuleEntity;
import com.theveloper.pixelplay.data.model.Curve;
import com.theveloper.pixelplay.data.model.Playlist;
import com.theveloper.pixelplay.data.model.TransitionMode;
import com.theveloper.pixelplay.data.model.TransitionSettings;
import com.theveloper.pixelplay.data.preferences.PreferenceBackupEntry;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.ByteArrayInputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Type;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.zip.CRC32;
import java.util.zip.Deflater;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

/**
 * Golden vectors and binary fixtures for PixlBackup (stage 3e). Runs the Android app's compiled backup classes
 * (format detector, legacy adapter, sanitizer, manifest/module validators, the Gson entity decoding of every
 * module, the engagement merge and the playlist song resolver) on a desktop JVM, and builds .pxpl files the way
 * the Android writers do (BackupWriter: PXPL + ZipOutputStream/DEFLATED with data descriptors; the legacy
 * AppDataBackupManager: PXPL + GZIPOutputStream over pretty-printed Gson).
 *
 * Writes into Packages/PixlCore/Tests/PixlBackupTests/Fixtures/: backup-android-golden.jsonl (one
 * {"fn","in","out"} object per line), inflate-cases.jsonl, android-v3.pxpl, android-v2-legacy.pxpl,
 * android-v1-legacy.json.gz, android-v1-legacy.json.
 *
 * Classpath (Windows separators): the app's compileDebugKotlin/classes, its debug R.jar
 * (compile_and_runtime_r_class_jar), android.jar (platforms/android-37.0), kotlin-stdlib 2.4.0,
 * kotlinx-coroutines-core-jvm 1.10.2, kotlinx-serialization-{core,json}-jvm 1.11.0, gson 2.14.0.
 *   javac -cp "$CP" -d out BackupGen.java
 *   java -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote -cp "$CP;out" BackupGen <repo root>
 */
public class BackupGen {
    static final Gson OUT = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    static final Gson BACKUP = new GsonBuilder().setPrettyPrinting().serializeNulls().create();
    static final Gson PLAIN = new Gson();
    static final List<String> lines = new ArrayList<>();
    static Path fixtures;

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.US);
        fixtures = Path.of(args[0]).resolve("Packages/PixlCore/Tests/PixlBackupTests/Fixtures");
        Files.createDirectories(fixtures);
        detect();
        sanitizer();
        schema();
        manifest();
        legacy();
        entities();
        engagement();
        resolver();
        gsonWriter();
        containers();
        StringBuilder sb = new StringBuilder();
        for (String l : lines) sb.append(l).append('\n');
        Files.writeString(fixtures.resolve("backup-android-golden.jsonl"), sb.toString(), StandardCharsets.UTF_8);
        System.err.println("golden lines: " + lines.size());
        inflate();
    }

    // ------------------------------------------------------------------ helpers

    static void line(String fn, JsonElement in, JsonElement out) {
        JsonObject o = new JsonObject();
        o.addProperty("fn", fn);
        o.add("in", in);
        o.add("out", out);
        lines.add(OUT.toJson(o));
    }

    static JsonElement s(String v) { return v == null ? JsonNull.INSTANCE : new JsonPrimitive(v); }

    static JsonObject obj(Object... kv) {
        JsonObject o = new JsonObject();
        for (int i = 0; i < kv.length; i += 2) {
            Object v = kv[i + 1];
            if (v instanceof JsonElement e) o.add((String) kv[i], e);
            else if (v instanceof String str) o.addProperty((String) kv[i], str);
            else if (v instanceof Number n) o.addProperty((String) kv[i], n);
            else if (v instanceof Boolean b) o.addProperty((String) kv[i], b);
            else o.add((String) kv[i], JsonNull.INSTANCE);
        }
        return o;
    }

    static JsonElement thrown(Throwable t) {
        while (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null) t = t.getCause();
        return obj("throw", t.getClass().getSimpleName());
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x));
        return sb.toString();
    }

    static String sha256(byte[] data) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(data));
    }

    static JsonElement validation(BackupValidationResult r) {
        JsonArray errors = new JsonArray();
        if (r instanceof BackupValidationResult.Invalid inv) {
            for (ValidationError e : inv.getErrors()) {
                errors.add(obj("code", e.getCode(), "message", e.getMessage(), "module", s(e.getModule()),
                    "severity", e.getSeverity().name()));
            }
        }
        return obj("valid", r instanceof BackupValidationResult.Valid, "errors", errors);
    }

    static Object allocate(Class<?> c) throws Exception {
        Field f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Object unsafe = f.get(null);
        return unsafe.getClass().getMethod("allocateInstance", Class.class).invoke(unsafe, c);
    }

    // ------------------------------------------------------------------ format detector

    static void detect() {
        BackupFormatDetector d = new BackupFormatDetector();
        String[] headers = {
            "", "50", "5058", "505850", "5058504c", "5058504c50", "5058504c504b", "5058504c504b03",
            "5058504c504b0304", "5058504c1f8b0800", "5058504c1f8b08", "5058504c00000000", "5058504c7b226122",
            "1f8b080000000000", "1f8b", "1f", "7b20226672", "7b", "7b7d", "0001020304050607", "504b030414000800",
            "5b5d", "efbbbf7b", "5078504c504b0304", "5058504c504c504b", "5058504c1f8a0800",
        };
        for (String h : headers) {
            byte[] b = new byte[h.length() / 2];
            for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
            line("detect", s(h), s(d.detect(b).name()));
        }
    }

    // ------------------------------------------------------------------ sanitizer

    static void sanitizer() {
        ContentSanitizer c = new ContentSanitizer();
        String[] strings = {
            "", "  hello  ", "\t\n tabbed \r\n", "Hello\tWorld\n\u0000\u0001\u0002Test", "\u007fdel\u007f",
            "\u000b\u000cvt-ff\u000e\u001f", "  \u0001  ", "\u00a0nbsp\u00a0", "\u2003em space\u2003", "\u3000ideo\u3000",
            "mixed \u0000 inner \u0008 controls", "caf\u00e9 \ud83c\udfb5 emoji", "\u0085next line\u0085", "\u001c\u001d\u001e\u001f",
            "x".repeat(20), "line1\r\nline2", "\u200bzero width\u200b",
        };
        int[] maxes = {10_000, 5, 1, 0, 3};
        for (String str : strings) {
            for (int m : maxes) {
                line("sanitizeString", obj("s", str, "max", m), s(c.sanitizeString(str, m)));
            }
        }
        line("sanitizeString", obj("s", "a".repeat(2000), "max", 100), s(c.sanitizeString("a".repeat(2000), 100)));
        line("sanitizeString", obj("s", "\u0001" + "b".repeat(12), "max", 10), s(c.sanitizeString("\u0001" + "b".repeat(12), 10)));
        String[] urls = {
            "https://cdn.example.com/image.jpg", "http://example.com/image.jpg", "ftp://files.example.com/image.jpg",
            "", "   ", "  https://padded.example.com/x  ", "HTTPS://upper.example.com", "javascript:alert(1)",
            "https://example.com/" + "a".repeat(3000), "content://media/external/1", "https:/broken", "http://",
            "\u0001https://ctrl.example.com", "https://ex\u0000ample.com",
        };
        for (String u : urls) {
            line("sanitizeUrl", obj("s", u, "max", 2000), s(c.sanitizeUrl(u, 2000)));
            line("sanitizeUrl", obj("s", u, "max", 12), s(c.sanitizeUrl(u, 12)));
        }
        String[] keys = {
            "playlists", "global_settings", "favorites", "quick_fill", "artist_images", "equalizer", "ai_usage_logs",
            "", "../path_traversal", "UPPERCASE", "has spaces", "has-dashes", "a".repeat(50), "a".repeat(51), "_", "__",
            "digits1", "caf\u00e9", "tab\t", "x\n", "\u00e9",
        };
        for (String k : keys) line("isValidModuleKey", s(k), new JsonPrimitive(c.isValidModuleKey(k)));
    }

    // ------------------------------------------------------------------ module schema validator

    static void schema() {
        ModuleSchemaValidator v = new ModuleSchemaValidator(new ContentSanitizer());
        Map<String, String[]> cases = new LinkedHashMap<>();
        cases.put("favorites", new String[] {
            "[{\"songId\": 123, \"addedAt\": 1700000000000}]", "not valid json{", "{\"key\": \"value\"}",
            "[{\"songId\": 0, \"addedAt\": 1700000000000}]", "[{\"song_id\": \"123\", \"added_at\": 1700000000000}]", "[]",
            "", "   ", "null", "123", "\"str\"", "[1, \"x\", null, [], {}]", "[{\"songId\": -5}]", "[{\"songId\": \"abc\"}]",
            "[{\"songId\": \"12.5\"}]", "[{\"songId\": 12.5}]", "[{\"songId\": 1e3}]", "[{\"songId\": true}]",
            "[{\"songId\": null}]", "[{\"songId\": [1]}]", "[{\"songId\": {}}]", "[{}]", "[{\"song_id\": 7, \"songId\": 0}]",
            "[{\"songId\": 0, \"song_id\": 7}]", "[{\"songId\": 99999999999999999999}]", "[{\"songId\": \" 12\"}]",
            "[{\"songId\": \"0x10\"}]", "[{\"songId\": \"+5\"}]", "[{\"songId\": 1.0}]", "[{\"songId\":1}] trailing",
            "[{\"songId\":1}]  \n", "[{\"songId\": 9223372036854775807}]", "[{\"songId\": 9223372036854775808}]",
            "[{\"songId\": -0}]", "[{\"songId\": 1E2}]", "[{\"songId\": 0.5}]",
        });
        cases.put("lyrics", new String[] {
            "[{\"songId\": 1, \"content\": \"[00:01.00]hi\", \"isSynced\": true}]", "[{\"content\": null}]",
            "[{\"content\": 123}]", "[{\"content\": \"" + "x".repeat(50_001) + "\"}]",
            "[{\"content\": \"" + "x".repeat(50_000) + "\"}]", "[{\"content\": {}}]", "[{\"content\": [\"a\"]}]",
            "[{\"content\": [\"a\", \"b\"]}]", "[\"x\", {\"jsonFile\": \"abc.json\", \"json\": \"{}\"}]", "{}",
            "[{\"content\": true}]",
        });
        cases.put("search_history", new String[] {
            "[{\"id\": 1, \"query\": \"rock\", \"timestamp\": 5}]", "[{\"query\": \"" + "q".repeat(501) + "\"}]",
            "[{\"query\": \"" + "q".repeat(500) + "\"}]", "[{\"query\": null}]", "[{\"query\": 5}]", "[{\"query\": {}}]",
            "[{}]",
        });
        cases.put("engagement_stats", new String[] {
            "[{\"songId\": \"123\", \"playCount\": -1, \"totalDuration\": 0}]",
            "[{\"playCount\": \"oops\", \"totalDuration\": -5, \"lastPlayedTimestamp\": \"bad\"}]",
            "[{\"songId\": \"123\", \"playCount\": 1}, {\"songId\": \"123\", \"playCount\": 2}]",
            "[1, \"x\", null]", "[{\"song_id\": 42, \"play_count\": \"7\"}]", "[{\"songId\": \"  \"}]",
            "[{\"songId\": \" a \"}, {\"songId\": \"a\"}]", "[{\"songId\": null, \"song_id\": \"z\"}]",
            "[{\"songId\": {}, \"song_id\": \"z\"}]", "[{\"songId\": \"s\", \"playCount\": true}]",
            "[{\"songId\": \"s\", \"playCount\": null, \"play_count\": -3}]", "[{\"songId\": \"s\", \"score\": 5.9}]",
            "[{\"songId\": \"s\", \"plays\": \"5.9\"}]", "[{\"songId\": \"s\", \"duration_ms\": [1]}]",
            "[{\"songId\": \"s\", \"timestamp\": -1}]", "[{\"songId\": \"s\", \"last_played_at\": \"-1\"}]",
            "[{\"songId\": \"s\", \"playCount\": 1e2, \"totalPlayDurationMs\": 2.5e3}]", "[{\"songId\": true}]",
            "[{\"songId\": 12.0}]", "[{\"songId\": \"s\", \"playCount\": 99999999999999999999}]",
            "[{\"songId\": \"s\", \"playCount\": \"\"}]",
        });
        cases.put("playback_history", new String[] {
            "[{\"songId\": \"123\", \"timestamp\": 1700000000000, \"durationMs\": -500}]",
            "[{\"songId\": \"1\", \"durationMs\": 5}]", "[{\"durationMs\": \"-3\"}]", "[{\"durationMs\": \"abc\"}]",
            "[{\"durationMs\": null}]", "[{\"durationMs\": {}}]", "[{\"durationMs\": [-1]}]", "[{\"durationMs\": [1, 2]}]",
            "[{\"durationMs\": -0.5}]", "[{\"durationMs\": -1.5}]", "[{\"durationMs\": true}]", "[{}]",
        });
        cases.put("artist_images", new String[] {
            "[{\"artistName\": \"Test\", \"imageUrl\": \"http://insecure.com/img.jpg\"}]",
            "[{\"artistName\": \"Test\", \"imageUrl\": \"https://cdn.example.com/img.jpg\"}]",
            "[{\"imageUrl\": \"https://x.com/" + "a".repeat(2000) + "\"}]", "[{\"imageUrl\": \"ftp://" + "b".repeat(2000) + "\"}]",
            "[{\"imageUrl\": \"\"}]", "[{\"imageUrl\": null}]", "[{\"imageUrl\": 5}]", "[{\"imageUrl\": {}}]",
        });
        cases.put("transitions", new String[] {
            "[{\"fromSongId\": \"1\", \"toSongId\": \"2\", \"settings\": {\"durationMs\": 50000}}]",
            "[{\"settings\": {\"durationMs\": 30000}}]", "[{\"settings\": {\"durationMs\": -1}}]",
            "[{\"settings\": {\"durationMs\": \"40000\"}}]", "[{\"settings\": {\"durationMs\": \"x\"}}]",
            "[{\"settings\": null}]", "[{\"settings\": []}]", "[{\"settings\": {}}]", "[{\"settings\": {\"durationMs\": 3000000000}}]",
            "[{\"settings\": {\"durationMs\": 1.5}}]", "[{\"settings\": {\"durationMs\": null}}]",
        });
        cases.put("global_settings", new String[] {
            "[{\"key\": \"theme\", \"type\": \"string\", \"stringValue\": \"dark\"}, {\"key\": \"count\", \"type\": \"int\", \"intValue\": 5}, {\"key\": \"enabled\", \"type\": \"boolean\", \"booleanValue\": true}]",
            "[{\"key\": \"theme\", \"type\": \"invalid_type\", \"stringValue\": \"dark\"}]", "[{\"type\": \"string\"}]",
            "[{\"key\": \"  \", \"type\": \"long\"}]", "[{\"key\": \"k\"}]", "[{\"key\": \"k\", \"type\": null}]",
            "[{\"key\": 5, \"type\": \"float\"}]", "[{\"key\": \"k\", \"type\": \"STRING\"}]", "[{\"key\": {}, \"type\": \"int\"}]",
            "[\"x\", 1]", "{\"key\": \"k\"}", "[{\"key\": \"k\", \"type\": \"double\"}, {\"key\": \"s\", \"type\": \"string_set\"}]",
        });
        cases.put("quick_fill", new String[] {
            "[{\"key\": \"custom_genres\", \"type\": \"string_set\", \"stringSetValue\": [\"A\"]}]", "{\"a\": 1}", "\"str\"",
            "[{\"key\": \"custom_genres\", \"type\": \"bogus\"}]",
        });
        cases.put("equalizer", new String[] {
            "[{\"key\": \"custom_presets_json\", \"type\": \"string\", \"stringValue\": \"[]\"}]", "{}", "5",
            "[{\"type\": \"string\"}]",
        });
        cases.put("ai_usage_logs", new String[] {
            "[{\"id\": 1, \"timestamp\": 5, \"provider\": \"GEMINI\"}]", "{}", "[1, 2]",
        });
        cases.put("playlists", new String[] {
            "{\"playlists\": [{\"id\": \"p1\", \"name\": \"One\", \"songIds\": []}], \"playlistsSortOption\": \"name_az\"}",
            "{\"playlists\": [{\"id\": \"\", \"name\": \" \"}, 5, {\"id\": 7, \"name\": true}]}", "{\"playlists\": null}",
            "{\"playlists\": {}}", "{}", "[{\"key\": \"user_playlists_json_v1\", \"type\": \"string\", \"stringValue\": \"[]\"}]",
            "[{\"key\": \"x\", \"type\": \"nope\"}]", "\"str\"", "5", "null", "",
            "{\"playlistsSortOption\": \"" + "s".repeat(201) + "\"}", "{\"playlistsSortOption\": \"" + "s".repeat(200) + "\"}",
            "{\"playlistsSortOption\": 5}", "{\"playlistsSortOption\": {}}", "{\"playlists\": [{\"id\": {}}]}",
            "{\"playlists\": [{\"id\": null, \"name\": null}]}", "{\"playlists\": [[]]}",
        });
        for (Map.Entry<String, String[]> e : cases.entrySet()) {
            BackupSection section = BackupSection.Companion.fromKey(e.getKey());
            for (String payload : e.getValue()) {
                JsonElement out;
                try {
                    out = validation(v.validate(section, payload));
                } catch (Throwable t) {
                    out = thrown(t);
                }
                line("schema", obj("section", e.getKey(), "payload", payload), out);
            }
        }
    }

    // ------------------------------------------------------------------ manifest

    static void manifest() throws Exception {
        ManifestValidator mv = new ManifestValidator();
        long now = System.currentTimeMillis();
        long[] created = {now, now + 86_400_000L * 2, now - 86_400_000L * 400, 1_000_000_000_000L, 1_700_000_000_000L,
            1_699_999_999_999L, now + 3_600_000L, 0L, -5L};
        int[] versions = {0, 1, 2, 3, 4, 99, -1};
        String[][] moduleSets = {{}, {"playlists"}, {"unknown_module_xyz"}, {"favorites", "lyrics", "x", "ai_usage_logs"}};
        for (long c : created) {
            for (int ver : versions) {
                for (String[] mods : moduleSets) {
                    Map<String, BackupModuleInfo> m = new LinkedHashMap<>();
                    for (String k : mods) m.put(k, new BackupModuleInfo("sha256:abc", 1, 10));
                    BackupManifest manifest = new BackupManifest(ver, "1.0", 1, c, new DeviceInfo("", "", 0), m);
                    JsonObject in = obj("schemaVersion", ver, "createdAt", c, "now", now);
                    JsonArray keys = new JsonArray();
                    for (String k : mods) keys.add(k);
                    in.add("modules", keys);
                    line("manifestValidate", in, validation(mv.validate(manifest)));
                }
            }
        }
        // checksum verification
        String[][] checks = {
            {"[{\"songId\": 123}]", "match"}, {"[{\"songId\": 999}]", "sha256:0000000000000000000000000000000000000000000000000000000000000000"},
            {"any payload", null}, {"x", ""}, {"x", "md5:abc"}, {"caf\u00e9 \ud83c\udfb5", "match"}, {"", "match"},
            {"x", "SHA256:abc"}, {"abc", "sha256:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"},
        };
        for (String[] c : checks) {
            Map<String, BackupModuleInfo> m = new LinkedHashMap<>();
            String checksum = c[1];
            if ("match".equals(checksum)) checksum = "sha256:" + sha256(c[0].getBytes(StandardCharsets.UTF_8));
            if (checksum != null) m.put("favorites", new BackupModuleInfo(checksum, 1, 1));
            BackupManifest manifest = new BackupManifest(3, "", 0, 0, new DeviceInfo("", "", 0), m);
            line("verifyChecksum", obj("payload", c[0], "checksum", s(checksum)),
                new JsonPrimitive(mv.verifyChecksum("favorites", c[0], manifest)));
        }
        // Gson decoding of manifest.json, re-encoded with the backup Gson
        String[] manifests = {
            "{\"schemaVersion\":3,\"appVersion\":\"0.6.0\",\"appVersionCode\":60,\"createdAt\":1759000000000,\"deviceInfo\":{\"manufacturer\":\"Google\",\"model\":\"Pixel 9\",\"androidVersion\":36},\"modules\":{\"favorites\":{\"checksum\":\"sha256:ab\",\"entryCount\":2,\"sizeBytes\":40}}}",
            "{}", "{\"schemaVersion\":\"3\",\"createdAt\":\"1759000000000\"}", "{\"schemaVersion\":3.0}", "{\"schemaVersion\":3.5}",
            "{\"appVersion\":5,\"appVersionCode\":\"7\"}", "{\"appVersion\":null,\"deviceInfo\":null}", "{\"modules\":{}}",
            "{\"modules\":{\"a\":{},\"b\":{\"checksum\":null,\"entryCount\":\"3\",\"sizeBytes\":1e3}}}",
            "{\"unknown\":[1,2,{\"x\":null}],\"schemaVersion\":2}", "{\"schemaVersion\":true}", "[]", "null", "",
            "{\"modules\":[]}", "{\"modules\":{\"a\":{\"entryCount\":1.5}}}", "{\"createdAt\":1.759E12}",
            "{\"deviceInfo\":{\"androidVersion\":\"x\"}}", "{\"schemaVersion\":3,\"schemaVersion\":4}",
            "{\"modules\":{\"a\":{\"checksum\":\"x\"},\"a\":{\"checksum\":\"y\"}}}", "{\"appVersion\":true}",
            "{\"appVersion\":{\"x\":1}}", "{\"schemaVersion\":2147483648}", "{\"createdAt\":9223372036854775808}",
            "{\"appVersion\":\"<b>&'=\\u2028\"}", "{\"modules\":null}",
        };
        for (String json : manifests) {
            JsonElement out;
            try {
                BackupManifest m = PLAIN.fromJson(json, BackupManifest.class);
                out = s(m == null ? "null" : BACKUP.toJson(m));
            } catch (Throwable t) {
                out = thrown(t);
            }
            line("manifestDecode", s(json), out);
        }
    }

    // ------------------------------------------------------------------ legacy adapter

    static void legacy() {
        LegacyPayloadAdapter adapter = new LegacyPayloadAdapter();
        String[] inputs = {
            "{\"formatVersion\": 2, \"exportedAtEpochMs\": 1700000000000, \"availableSections\": [\"playlists\", \"global_settings\", \"favorites\"], \"playlists\": [{\"key\": \"user_playlists_json_v1\", \"type\": \"string\", \"stringValue\": \"[]\"}], \"globalSettings\": [{\"key\": \"app_theme\", \"type\": \"string\", \"stringValue\": \"dark\"}], \"favorites\": [{\"songId\": 123, \"addedAt\": 1700000000000}]}",
            "{\"formatVersion\": 1, \"exportedAtEpochMs\": 1600000000000, \"availableSections\": [\"playlists\", \"global_settings\"], \"preferences\": [{\"key\": \"user_playlists_json_v1\", \"type\": \"string\", \"stringValue\": \"[]\"}, {\"key\": \"app_theme\", \"type\": \"string\", \"stringValue\": \"dark\"}, {\"key\": \"crossfade_duration\", \"type\": \"int\", \"intValue\": 6000}]}",
            "{\"formatVersion\": 2, \"exportedAtEpochMs\": 1700000000000, \"availableSections\": [\"favorites\"], \"playlists\": [{\"key\": \"user_playlists_json_v1\", \"type\": \"string\", \"stringValue\": \"[]\"}], \"favorites\": [{\"songId\": 123}]}",
            "{\"formatVersion\": 2, \"exportedAtEpochMs\": 1700000000000, \"availableSections\": []}",
            "{}", "{\"availableSections\": [\"favorites\"], \"favorites\": [{\"songId\": 1, \"note\": \"<&>\", \"n\": null, \"f\": 1.50, \"e\": 1e2}]}",
            "{\"formatVersion\": \"2\", \"exportedAtEpochMs\": \"5\", \"availableSections\": [\"lyrics\", \"search_history\", \"transitions\", \"engagement_stats\", \"playback_history\"], \"lyrics\": [{\"songId\": 1, \"content\": \"x\"}], \"searchHistory\": [{\"query\": \"q\"}], \"transitions\": [{\"playlistId\": \"p\"}], \"engagementStats\": [{\"songId\": \"s\"}], \"playbackHistory\": [{\"songId\": \"s\", \"timestamp\": 1, \"durationMs\": 2}]}",
            "{\"formatVersion\": 1, \"availableSections\": [\"global_settings\"], \"preferences\": [{\"key\": \"playlists_sort_option\", \"type\": \"string\"}, {\"type\": \"int\"}]}",
            "{\"formatVersion\": 1, \"availableSections\": [\"playlists\"], \"preferences\": []}",
            "{\"formatVersion\": 1, \"availableSections\": [\"playlists\", \"global_settings\"], \"preferences\": [\"x\"]}",
            "{\"formatVersion\": 3, \"availableSections\": [\"favorites\"], \"favorites\": []}",
            "{\"formatVersion\": 2, \"availableSections\": [\"favorites\"], \"favorites\": {}}",
            "{\"formatVersion\": 2, \"availableSections\": \"favorites\"}", "[]", "not json",
            "{\"formatVersion\": 2, \"availableSections\": [\"favorites\", \"favorites\"], \"favorites\": [1, [2, {\"a\": []}], {}]}",
            "{\"formatVersion\": 2, \"availableSections\": [5], \"favorites\": [1]}",
            "{\"formatVersion\": 1.0, \"availableSections\": [\"global_settings\"], \"globalSettings\": [{\"key\": \"a\"}]}",
            "{\"formatVersion\": 2, \"availableSections\": [\"favorites\"], \"favorites\": [\"caf\u00e9 \ud83c\udfb5 \\u00e9 \\\"q\\\" \\/ \\u0001\"]}",
            "{\"formatVersion\": null, \"availableSections\": null}",
        };
        for (String json : inputs) {
            JsonElement out;
            try {
                kotlin.Pair<BackupManifest, Map<String, String>> r = adapter.adapt(json, BACKUP);
                JsonObject modules = new JsonObject();
                for (Map.Entry<String, String> e : r.getSecond().entrySet()) modules.addProperty(e.getKey(), e.getValue());
                out = obj("manifest", BACKUP.toJson(stableCreatedAt(r.getFirst())), "modules", modules);
            } catch (Throwable t) {
                out = thrown(t);
            }
            line("legacyAdapt", s(json), out);
        }
    }

    static BackupManifest stableCreatedAt(BackupManifest m) { return m; }

    // ------------------------------------------------------------------ Gson entity decoding

    static Class<?> payloadClass() throws Exception {
        return Class.forName("com.theveloper.pixelplay.data.backup.module.PlaylistsModuleHandler$PlaylistsBackupPayload");
    }

    static void entities() throws Exception {
        Map<String, Type> types = new LinkedHashMap<>();
        types.put("favorites", TypeToken.getParameterized(List.class, FavoritesEntity.class).getType());
        types.put("lyrics", TypeToken.getParameterized(List.class, LyricsEntity.class).getType());
        types.put("search_history", TypeToken.getParameterized(List.class, SearchHistoryEntity.class).getType());
        types.put("transitions", TypeToken.getParameterized(List.class, TransitionRuleEntity.class).getType());
        types.put("playback_history", TypeToken.getParameterized(List.class, PlaybackHistoryBackupEntry.class).getType());
        types.put("ai_usage_logs", TypeToken.getParameterized(List.class, AiUsageEntity.class).getType());
        types.put("artist_images", TypeToken.getParameterized(List.class, ArtistImageBackupEntry.class).getType());
        types.put("preferences", TypeToken.getParameterized(List.class, PreferenceBackupEntry.class).getType());
        types.put("playlist_list", TypeToken.getParameterized(List.class, Playlist.class).getType());
        types.put("playlists_payload", payloadClass());
        types.put("order_modes", TypeToken.getParameterized(Map.class, String.class, String.class).getType());

        Map<String, String[]> cases = new LinkedHashMap<>();
        cases.put("favorites", new String[] {
            "[{\"song_id\": 123, \"is_favorite\": true, \"added_at\": 1700000000000}]", "[{\"songId\": 5}]", "[]", "",
            "[{\"songId\": \"12\", \"isFavorite\": \"TRUE\", \"timestamp\": \"7\"}]", "[{\"songId\": \"x\"}]",
            "[{\"songId\": 1.5}]", "[{\"songId\": 2.0, \"isFavorite\": \"no\"}]", "[{\"songId\": 1e3}]", "[{\"songId\": null}]",
            "[null]", "[\"bad\"]", "[{\"songId\": 1, \"isFavorite\": 1}]", "[{\"songId\": 1, \"timestamp\": null}]",
            "[{\"song_id\": 3, \"songId\": 4}]", "[{\"songId\": 4, \"song_id\": 3}]", "{}", "[{\"songId\": 1, \"extra\": {\"a\": [1]}}]",
            "[{\"songId\": 9223372036854775807}]", "[{\"songId\": 9223372036854775808}]", "[{\"songId\": true}]",
            "[{\"songId\": [5]}]", "[{\"songId\": \"\"}]", "[{\"songId\": \" 5\"}]", "[{\"songId\": \"5.0\"}]",
            "[{\"songId\": -7, \"isFavorite\": false, \"timestamp\": -1}]", "null", "[{\"songId\": 1, \"timestamp\": 1.0E12}]",
        });
        cases.put("lyrics", new String[] {
            "[{\"songId\": 1, \"content\": \"[00:01.00]hi\", \"isSynced\": true, \"source\": \"remote\"}]",
            "[{\"song_id\": 2, \"content\": \"x\", \"is_synced\": \"true\"}]", "[{\"songId\": 3}]", "[{\"songId\": 3, \"content\": 5}]",
            "[{\"songId\": 3, \"content\": true, \"source\": 1}]", "[{\"songId\": 3, \"content\": {}}]",
        });
        cases.put("search_history", new String[] {
            "[{\"id\": 4, \"query\": \"rock\", \"timestamp\": 1700000000000}]", "[{\"query\": \"q\"}]", "[{\"id\": \"5\", \"query\": 6, \"timestamp\": \"7\"}]",
            "[{\"id\": null, \"query\": null, \"timestamp\": null}]",
        });
        cases.put("transitions", new String[] {
            "[{\"id\": 1, \"playlistId\": \"p1\", \"fromTrackId\": \"a\", \"toTrackId\": \"b\", \"settings\": {\"mode\": \"SMOOTH\", \"durationMs\": 4000, \"curveIn\": \"LINEAR\", \"curveOut\": \"EXP\"}}]",
            "[{\"playlistId\": \"p\", \"fromSongId\": \"1\", \"to_song_id\": \"2\", \"settings\": {\"durationMs\": 50000}}]",
            "[{\"playlistId\": \"p\"}]", "[{\"playlistId\": \"p\", \"settings\": {}}]",
            "[{\"playlistId\": \"p\", \"settings\": {\"mode\": \"BOGUS\", \"curveIn\": \"s_curve\"}}]",
            "[{\"playlistId\": \"p\", \"settings\": {\"mode\": null, \"durationMs\": null}}]",
            "[{\"playlistId\": \"p\", \"settings\": {\"mode\": 1}}]", "[{\"playlistId\": \"p\", \"settings\": {\"durationMs\": \"2500\"}}]",
            "[{\"playlistId\": \"p\", \"settings\": {\"durationMs\": 2.5}}]", "[{\"playlistId\": \"p\", \"settings\": null}]",
            "[{\"playlistId\": \"p\", \"fromTrackId\": null, \"toTrackId\": null, \"settings\": {\"mode\": \"NONE\"}}]",
        });
        cases.put("playback_history", new String[] {
            "[{\"songId\": \"s1\", \"timestamp\": 1700000000000, \"durationMs\": 30000, \"startTimestamp\": 1699999970000, \"endTimestamp\": 1700000000000}]",
            "[{\"songId\": \"s1\", \"timestamp\": 5, \"durationMs\": 2}]", "[{\"songId\": 7, \"timestamp\": \"5\", \"durationMs\": 2, \"startTimestamp\": null}]",
            "[{\"timestamp\": 5}]", "[{\"songId\": \"s\", \"timestamp\": 5, \"durationMs\": 2, \"endTimestamp\": \"x\"}]",
        });
        cases.put("ai_usage_logs", new String[] {
            "[{\"id\": 3, \"timestamp\": 1700000000000, \"provider\": \"GEMINI\", \"model\": \"gemini-2.5-flash\", \"promptType\": \"playlist\", \"promptTokens\": 10, \"outputTokens\": 20, \"thoughtTokens\": 0}]",
            "[{\"timestamp\": 1}]", "[{\"promptTokens\": 3000000000}]", "[{\"promptTokens\": \"12\"}]",
        });
        cases.put("artist_images", new String[] {
            "[{\"artistName\": \"A\", \"imageUrl\": \"https://x/y.jpg\", \"customImageBase64\": \"AAEC\"}]",
            "[{\"artistName\": \"B\", \"imageUrl\": \"\"}]", "[{\"artistName\": \"C\"}]", "[{\"imageUrl\": 5, \"customImageBase64\": null}]",
        });
        cases.put("preferences", new String[] {
            "[{\"key\": \"theme\", \"type\": \"string\", \"stringValue\": \"dark\"}, {\"key\": \"count\", \"type\": \"int\", \"intValue\": 5}, {\"key\": \"enabled\", \"type\": \"boolean\", \"booleanValue\": true}]",
            "[{\"key\": \"a\", \"type\": \"long\", \"longValue\": 9000000000}, {\"key\": \"b\", \"type\": \"float\", \"floatValue\": 0.1}, {\"key\": \"c\", \"type\": \"double\", \"doubleValue\": 0.1}]",
            "[{\"key\": \"s\", \"type\": \"string_set\", \"stringSetValue\": [\"b\", \"a\", \"b\"]}]", "[{\"key\": \"f\", \"type\": \"float\", \"floatValue\": 1e10}]",
            "[{\"key\": \"f\", \"type\": \"float\", \"floatValue\": 3.4028235e38}, {\"key\": \"d\", \"type\": \"double\", \"doubleValue\": 1e-7}]",
            "[{\"key\": \"i\", \"type\": \"int\", \"intValue\": \"5\", \"doubleValue\": \"2.5\"}]", "[{\"key\": \"i\", \"type\": \"int\", \"intValue\": 2147483648}]",
            "[{\"key\": \"f\", \"type\": \"float\", \"floatValue\": 0.30000001192092896, \"doubleValue\": 123456789.125}]",
            "[{\"key\": \"d\", \"type\": \"double\", \"doubleValue\": 1.0E7}, {\"key\": \"e\", \"type\": \"double\", \"doubleValue\": 0.001}, {\"key\": \"g\", \"type\": \"double\", \"doubleValue\": 0.0001}]",
            "[{\"key\": \"d\", \"type\": \"double\", \"doubleValue\": -0.0}, {\"key\": \"x\", \"type\": \"double\", \"doubleValue\": 123456789012345680000}]",
            "[{\"key\": \"s\", \"type\": \"string_set\", \"stringSetValue\": null}, {\"key\": \"t\", \"type\": \"string_set\", \"stringSetValue\": []}]",
            "[{\"key\": \"s\", \"type\": \"string\", \"stringValue\": 5}, {\"key\": \"b\", \"type\": \"boolean\", \"booleanValue\": \"yes\"}]",
            "[{\"key\": \"s\", \"type\": \"string_set\", \"stringSetValue\": [1, true, null]}]",
        });
        cases.put("playlist_list", new String[] {
            "[{\"id\": \"p1\", \"name\": \"Mix\", \"songIds\": [\"1\", \"2\"], \"createdAt\": 5, \"lastModified\": 6, \"isAiGenerated\": true, \"coverColorArgb\": -16777216, \"coverShapeType\": \"Star\", \"coverShapeDetail1\": 0.5, \"source\": \"AI\", \"sortOrder\": 2}]",
            "[{\"id\": \"p\", \"name\": \"n\"}]", "[{\"id\": \"p\", \"name\": \"n\", \"songIds\": [1, null]}]",
            "[{\"id\": \"p\", \"name\": \"n\", \"songIds\": [], \"coverShapeDetail4\": 6, \"coverShapeDetail2\": 1.0E-5}]",
        });
        cases.put("playlists_payload", new String[] {
            "{\"playlists\": [{\"id\": \"p1\", \"name\": \"Mix\", \"songIds\": [\"10\", \"11\"], \"source\": \"LOCAL\"}], \"playlistSongOrderModes\": {\"p1\": \"manual\"}, \"playlistsSortOption\": \"playlist_name_az\", \"songMetadata\": {\"10\": {\"title\": \"T\", \"artist\": \"A\", \"album\": \"B\", \"duration\": 1000}}, \"coverImages\": {\"p1\": \"AAEC\"}}",
            "{}", "{\"playlists\": null, \"songMetadata\": {}}", "{\"songMetadata\": {\"1\": {\"title\": \"t\"}}}", "[]", "5",
            "{\"playlistSongOrderModes\": {\"a\": 5, \"b\": null}}", "{\"playlists\": [5]}",
        });
        cases.put("order_modes", new String[] {"{\"a\": \"b\"}", "{}", "[]", "{\"a\": 1}", "{\"a\": \"x\", \"a\": \"y\"}"});
        for (Map.Entry<String, String[]> e : cases.entrySet()) {
            Type t = types.get(e.getKey());
            for (String payload : e.getValue()) {
                JsonElement out;
                try {
                    Object value = BACKUP.fromJson(payload, t);
                    out = s(value == null ? "null" : BACKUP.toJson(value));
                } catch (Throwable th) {
                    out = thrown(th);
                }
                line("entities", obj("type", e.getKey(), "payload", payload), out);
            }
        }
        // the AI usage handler encodes with the app's default Gson (compact, no nulls)
        List<AiUsageEntity> usage = List.of(new AiUsageEntity(1, 1_700_000_000_000L, "GEMINI", "gemini-2.5-flash", "playlist", 10, 20, 3));
        line("aiUsageExport", JsonNull.INSTANCE, s(PLAIN.toJson(usage)));
    }

    // ------------------------------------------------------------------ engagement merge

    static void engagement() throws Exception {
        Object handler = allocate(EngagementStatsModuleHandler.class);
        Method parse = EngagementStatsModuleHandler.class.getDeclaredMethod("parseEntries", JsonArray.class);
        parse.setAccessible(true);
        String[] payloads = {
            "[{\"songId\":\"song-1\",\"playCount\":3,\"totalDuration\":1200,\"lastPlayedAt\":100},{\"song_id\":\"song-2\",\"play_count\":\"-4\",\"duration_ms\":\"500\",\"last_played_timestamp\":\"250\"},{\"songId\":\"song-1\",\"playCount\":2,\"totalPlayDurationMs\":4000,\"lastPlayedTimestamp\":300},{\"songId\":\"   \",\"playCount\":8},\"bad-row\"]",
            "[{\"playCount\": 3}, null, \"bad-row\"]", "[]", "[{\"songId\": \" s \", \"playCount\": 5.9}]",
            "[{\"songId\": 42, \"plays\": \"3\", \"score\": 9}]", "[{\"songId\": \"s\", \"playCount\": 99999999999}]",
            "[{\"songId\": \"s\", \"playCount\": null, \"play_count\": 4}]", "[{\"songId\": \"s\", \"playCount\": \"x\", \"score\": 6}]",
            "[{\"songId\": true, \"timestamp\": 1e3}]", "[{\"songId\": \"a\", \"totalDuration\": -8, \"duration_ms\": 9}]",
            "[{\"songId\": \"a\"}, {\"songId\": \"b\"}, {\"songId\": \"a\", \"playCount\": 1}]", "[{\"songId\": null, \"song_id\": \"z\"}]",
            "[{\"songId\": [\"q\"]}]", "[{\"songId\": \"s\", \"lastPlayedTimestamp\": 9223372036854775807}]",
            "[{\"songId\": \"s\", \"playCount\": -2147483649}]",
        };
        for (String p : payloads) {
            JsonElement out;
            try {
                JsonElement parsed = JsonParser.parseString(p);
                if (!parsed.isJsonArray()) throw new IllegalArgumentException("Engagement stats payload must be a JSON array.");
                @SuppressWarnings("unchecked")
                List<SongEngagementEntity> stats = (List<SongEngagementEntity>) parse.invoke(handler, parsed.getAsJsonArray());
                if (parsed.getAsJsonArray().size() > 0 && stats.isEmpty()) {
                    throw new IllegalArgumentException("Engagement stats backup does not contain any valid entries.");
                }
                out = s(OUT.toJson(stats));
            } catch (Throwable t) {
                out = thrown(t);
            }
            line("engagementRestore", s(p), out);
        }
        // export field names
        line("engagementExport", JsonNull.INSTANCE,
            s(BACKUP.toJson(List.of(new SongEngagementEntity("song-1", 3, 1200, 100)))));
    }

    // ------------------------------------------------------------------ playlist song resolver

    static void resolver() throws Exception {
        Object handler = allocate(PlaylistsModuleHandler.class);
        Method resolve = PlaylistsModuleHandler.class.getDeclaredMethod("resolveSongId", String.class, Map.class, Map.class, Map.class);
        resolve.setAccessible(true);
        Method key = PlaylistsModuleHandler.class.getDeclaredMethod("normalizeMatchKey", String.class, String.class);
        key.setAccessible(true);
        Object[][] library = {
            {1L, "Song A", "Artist", "Album 1", 200_000L},
            {2L, "song a ", " ARTIST", "Album 2", 201_000L},
            {3L, "Song A", "Artist", "Album 2", 260_000L},
            {4L, "Unique", "Solo", "Only", 100_000L},
            {5L, "Twin", "Band", "Same", 150_000L},
            {6L, "Twin", "Band", "Same", 151_500L},
            {7L, "Twin", "Band", "Same", 300_000L},
            {8L, "\u0130stanbul", "\u00c9dith", "X", 1L},
            {9L, "Stra\u00dfe", "K", "Y", 1L},
            {10L, "Reused", "Other", "Z", 5L},
        };
        List<SongSummary> summaries = new ArrayList<>();
        for (Object[] r : library) summaries.add(new SongSummary((Long) r[0], (String) r[1], (String) r[2], (String) r[3], (Long) r[4]));
        Map<String, SongSummary> byId = new LinkedHashMap<>();
        Map<String, List<SongSummary>> index = new LinkedHashMap<>();
        for (SongSummary sum : summaries) {
            byId.put(Long.toString(sum.getId()), sum);
            String k = (String) key.invoke(handler, sum.getTitle(), sum.getArtistName());
            index.computeIfAbsent(k, x -> new ArrayList<>()).add(sum);
        }
        Object[][] metas = {
            {"1", "Song A", "Artist", "Album 1", 200_000L}, {"1", "Different", "Artist", "Album 1", 200_000L},
            {"99", "Unique", "Solo", "Elsewhere", 1L}, {"99", "SONG A", "artist", "Album 2", 0L},
            {"99", "Song A", "Artist", "album 2 ", 250_000L}, {"99", "Song A", "Artist", "Album 9", 201_500L},
            {"99", "Song A", "Artist", "Album 9", 230_000L}, {"99", "Twin", "Band", "Same", 150_500L},
            {"99", "Twin", "Band", "Same", 152_000L}, {"99", "Twin", "Band", "Other", 300_000L},
            {"99", "Twin", "Band", "Same", 500_000L}, {"99", "Missing", "Nobody", "", 0L},
            {"8", "i\u0307stanbul", "\u00e9dith", "x", 1L}, {"9", "STRASSE", "k", "y", 1L}, {"10", "Reused", "Different", "Z", 5L},
            {"10", " reused ", "OTHER", "Q", 99L}, {"4", "\tUnique\n", "solo", "", 0L},
        };
        for (Object[] m : metas) {
            Map<String, Object> meta = new LinkedHashMap<>();
            meta.put((String) m[0], new PlaylistsModuleHandler.SongMetadataEntry((String) m[1], (String) m[2], (String) m[3], (Long) m[4]));
            Object r = resolve.invoke(handler, m[0], meta, byId, index);
            line("resolveSongId", obj("id", (String) m[0], "title", (String) m[1], "artist", (String) m[2], "album", (String) m[3],
                "duration", (Long) m[4]), s((String) r));
        }
        for (String id : new String[] {"1", "4", "77", "", "-3"}) {
            Object r = resolve.invoke(handler, id, new LinkedHashMap<>(), byId, index);
            line("resolveSongId", obj("id", id), s((String) r));
        }
        JsonArray lib = new JsonArray();
        for (Object[] r : library) {
            JsonArray row = new JsonArray();
            row.add((Long) r[0]); row.add((String) r[1]); row.add((String) r[2]); row.add((String) r[3]); row.add((Long) r[4]);
            lib.add(row);
        }
        line("resolverLibrary", lib, JsonNull.INSTANCE);
    }

    // ------------------------------------------------------------------ Gson pretty writer on entities

    static void gsonWriter() throws Exception {
        List<Object> values = new ArrayList<>();
        values.add(List.of(new FavoritesEntity(123L, true, 1_700_000_000_000L), new FavoritesEntity(-4L, false, 0L)));
        values.add(List.of(new LyricsEntity(5L, "[00:01.00]<b>Tom & Jerry's</b> = \"x\" \\ \u2028 \u0001 caf\u00e9 \ud83c\udfb5", true, null)));
        values.add(List.of(new SearchHistoryEntity(0L, "q", 5L)));
        values.add(List.of(new TransitionRuleEntity(7L, "p", null, "b", new TransitionSettings(TransitionMode.FADE_IN_OUT, 1500, Curve.LOG, Curve.LINEAR))));
        values.add(List.of(new PlaybackHistoryBackupEntry("s", 10L, 5L, null, 10L)));
        values.add(List.of(new ArtistImageBackupEntry("A", "", null)));
        values.add(List.of(
            new PreferenceBackupEntry("f", "float", null, null, null, null, 0.1f, null, null),
            new PreferenceBackupEntry("g", "float", null, null, null, null, 1.0e10f, null, null),
            new PreferenceBackupEntry("h", "float", null, null, null, null, 1.0e-5f, null, null),
            new PreferenceBackupEntry("d", "double", null, null, null, null, null, 1234567.0, null),
            new PreferenceBackupEntry("e", "double", null, null, null, null, null, 12345678.9, null),
            new PreferenceBackupEntry("z", "double", null, null, null, null, null, -0.0, null),
            new PreferenceBackupEntry("t", "string_set", null, null, null, null, null, null, new LinkedHashSet<>(List.of("b", "a")))));
        values.add(new ArrayList<>());
        values.add(List.of(new Playlist("p1", "Mix", List.of("1", "2"), 5L, 6L, true, false, null, -16777216, null, "Star", 0.5f, null, null, 6.0f, "AI", 2)));
        Constructor<?> ctor = payloadClass().getDeclaredConstructors()[0];
        for (Constructor<?> c : payloadClass().getDeclaredConstructors()) if (c.getParameterCount() == 5) ctor = c;
        ctor.setAccessible(true);
        Map<String, String> modes = new LinkedHashMap<>();
        modes.put("p1", "manual");
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("1", new PlaylistsModuleHandler.SongMetadataEntry("T", "A", "B", 1000L));
        values.add(ctor.newInstance(List.of(new Playlist("p1", "Mix", List.of("1"), 5L, 6L, false, false, null, null, null, null, null, null, null, null, "LOCAL", 0)),
            modes, "playlist_name_az", meta, null));
        values.add(ctor.newInstance(new ArrayList<>(), new LinkedHashMap<>(), "", null, new LinkedHashMap<>()));
        for (Object v : values) line("gsonPretty", s(v.getClass().getSimpleName()), s(BACKUP.toJson(v)));
    }

    // ------------------------------------------------------------------ binary fixtures

    static byte[] pxplZip(Map<String, String> payloads, BackupManifest base, boolean stored) throws Exception {
        Map<String, BackupModuleInfo> info = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : payloads.entrySet()) {
            byte[] bytes = e.getValue().getBytes(StandardCharsets.UTF_8);
            int count;
            String trimmed = e.getValue().trim();
            try {
                count = trimmed.startsWith("[") ? BACKUP.fromJson(trimmed, JsonArray.class).size() : 1;
            } catch (Exception ex) {
                count = 0;
            }
            info.put(e.getKey(), new BackupModuleInfo("sha256:" + sha256(bytes), count, bytes.length));
        }
        BackupManifest manifest = new BackupManifest(base.getSchemaVersion(), base.getAppVersion(), base.getAppVersionCode(),
            base.getCreatedAt(), base.getDeviceInfo(), info);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(BackupFormatDetector.Companion.getPXPL_MAGIC());
        try (ZipOutputStream zip = new ZipOutputStream(out)) {
            putEntry(zip, "manifest.json", BACKUP.toJson(manifest).getBytes(StandardCharsets.UTF_8), stored);
            for (Map.Entry<String, String> e : payloads.entrySet()) {
                putEntry(zip, e.getKey() + ".json", e.getValue().getBytes(StandardCharsets.UTF_8), stored);
            }
        }
        return out.toByteArray();
    }

    static void putEntry(ZipOutputStream zip, String name, byte[] data, boolean stored) throws Exception {
        ZipEntry entry = new ZipEntry(name);
        if (stored) {
            CRC32 crc = new CRC32();
            crc.update(data);
            entry.setMethod(ZipEntry.STORED);
            entry.setSize(data.length);
            entry.setCompressedSize(data.length);
            entry.setCrc(crc.getValue());
        }
        zip.putNextEntry(entry);
        zip.write(data);
        zip.closeEntry();
    }

    /** BackupReader's ZIP path: skip the magic, then ZipInputStream; every .json except the manifest. */
    static JsonObject readLikeAndroid(byte[] file) throws Exception {
        JsonObject modules = new JsonObject();
        String manifest = null;
        try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(file, 4, file.length - 4))) {
            ZipEntry e;
            while ((e = zip.getNextEntry()) != null) {
                String text = new String(zip.readAllBytes(), StandardCharsets.UTF_8);
                if (e.getName().equals("manifest.json")) { if (manifest == null) manifest = text; }
                else if (e.getName().endsWith(".json")) modules.addProperty(e.getName().substring(0, e.getName().length() - 5), text);
            }
        }
        BackupManifest m = BACKUP.fromJson(manifest, BackupManifest.class);
        return obj("manifest", BACKUP.toJson(m), "modules", modules);
    }

    static void containers() throws Exception {
        BackupManifest base = new BackupManifest(3, "0.6.0-beta2", 60, 1_759_200_000_000L,
            new DeviceInfo("Google", "Pixel 9 Pro", 36), new LinkedHashMap<>());
        Map<String, String> payloads = new LinkedHashMap<>();
        // playlists: the v3 object payload with metadata for cross-device matching
        Constructor<?> ctor = null;
        for (Constructor<?> c : payloadClass().getDeclaredConstructors()) if (c.getParameterCount() == 5) ctor = c;
        ctor.setAccessible(true);
        Map<String, String> modes = new LinkedHashMap<>();
        modes.put("pl-1", "manual");
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("101", new PlaylistsModuleHandler.SongMetadataEntry("Midnight City", "M83", "Hurry Up, We're Dreaming", 243_000L));
        meta.put("102", new PlaylistsModuleHandler.SongMetadataEntry("Intro", "The xx", "xx", 127_000L));
        meta.put("103", new PlaylistsModuleHandler.SongMetadataEntry("Teardrop", "Massive Attack", "Mezzanine", 330_000L));
        Map<String, String> covers = new LinkedHashMap<>();
        covers.put("pl-1", Base64.getEncoder().encodeToString(new byte[] {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0, 0, 16}));
        List<Playlist> playlists = List.of(
            new Playlist("pl-1", "Late Night", List.of("101", "102", "103"), 1_750_000_000_000L, 1_758_000_000_000L, false, false,
                "/data/user/0/com.theveloper.pixelplay/files/playlist_cover_pl-1.jpg", null, null, null, null, null, null, null, "LOCAL", 0),
            new Playlist("pl-2", "Gym \u2022 AI", List.of("102"), 1_751_000_000_000L, 1_751_000_000_000L, true, false, null, -12_345_678,
                "rounded_bolt", "Star", 0.25f, 0.5f, 0.75f, 6.0f, "AI", 1));
        payloads.put("playlists", BACKUP.toJson(ctor.newInstance(playlists, modes, "playlist_name_az", meta, covers)));
        payloads.put("global_settings", BACKUP.toJson(List.of(
            new PreferenceBackupEntry("app_theme_mode", "string", "dark", null, null, null, null, null, null),
            new PreferenceBackupEntry("crossfade_duration", "int", null, 6000, null, null, null, null, null),
            new PreferenceBackupEntry("is_crossfade_enabled", "boolean", null, null, null, true, null, null, null),
            new PreferenceBackupEntry("nav_bar_corner_radius", "int", null, 28, null, null, null, null, null),
            new PreferenceBackupEntry("animated_lyrics_blur_strength", "float", null, null, null, null, 2.5f, null, null),
            new PreferenceBackupEntry("last_sync_timestamp", "long", null, null, 1_759_100_000_000L, null, null, null, null),
            new PreferenceBackupEntry("allowed_directories", "string_set", null, null, null, null, null, null,
                new LinkedHashSet<>(List.of("/storage/emulated/0/Music"))),
            new PreferenceBackupEntry("artist_delimiters", "string", "[\";\",\"/\"]", null, null, null, null, null, null),
            new PreferenceBackupEntry("lyrics_alignment", "string", "start", null, null, null, null, null, null),
            new PreferenceBackupEntry("songs_sort_option", "string", "song_title_az", null, null, null, null, null, null))));
        payloads.put("favorites", BACKUP.toJson(List.of(new FavoritesEntity(101L, true, 1_755_000_000_000L),
            new FavoritesEntity(104L, true, 1_756_000_000_000L))));
        payloads.put("lyrics", lyricsPayload());
        payloads.put("search_history", BACKUP.toJson(List.of(new SearchHistoryEntity(1L, "massive attack", 1_758_000_000_000L),
            new SearchHistoryEntity(2L, "caf\u00e9 \ud83c\udfb5 <tag>", 1_758_100_000_000L))));
        payloads.put("transitions", BACKUP.toJson(List.of(
            new TransitionRuleEntity(1L, "pl-1", null, null, new TransitionSettings(TransitionMode.SMOOTH, 6000, Curve.S_CURVE, Curve.S_CURVE)),
            new TransitionRuleEntity(2L, "pl-1", "101", "102", new TransitionSettings(TransitionMode.NONE, 0, Curve.LINEAR, Curve.LINEAR)))));
        payloads.put("engagement_stats", BACKUP.toJson(List.of(new SongEngagementEntity("101", 12, 2_900_000L, 1_758_500_000_000L),
            new SongEngagementEntity("103", 3, 990_000L, 1_757_000_000_000L))));
        payloads.put("playback_history", BACKUP.toJson(List.of(
            new PlaybackHistoryBackupEntry("101", 1_758_500_000_000L, 243_000L, 1_758_499_757_000L, 1_758_500_000_000L),
            new PlaybackHistoryBackupEntry("103", 1_758_600_000_000L, 120_000L, null, null))));
        payloads.put("quick_fill", BACKUP.toJson(List.of(
            new PreferenceBackupEntry("custom_genres", "string_set", null, null, null, null, null, null, new LinkedHashSet<>(List.of("Shoegaze", "City Pop"))),
            new PreferenceBackupEntry("custom_genre_icons", "string", "{\"Shoegaze\":\"rounded_waves\"}", null, null, null, null, null, null))));
        payloads.put("artist_images", BACKUP.toJson(List.of(new ArtistImageBackupEntry("M83", "https://e-cdns-images.dzcdn.net/images/artist/m83.jpg", null),
            new ArtistImageBackupEntry("The xx", "", Base64.getEncoder().encodeToString(new byte[] {1, 2, 3, 4, 5})))));
        payloads.put("equalizer", BACKUP.toJson(List.of(
            new PreferenceBackupEntry("custom_presets_json", "string", "[{\"name\":\"custom_night\",\"displayName\":\"NIGHT\",\"bandLevels\":[3,2,1,0,0,0,-1,-2,-3,-4],\"isCustom\":true}]", null, null, null, null, null, null),
            new PreferenceBackupEntry("pinned_presets_json", "string", "[\"flat\",\"rock\",\"custom_night\"]", null, null, null, null, null, null))));
        payloads.put("ai_usage_logs", PLAIN.toJson(List.of(new AiUsageEntity(1, 1_758_000_000_000L, "GEMINI", "gemini-2.5-flash", "playlist", 812, 240, 0))));
        byte[] v3 = pxplZip(payloads, base, false);
        Files.write(fixtures.resolve("android-v3.pxpl"), v3);
        line("readV3", s("android-v3.pxpl"), readLikeAndroid(v3));
        // the same archive with stored entries (what PixlBackup writes) must read identically on Android
        Map<String, String> small = new LinkedHashMap<>();
        small.put("favorites", payloads.get("favorites"));
        small.put("search_history", payloads.get("search_history"));
        byte[] storedZip = pxplZip(small, base, true);
        Files.write(fixtures.resolve("android-v3-stored.pxpl"), storedZip);
        line("readV3", s("android-v3-stored.pxpl"), readLikeAndroid(storedZip));

        // legacy v2: AppDataBackupManager.encodePayload (pretty Gson, PXPL + GZIP)
        Gson legacyGson = new GsonBuilder().setPrettyPrinting().create();
        JsonObject v2 = new JsonObject();
        v2.addProperty("formatVersion", 2);
        v2.addProperty("exportedAtEpochMs", 1_720_000_000_000L);
        JsonArray sections = new JsonArray();
        for (String k : new String[] {"playlists", "global_settings", "favorites", "search_history", "engagement_stats", "playback_history"}) sections.add(k);
        v2.add("availableSections", sections);
        List<Playlist> legacyPlaylists = List.of(new Playlist("legacy-1", "Old Mix", List.of("101", "103"), 1_700_000_000_000L,
            1_700_000_000_000L, false, false, null, null, null, null, null, null, null, null, "LOCAL", 0));
        v2.add("playlists", legacyGson.toJsonTree(List.of(
            new PreferenceBackupEntry("user_playlists_json_v1", "string", legacyGson.toJson(legacyPlaylists), null, null, null, null, null, null),
            new PreferenceBackupEntry("playlist_song_order_modes", "string", "{\"legacy-1\":\"manual\"}", null, null, null, null, null, null),
            new PreferenceBackupEntry("playlists_sort_option", "string", "playlist_name_za", null, null, null, null, null, null))));
        v2.add("globalSettings", legacyGson.toJsonTree(List.of(
            new PreferenceBackupEntry("app_theme_mode", "string", "light", null, null, null, null, null, null))));
        v2.add("favorites", legacyGson.toJsonTree(List.of(new FavoritesEntity(103L, true, 1_710_000_000_000L))));
        v2.add("searchHistory", legacyGson.toJsonTree(List.of(new SearchHistoryEntity(9L, "old query", 1_710_000_000_000L))));
        v2.add("engagementStats", legacyGson.toJsonTree(List.of(new SongEngagementEntity("103", 4, 1_000_000L, 1_710_000_000_000L))));
        v2.add("playbackHistory", legacyGson.toJsonTree(List.of(new PlaybackHistoryBackupEntry("103", 1_710_000_000_000L, 200_000L, null, null))));
        String v2Json = legacyGson.toJson(v2);
        ByteArrayOutputStream gz = new ByteArrayOutputStream();
        gz.write(BackupFormatDetector.Companion.getPXPL_MAGIC());
        try (GZIPOutputStream g = new GZIPOutputStream(gz)) { g.write(v2Json.getBytes(StandardCharsets.UTF_8)); }
        Files.write(fixtures.resolve("android-v2-legacy.pxpl"), gz.toByteArray());
        line("readLegacy", s("android-v2-legacy.pxpl"), adaptOut(new String(gunzip(gz.toByteArray(), 4), StandardCharsets.UTF_8)));

        // legacy v1: combined "preferences", raw GZIP (no magic) and raw JSON
        JsonObject v1 = new JsonObject();
        v1.addProperty("formatVersion", 1);
        v1.addProperty("exportedAtEpochMs", 1_690_000_000_000L);
        JsonArray s1 = new JsonArray();
        s1.add("playlists"); s1.add("global_settings"); s1.add("lyrics"); s1.add("transitions");
        v1.add("availableSections", s1);
        v1.add("preferences", legacyGson.toJsonTree(List.of(
            new PreferenceBackupEntry("user_playlists_json_v1", "string", "[]", null, null, null, null, null, null),
            new PreferenceBackupEntry("crossfade_duration", "int", null, 4000, null, null, null, null, null))));
        v1.add("lyrics", legacyGson.toJsonTree(List.of(new LyricsEntity(101L, "[00:00.50]Waiting in a car", true, "remote"))));
        v1.add("transitions", legacyGson.toJsonTree(List.of(new TransitionRuleEntity(3L, "legacy-1", null, null,
            new TransitionSettings(TransitionMode.OVERLAP, 3000, Curve.EXP, Curve.LOG)))));
        String v1Json = legacyGson.toJson(v1);
        ByteArrayOutputStream gz1 = new ByteArrayOutputStream();
        try (GZIPOutputStream g = new GZIPOutputStream(gz1)) { g.write(v1Json.getBytes(StandardCharsets.UTF_8)); }
        Files.write(fixtures.resolve("android-v1-legacy.json.gz"), gz1.toByteArray());
        Files.writeString(fixtures.resolve("android-v1-legacy.json"), v1Json, StandardCharsets.UTF_8);
        line("readLegacy", s("android-v1-legacy.json.gz"), adaptOut(v1Json));
        line("readLegacy", s("android-v1-legacy.json"), adaptOut(v1Json));
    }

    static String lyricsPayload() {
        JsonArray array = BACKUP.toJsonTree(List.of(new LyricsEntity(101L, "[00:01.00]Waiting in a car\n[00:04.20]Waiting for a ride in the dark", true, "remote"),
            new LyricsEntity(103L, "Love, love is a verb", false, null))).getAsJsonArray();
        JsonObject file = new JsonObject();
        file.addProperty("jsonFile", "yt_abc123XYZ.json");
        file.addProperty("json", "{\"plainLyrics\":\"Streaming words\",\"syncedLyrics\":\"[00:01.00]Streaming words\"}");
        array.add(file);
        JsonObject bad = new JsonObject();
        bad.addProperty("jsonFile", "../evil.json");
        bad.addProperty("json", "{}");
        array.add(bad);
        return BACKUP.toJson(array);
    }

    static JsonElement adaptOut(String json) {
        kotlin.Pair<BackupManifest, Map<String, String>> r = new LegacyPayloadAdapter().adapt(json, BACKUP);
        JsonObject modules = new JsonObject();
        for (Map.Entry<String, String> e : r.getSecond().entrySet()) modules.addProperty(e.getKey(), e.getValue());
        return obj("manifest", BACKUP.toJson(r.getFirst()), "modules", modules);
    }

    static byte[] gunzip(byte[] data, int offset) throws Exception {
        try (InputStream in = new GZIPInputStream(new ByteArrayInputStream(data, offset, data.length - offset))) {
            return in.readAllBytes();
        }
    }

    // ------------------------------------------------------------------ inflate vectors

    static void inflate() throws Exception {
        Random random = new Random(20260930L);
        List<byte[]> plains = new ArrayList<>();
        plains.add(new byte[0]);
        plains.add("a".getBytes(StandardCharsets.UTF_8));
        plains.add("hello hello hello hello hello hello".getBytes(StandardCharsets.UTF_8));
        byte[] rnd = new byte[4_000];
        random.nextBytes(rnd);
        plains.add(rnd);
        StringBuilder text = new StringBuilder();
        String[] words = {"lyrics", "playlist", "song", "\u00e9t\u00e9", "\ud83c\udfb5", "{\"songId\":", "123", "}", "\n", "  "};
        for (int i = 0; i < 15_000; i++) text.append(words[random.nextInt(words.length)]).append(i % 7 == 0 ? " " : "");
        plains.add(text.toString().getBytes(StandardCharsets.UTF_8));
        byte[] runs = new byte[100_000];
        for (int i = 0; i < runs.length; i++) runs[i] = (byte) ((i / 3000) % 4 == 0 ? 0 : (i % 251));
        plains.add(runs);
        byte[] zeros = new byte[300_000];
        plains.add(zeros);
        byte[] smallAlphabet = new byte[70_000];
        for (int i = 0; i < smallAlphabet.length; i++) smallAlphabet[i] = (byte) ('a' + random.nextInt(3));
        plains.add(smallAlphabet);
        int[][] settings = {{0, Deflater.DEFAULT_STRATEGY}, {1, Deflater.DEFAULT_STRATEGY}, {6, Deflater.DEFAULT_STRATEGY},
            {9, Deflater.DEFAULT_STRATEGY}, {6, Deflater.FILTERED}, {6, Deflater.HUFFMAN_ONLY}};
        StringBuilder sb = new StringBuilder();
        for (byte[] plain : plains) {
            for (int[] st : settings) {
                // Stored (level 0) output is as large as the input: keep it to the small inputs plus one
                // multi-block (> 65535 bytes) case.
                if (st[0] == 0 && plain.length > 20_000 && plain != smallAlphabet) continue;
                if (st[1] == Deflater.HUFFMAN_ONLY && (plain == runs || plain == zeros)) continue;
                Deflater d = new Deflater(st[0], true);
                d.setStrategy(st[1]);
                d.setInput(plain);
                d.finish();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                while (!d.finished()) out.write(buf, 0, d.deflate(buf));
                d.end();
                JsonObject o = new JsonObject();
                o.addProperty("level", st[0]);
                o.addProperty("strategy", st[1]);
                o.addProperty("deflate", Base64.getEncoder().encodeToString(out.toByteArray()));
                o.addProperty("size", plain.length);
                o.addProperty("sha256", sha256(plain));
                if (plain.length <= 64) o.addProperty("plain", Base64.getEncoder().encodeToString(plain));
                sb.append(OUT.toJson(o)).append('\n');
            }
        }
        // Deflater with SYNC_FLUSH segments (empty stored blocks inside the stream) and a preset of tiny blocks.
        Deflater d = new Deflater(6, true);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[65536];
        ByteArrayOutputStream plain = new ByteArrayOutputStream();
        for (int i = 0; i < 20; i++) {
            byte[] chunk = ("chunk " + i + " " + "x".repeat(i * 13) + "\n").getBytes(StandardCharsets.UTF_8);
            plain.write(chunk);
            d.setInput(chunk);
            int n;
            while ((n = d.deflate(buf, 0, buf.length, Deflater.SYNC_FLUSH)) > 0) out.write(buf, 0, n);
        }
        d.finish();
        while (!d.finished()) out.write(buf, 0, d.deflate(buf));
        d.end();
        JsonObject o = new JsonObject();
        o.addProperty("level", 6);
        o.addProperty("strategy", -1);
        o.addProperty("deflate", Base64.getEncoder().encodeToString(out.toByteArray()));
        o.addProperty("size", plain.size());
        o.addProperty("sha256", sha256(plain.toByteArray()));
        sb.append(OUT.toJson(o)).append('\n');
        Files.writeString(fixtures.resolve("inflate-cases.jsonl"), sb.toString(), StandardCharsets.UTF_8);
        System.err.println("inflate cases written");
    }
}
