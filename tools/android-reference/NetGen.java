import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;
import com.theveloper.pixelplay.data.ai.AiResponseCleaner;
import com.theveloper.pixelplay.data.ai.AiSystemPromptEngine;
import com.theveloper.pixelplay.data.ai.AiSystemPromptType;
import com.theveloper.pixelplay.data.ai.provider.AiProvider;
import com.theveloper.pixelplay.data.ai.provider.AiProviderException;
import com.theveloper.pixelplay.data.ai.provider.AiProviderSupport;
import com.theveloper.pixelplay.data.ai.provider.GeminiAiClient;
import com.theveloper.pixelplay.data.ai.provider.GenericOpenAiClient;
import com.theveloper.pixelplay.data.ai.provider.UnifiedModelFilter;
import com.theveloper.pixelplay.data.database.SpotifySongEntity;
import com.theveloper.pixelplay.data.spotify.SpotifyRepository;
import com.theveloper.pixelplay.data.tais.dj.DjIntent;
import com.theveloper.pixelplay.data.tais.dj.TaisIntentParser;
import com.theveloper.pixelplay.data.youtube.SignatureCipherSolver;
import com.theveloper.pixelplay.data.youtube.TrackMatcher;
import com.theveloper.pixelplay.data.youtube.YouTubeAudioFormat;
import com.theveloper.pixelplay.data.youtube.YouTubeSearchResult;
import com.theveloper.pixelplay.data.youtube.YouTubeStreamResolverKt;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import kotlinx.serialization.SerializationStrategy;
import kotlinx.serialization.json.Json;

/**
 * Golden vectors for PixlNet (stage 3c). Runs the Android app's compiled network-side logic on a desktop JVM and
 * writes one JSON object per line ({"fn": …, "in": …, "out": …}) to
 * Packages/PixlCore/Tests/PixlNetTests/Fixtures/net-android-golden.jsonl.
 *
 * Covered: TrackMatcher.normalize / similarity / score (float bits), pickBestAudio, TaisIntentParser.parse /
 * isMediaRequest, AiSystemPromptEngine.buildPrompt (every type × personas × contexts), AiResponseCleaner,
 * AiProviderSupport (chain, recovery model, createException + classification, wrapThrowable), UnifiedModelFilter,
 * the kotlinx request bodies of GeminiAiClient and GenericOpenAiClient (private @Serializable classes reached by
 * reflection), SpotifyRepository.unifiedId, and SignatureCipherSolver's base.js extraction (player id, signature and
 * n functions) over synthetic players.
 *
 * Classpath (Windows separators): the app's compileDebugKotlin/classes, kotlin-stdlib 2.4.0,
 * kotlinx-serialization-{core,json}-jvm 1.11.0, gson 2.14.0, okhttp 5.4.0 + okio-jvm 3.18.1 (the AI clients build an
 * OkHttpClient in their constructors), android.jar (platforms/android-37.0, only for class loading).
 *   javac -cp "$CP" NetGen.java && java -Duser.language=en -Duser.country=US \
 *       -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote -cp "$CP;." NetGen <ios repo root>
 */
public class NetGen {
    static final Gson G = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    static final List<JsonObject> OUT = new ArrayList<>();

    static void line(String fn, JsonElement in, JsonElement out) {
        JsonObject o = new JsonObject();
        o.addProperty("fn", fn);
        o.add("in", in);
        o.add("out", out);
        OUT.add(o);
    }

    static JsonElement str(String s) { return s == null ? JsonNull.INSTANCE : new JsonPrimitive(s); }

    static JsonArray arr(List<String> list) {
        JsonArray a = new JsonArray();
        for (String s : list) a.add(str(s));
        return a;
    }

    static String bits(float f) { return "0x" + Integer.toHexString(Float.floatToRawIntBits(f)); }

    static sun.misc.Unsafe unsafe() throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        return (sun.misc.Unsafe) f.get(null);
    }

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.US);
        Path fixtures = Path.of(args[0]).resolve("Packages/PixlCore/Tests/PixlNetTests/Fixtures");
        Files.createDirectories(fixtures);
        trackMatcher();
        pickBestAudio();
        intentParser();
        prompts();
        cleaner();
        providerSupport();
        codecs();
        unifiedIds();
        cipher();
        StringBuilder sb = new StringBuilder();
        for (JsonObject o : OUT) sb.append(G.toJson(o)).append('\n');
        Files.writeString(fixtures.resolve("net-android-golden.jsonl"), sb.toString(), StandardCharsets.UTF_8);
        System.err.println("net-android-golden.jsonl: " + OUT.size());
    }

    // ---------------------------------------------------------------- TrackMatcher

    static final String[] NORMALIZE = {
        "Northern Lights", "Café", "夜に駆ける", "春の日", "Nova - Northern Lights [Official Music Video]",
        "Song (Official Audio)", "Song (Lyric Video)", "Song lyrics", "HD Song 4K", "Song (feat. X)",
        "ΣΊΣΥΦΟΣ", "ΟΔΟΣ ΣΑΣ", "Ｆｕｌｌｗｉｄｔｈ Ｓｏｎｇ", "Beyoncé — Halo", "Don't Stop Me Now", "AC/DC – Back in Black",
        "Mr. Brightside", "  spaced   out  ", "Tab\tSep\nLine", "émoji 🎵 song", "Ⅳ roman", "½ half", "ﬁne ligature",
        "İstanbul", "Straße", "Song [MV]", "(official) song", "[audio] track (video)", "official music video",
        "official videos", "lyrics video", "lyric videos", "the hd remaster", "shd", "hd-remaster", "4k.", "x4k",
        "Café del Mar (Official Video) [HD]", "Ｓｏｎｇ（Official Audio）", "Кино — Группа крови", "مرحبا بالعالم",
        "한국어 노래", "a_b c-d", "Song (Live)", "Song - Remix", "Sped Up Version", "8D Audio Song", "(Official",
        "song (hd", "123", "", " ", "Ⓐ circled", "x²", "Ǆ digraph", "(mv) [hd] (audio", "Hurt (Official Video)",
        "Lyrics", "LYRICS", "official audio visualizer", "Song (Official Lyric Video) - Topic", "Ñandú", "Ølstykke",
        "ßhd", "hdß", "日hd lyrics", "αlyrics β", "x_hd", "4kß",
    };

    static final String[][] SONGS = {
        {"Northern Lights", "Nova", "First Light", "180000"},
        {"Northern Lights", "Nova, Guest Star", "Unknown Album", "0"},
        {"Hurt", "Johnny Cash", "American IV: The Man Comes Around", "218000"},
        {"Hurt (Live)", "Nine Inch Nails", "And All That Could Have Been", "372000"},
        {"夜に駆ける", "YOASOBI", "THE BOOK", "261000"},
        {"Blinding Lights - Remix", "The Weeknd, Rosalía", "", "203000"},
        {"Song 2", "Blur", "Blur", "122000"},
        {"Creep", "Radiohead", "Pablo Honey", "238000"},
    };

    static YouTubeSearchResult candidate(String videoId, String title, String artist, String album, Integer seconds, boolean video) {
        return new YouTubeSearchResult(videoId, title, artist, album, seconds, null, video);
    }

    static final Object[][] CANDIDATES = {
        {"Northern Lights", "Nova", null, 180, false},
        {"Northern Lights (Live)", "Nova", null, 180, false},
        {"Nova - Northern Lights [Official Music Video]", "NovaVEVO", null, 183, true},
        {"Northern Lights", "Supernova", null, 180, false},
        {"Northern Lights", "Completely Different", null, 180, false},
        {"Northern Lights", "Nova - Topic", "First Light", 186, false},
        {"Hurt", "Johnny Cash", "American IV: The Man Comes Around", 216, false},
        {"Hurt (Live)", "Johnny Cash", null, 240, false},
        {"Johnny Cash - Hurt", "Johnny Cash", null, 218, true},
        {"Hurt", "Nine Inch Nails", "The Downward Spiral", 373, false},
        {"夜に駆ける", "YOASOBI", "THE BOOK", 261, false},
        {"Blinding Lights (Remix)", "The Weeknd", null, 203, false},
        {"Blinding Lights", "The Weeknd", "After Hours", 200, false},
        {"Song 2", "Blur", "Blur", 122, false},
        {"Creep (Acoustic Cover)", "Radiohead", null, 230, false},
        {"Creep", "Radiohead", "Pablo Honey", 236, false},
        {"Creep", "Radiohead", "1.2M views", 238, false},
        {"Creep - Karaoke Instrumental", "Sing King", null, 238, false},
    };

    static void trackMatcher() throws Exception {
        TrackMatcher.Companion companion = TrackMatcher.Companion;
        Method normalize = TrackMatcher.Companion.class.getDeclaredMethod("normalize$app", String.class);
        Method similarity = TrackMatcher.Companion.class.getDeclaredMethod("similarity$app", String.class, String.class);
        for (String s : NORMALIZE) {
            line("normalize", str(s), str((String) normalize.invoke(companion, s)));
        }
        for (int i = 0; i < NORMALIZE.length; i++) {
            String a = (String) normalize.invoke(companion, NORMALIZE[i]);
            String b = (String) normalize.invoke(companion, NORMALIZE[(i * 7 + 3) % NORMALIZE.length]);
            JsonArray in = new JsonArray();
            in.add(a);
            in.add(b);
            line("similarity", in, new JsonPrimitive(bits((Float) similarity.invoke(companion, a, b))));
        }
        TrackMatcher matcher = (TrackMatcher) unsafe().allocateInstance(TrackMatcher.class);
        Method score = TrackMatcher.class.getDeclaredMethod("score$app", SpotifySongEntity.class, YouTubeSearchResult.class);
        int id = 0;
        for (String[] s : SONGS) {
            SpotifySongEntity song = new SpotifySongEntity("row", "track", "playlist", s[0], s[1], s[2], null,
                Long.parseLong(s[3]), null, null, 0L, null, null, 0, null);
            for (Object[] c : CANDIDATES) {
                YouTubeSearchResult cand = candidate("vid" + (id++), (String) c[0], (String) c[1], (String) c[2], (Integer) c[3], (Boolean) c[4]);
                JsonObject in = new JsonObject();
                in.addProperty("title", s[0]);
                in.addProperty("artist", s[1]);
                in.addProperty("album", s[2]);
                in.addProperty("durationMs", Long.parseLong(s[3]));
                in.addProperty("cTitle", (String) c[0]);
                in.addProperty("cArtist", (String) c[1]);
                in.add("cAlbum", str((String) c[2]));
                in.addProperty("cSeconds", (Integer) c[3]);
                in.addProperty("cVideo", (Boolean) c[4]);
                line("score", in, new JsonPrimitive(bits((Float) score.invoke(matcher, song, cand))));
            }
        }
    }

    // ---------------------------------------------------------------- pickBestAudio

    static YouTubeAudioFormat fmt(int itag, String mime, int bitrate, boolean muxed) {
        return new YouTubeAudioFormat(itag, mime, bitrate, "u" + itag, null, null, null, muxed);
    }

    static void pickBestAudio() {
        List<List<YouTubeAudioFormat>> sets = List.of(
            List.of(fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130000, false), fmt(251, "audio/webm; codecs=\"opus\"", 160000, false),
                fmt(141, "audio/mp4; codecs=\"mp4a.40.2\"", 256000, false)),
            List.of(fmt(18, "video/mp4", 90000, true), fmt(251, "audio/webm; codecs=\"opus\"", 160000, false)),
            List.of(fmt(18, "video/mp4", 500000, true)),
            List.of(fmt(140, "audio/mp4", 128000, false), fmt(250, "audio/webm; codecs=\"opus\"", 128000, false)),
            List.of(fmt(250, "audio/webm; codecs=\"OPUS\"", 128000, false), fmt(140, "audio/mp4", 128000, false)),
            List.of(fmt(139, "audio/mp4", 48000, false), fmt(140, "audio/mp4", 128000, false), fmt(18, "video/mp4", 600000, true)),
            List.of(fmt(140, null, 128000, false), fmt(141, null, 256000, false)),
            List.of());
        Integer[] caps = {null, 96, 128, 160, 300, 10};
        for (int i = 0; i < sets.size(); i++) {
            for (Integer cap : caps) {
                YouTubeAudioFormat best = YouTubeStreamResolverKt.pickBestAudio(sets.get(i), cap);
                JsonObject in = new JsonObject();
                in.addProperty("set", i);
                in.add("cap", cap == null ? JsonNull.INSTANCE : new JsonPrimitive(cap));
                line("pickBestAudio", in, best == null ? JsonNull.INSTANCE : new JsonPrimitive(best.getItag()));
            }
        }
    }

    // ---------------------------------------------------------------- TAIS DJ

    static final String[] PROMPTS = {
        "Why is jazz different from blues?", "Tell me about rock music", "What should I know about relaxing music?",
        "Could you please queue some acoustic songs", "play The Night We Met", "play Love Story by Taylor Swift",
        "play House of Cards", "find rock by Muse", "playlist history", "play some chill acoustic songs",
        "find energetic rock", "queue up some lo-fi please", "Can you play hip hop", "would you search for metal",
        "look for k-pop", "add a few r&b tracks", "chill", "love", "night", "happy", "sad songs", "jazz?",
        "\"rock\"", "play \"Happy\" by Pharrell", "play me some upbeat dance music", "search for feel good songs",
        "Please play some sleep music", "PLAY ROCK", "play rocknroll", "play rock-and-roll", "play  some   jazz",
        "find me something new", "how do I play jazz", "is rock dead", "do you like pop", "explain techno",
        "play the music", "play", "add", "", "   ", "play by Muse", "play rock by", "play rock by  Muse  ",
        "play some songs by Queen", "queue study focus", "find house music", "play edm workout", "gym",
        "play 'calm' songs", "play ambient\tmusic", "play classical please please", "Could you play country",
        "can youplay rock", "play some some rock", "play me some me some jazz", "play 夜に駆ける", "play café jazz",
    };

    static void intentParser() {
        TaisIntentParser parser = new TaisIntentParser();
        for (String p : PROMPTS) {
            DjIntent intent = parser.parse(p);
            JsonObject out = new JsonObject();
            out.addProperty("action", intent.getAction().name());
            out.add("genres", arr(intent.getGenres()));
            out.add("moods", arr(intent.getMoods()));
            out.addProperty("query", intent.getSearchQuery());
            out.addProperty("isMedia", parser.isMediaRequest(p));
            line("dj", str(p), out);
        }
    }

    // ---------------------------------------------------------------- prompts

    static void prompts() {
        AiSystemPromptEngine engine = new AiSystemPromptEngine();
        String defaultPersona = com.theveloper.pixelplay.data.preferences.AiPreferencesRepository.Companion.getDEFAULT_SYSTEM_PROMPT();
        String[] personas = {defaultPersona, "Be brief.", "Line one\n    indented line two"};
        String[] contexts = {"", "single line context", "USER_PROFILE\nSTATS: plays=1, uniq=1\n\nLISTENED: id|p|d|f|meta\n1|3|9|1|Song-Artist\n"};
        for (AiSystemPromptType type : AiSystemPromptType.values()) {
            for (int p = 0; p < personas.length; p++) {
                for (int c = 0; c < contexts.length; c++) {
                    JsonObject in = new JsonObject();
                    in.addProperty("type", type.name());
                    in.addProperty("persona", personas[p]);
                    in.addProperty("context", contexts[c]);
                    line("prompt", in, str(engine.buildPrompt(personas[p], type, contexts[c])));
                }
            }
        }
        line("defaultSystemPrompt", JsonNull.INSTANCE, str(defaultPersona));
    }

    // ---------------------------------------------------------------- cleaner

    static final String[] CLEAN = {
        "[\"a\",\"b\"]", "```json\n[\"a\",\"b\"]\n```", "Here you go: [\"a\",\"b\"] enjoy", "[\"a]\",\"b\\\"]\"] tail",
        "{\"title\":\"x\"} extra", "```kotlin\n{\"a\":{\"b\":1}}\n```", "no json here", "[unclosed", "{\"a\":\"}\"",
        "  [1,[2,[3]]] and [4]  ", "text {\"k\":\"v\"} more {\"x\":1}", "```text\nHello\n```", "``` plain ```",
        "[\"esc\\\\\",\"q\\\"\"]", "\\[\"skipped\"]", "prefix ] [\"ok\"]", "{[}]", "[{]}", "",
    };

    static void cleaner() {
        for (String s : CLEAN) {
            JsonObject out = new JsonObject();
            out.addProperty("json", AiResponseCleaner.INSTANCE.cleanJsonResponse(s));
            out.addProperty("text", AiResponseCleaner.INSTANCE.cleanTextResponse(s));
            out.add("array", str(AiResponseCleaner.INSTANCE.extractJsonArray(s)));
            out.add("object", str(AiResponseCleaner.INSTANCE.extractJsonObject(s)));
            line("cleaner", str(s), out);
        }
    }

    // ---------------------------------------------------------------- provider support

    static void providerSupport() {
        AiProviderSupport support = AiProviderSupport.INSTANCE;
        for (AiProvider p : AiProvider.values()) {
            List<String> names = new ArrayList<>();
            for (AiProvider q : support.buildProviderChain(p)) names.add(q.name());
            line("chain", str(p.name()), arr(names));
        }
        String[][] recovery = {
            {"llama3-8b-8192", "llama-3.1-8b-instant", "llama-3.1-8b-instant|llama-3.3-70b-versatile"},
            {"removed-model", "missing-default", "gemini-2.5-flash-lite|gemini-2.5-flash"},
            {"m", "m", "m"}, {"m", "d", ""}, {"m", "m", ""}, {"m", " ", ""}, {" m ", "m", " m |n"},
            {"a", "b", " |  | a"}, {"a", "b", "a|a|b"}, {"x", "y", "y|y"},
        };
        for (String[] r : recovery) {
            List<String> available = r[2].isEmpty() ? List.of() : Arrays.asList(r[2].split("\\|", -1));
            JsonObject in = new JsonObject();
            in.addProperty("current", r[0]);
            in.addProperty("default", r[1]);
            in.add("available", arr(available));
            line("recovery", in, str(support.selectRecoveryModel(r[0], r[1], available)));
        }
        Object[][] errors = {
            {"Groq", 404, "Not Found", "{\"error\":{\"message\":\"The model was not found\",\"code\":\"model_not_found\"}}", "removed-model"},
            {"Mistral", 402, "Payment Required", "{\"error\":{\"message\":\"Insufficient credits\"}}", "mistral-large-latest"},
            {"Gemini", 400, "Bad Request", "{\"error\":{\"message\":\"API key not valid. Please pass a valid API key.\"}}", "gemini-2.5-flash"},
            {"Gemini", 403, "Forbidden", "{\"error\":{\"message\":\"Generative Language API has not been used in this project.\"}}", "gemini-2.5-flash"},
            {"OpenAI", 500, "Internal Server Error", "not json at all", null},
            {"OpenAI", null, "timeout while reading", null, ""},
            {"DeepSeek", 429, null, "{\"message\":\"Rate limited\",\"code\":429,\"type\":\"rate\"}", "deepseek-chat"},
            {"Kimi", 400, "", "{\"error\":\"plain string error\"}", "k"},
            {"GLM", 401, null, "{\"error\":{\"message\":{\"nested\":true}}}", null},
            {"NVIDIA", 400, null, "{\"error\":{\"message\":null,\"code\":null,\"type\":\"invalid_request\"}}", "m"},
            {"OpenRouter", null, null, "   ", null},
            {"Custom Provider", 503, "Service Unavailable", "{\"error\":{\"message\":\"Unknown Model requested\"}}", "x"},
            {"Ollama", null, "failed to connect to localhost", null, "llama3"},
            {"Groq", 200, null, "{\"error\":{\"message\":\"Your balance is low\",\"code\":\"insufficient_quota\"}}", "m"},
        };
        for (Object[] e : errors) {
            AiProviderException ex = support.createException((String) e[0], (Integer) e[1], (String) e[2], (String) e[3], (String) e[4], null);
            JsonObject in = new JsonObject();
            in.addProperty("provider", (String) e[0]);
            in.add("status", e[1] == null ? JsonNull.INSTANCE : new JsonPrimitive((Integer) e[1]));
            in.add("transport", str((String) e[2]));
            in.add("body", str((String) e[3]));
            in.add("model", str((String) e[4]));
            line("createException", in, exceptionJson(ex));
        }
        String[] messages = {"timeout 504 while reading", "HTTP 401 Unauthorized", "code1234 and 99", "", "status:503", "x429y 429",
            "Unable to resolve host api.groq.com", "connection reset by peer", "600 is not a status but 599 is"};
        for (String m : messages) {
            AiProviderException ex = support.wrapThrowable("Groq", new java.io.IOException(m), "model-x");
            line("wrapThrowable", str(m), exceptionJson(ex));
        }
        String[][] filterCases = {
            {"gpt-4o|text-embedding-3|whisper-1|dall-e-3|gpt-4o-mini|omni-moderation", "gpt-4o-mini"},
            {"b-model|A-model|a-model|tts-1", "z-default|a-model"},
            {"", "only-default"},
        };
        for (String[] f : filterCases) {
            List<String> api = f[0].isEmpty() ? List.of() : Arrays.asList(f[0].split("\\|"));
            List<String> defaults = Arrays.asList(f[1].split("\\|"));
            JsonObject in = new JsonObject();
            in.add("api", arr(api));
            in.add("defaults", arr(defaults));
            line("modelFilter", in, arr(UnifiedModelFilter.INSTANCE.filterChatModelsWithDefaults(api, defaults)));
        }
    }

    static JsonObject exceptionJson(AiProviderException ex) {
        JsonObject out = new JsonObject();
        out.addProperty("message", ex.getMessage());
        out.add("code", str(ex.getProviderCode()));
        out.add("type", str(ex.getProviderType()));
        out.add("status", ex.getStatusCode() == null ? JsonNull.INSTANCE : new JsonPrimitive(ex.getStatusCode()));
        out.addProperty("modelUnavailable", ex.isModelUnavailable());
        out.addProperty("billing", ex.isBillingIssue());
        out.addProperty("apiKey", ex.isApiKeyIssue());
        out.addProperty("cooldown", ex.shouldCooldown());
        return out;
    }

    // ---------------------------------------------------------------- request bodies

    static Object construct(String className, Object... args) throws Exception {
        Class<?> c = Class.forName(className);
        for (Constructor<?> k : c.getDeclaredConstructors()) {
            if (k.getParameterCount() == args.length && !k.isSynthetic()) {
                Class<?>[] types = k.getParameterTypes();
                if (types.length > 0 && types[types.length - 1].getName().endsWith("DefaultConstructorMarker")) continue;
                k.setAccessible(true);
                return k.newInstance(args);
            }
        }
        throw new IllegalStateException("no constructor " + className + "/" + args.length);
    }

    @SuppressWarnings("unchecked")
    static String encode(Object client, String className, Object value) throws Exception {
        Field jsonField = client.getClass().getDeclaredField("json");
        jsonField.setAccessible(true);
        Json json = (Json) jsonField.get(client);
        Class<?> c = Class.forName(className);
        Field companionField = c.getDeclaredField("Companion");
        companionField.setAccessible(true);
        Object companion = companionField.get(null);
        Method serializer = companion.getClass().getDeclaredMethod("serializer");
        serializer.setAccessible(true);
        return json.encodeToString((SerializationStrategy<Object>) serializer.invoke(companion), value);
    }

    static void codecs() throws Exception {
        float[][] params = {
            {0.7f, 0.95f, 64, 4096, 0f, 0f}, {0.1f, 0.95f, 64, 8192, 0f, 0f}, {0.6f, 0.9f, 40, 0, 0.5f, -0.25f},
            {1.0f, 1.0f, 1, 100, 0f, 2f}, {0.85f, 0.5f, 64, 4096, 1e-5f, 0f}, {2.0f, 0.95f, 64, -1, 0f, 0f},
        };
        String[][] prompts = {{"System line\nsecond", "User \"quoted\" / slash é 🎵"}, {"", "only user"}, {"   ", "\u0001ctl\ttab"}};
        GeminiAiClient gemini = new GeminiAiClient("key");
        GenericOpenAiClient openai = new GenericOpenAiClient("key", "https://example.com/v1", "default-model", "OpenAI");
        String g = "com.theveloper.pixelplay.data.ai.provider.GeminiAiClient$";
        String o = "com.theveloper.pixelplay.data.ai.provider.GenericOpenAiClient$";
        for (float[] p : params) {
            for (String[] pr : prompts) {
                Object part = construct(g + "Part", pr[1]);
                Object content = construct(g + "Content", "user", List.of(part));
                Object system = pr[0].isBlank() ? null : construct(g + "Content", null, List.of(construct(g + "Part", pr[0])));
                Object config = construct(g + "GenerationConfig", (double) p[0], (int) p[2], (double) p[1], (int) p[3],
                    ((double) p[4]) != 0.0 ? (Double) (double) p[4] : null, ((double) p[5]) != 0.0 ? (Double) (double) p[5] : null);
                Object request = construct(g + "GenerateRequest", List.of(content), system, config);
                JsonObject in = new JsonObject();
                in.addProperty("temperature", p[0]);
                in.addProperty("topP", p[1]);
                in.addProperty("topK", (int) p[2]);
                in.addProperty("maxTokens", (int) p[3]);
                in.addProperty("presence", p[4]);
                in.addProperty("frequency", p[5]);
                in.addProperty("system", pr[0]);
                in.addProperty("prompt", pr[1]);
                line("geminiBody", in, str(encode(gemini, g + "GenerateRequest", request)));

                List<Object> messages = new ArrayList<>();
                if (!pr[0].isBlank()) messages.add(construct(o + "ChatMessage", "system", pr[0]));
                messages.add(construct(o + "ChatMessage", "user", pr[1]));
                Object chat = construct(o + "ChatRequest", "model-x", messages, (double) p[0], (Double) (double) p[1],
                    ((int) p[3]) > 0 ? (Integer) (int) p[3] : null, (Double) (double) p[4], (Double) (double) p[5]);
                line("openAIBody", in, str(encode(openai, o + "ChatRequest", chat)));
            }
        }
        Object countConfig = construct(g + "GenerationConfig", 0.0, 64, 0.95, 8192, null, null);
        Object countRequest = construct(g + "GenerateRequest", List.of(construct(g + "Content", "user", List.of(construct(g + "Part", "p")))),
            construct(g + "Content", null, List.of(construct(g + "Part", "s"))), countConfig);
        line("geminiCountBody", JsonNull.INSTANCE, str(encode(gemini, g + "GenerateRequest", countRequest)));
    }

    // ---------------------------------------------------------------- unified ids

    static void unifiedIds() throws Exception {
        Method m = SpotifyRepository.Companion.class.getDeclaredMethod("unifiedId$app", long.class, String.class);
        String[] keys = {"", "a", "4uLU6hMCjMI75M1A2tKUQC", "spotify:track:x", "夜に駆ける", "🎵emoji", "browse_abcdef0123456789abcd",
            "a\u0000b", "The quick brown fox jumps over the lazy dog"};
        long[] offsets = {3_000_000_000_000L, 4_000_000_000_000L, 5_000_000_000_000L};
        for (long off : offsets) {
            for (String k : keys) {
                JsonObject in = new JsonObject();
                in.addProperty("offset", off);
                in.addProperty("key", k);
                line("unifiedId", in, new JsonPrimitive((Long) m.invoke(SpotifyRepository.Companion, off, k)));
            }
        }
    }

    // ---------------------------------------------------------------- cipher

    static final String HELPER = "var Xy={AB:function(a,b){a.splice(0,b)},CD:function(a){a.reverse()},EF:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c}};";
    static final String SIG = "Sig=function(a){a=a.split(\"\");Xy.AB(a,3);Xy.CD(a,17);Xy.EF(a,5);return a.join(\"\")};";
    static final String NFN = "nfn=function(a){var b=a.split(\"\"),c=\"}{\",d=`${b}}`;try{if(b.length>0){b.reverse()}}catch(e){return \"enhanced_except_\"+a}return b.join(\"\")};";

    static final String[] PLAYERS = {
        // c&&(c=Sig(decodeURIComponent(c))) + .get("n"))&&(b=Nf[0](b) with var Nf=[nfn];
        "(function(){" + HELPER + "var x=1;" + SIG + "var Nf=[nfn];" + NFN + "foo.get(\"n\"))&&(b=Nf[0](b),q);c&&(c=Sig(decodeURIComponent(c)));})",
        // m=Sig(decodeURIComponent(h.s)) + String.fromCharCode(110) pattern + function declaration
        "var Xy={AB:function(a,b){a.splice(0,b)}};function Sig(a){a=a.split(\"\");Xy.AB(a,1);return a.join(\"\")}"
            + "var z=m=Sig(decodeURIComponent(h.s));(b=String.fromCharCode(110),c=a.get(b))&&(c=Qn(c));"
            + "Qn=function(a){var s='{';return a+s.length}",
        // only the split pattern, n via .set("n", fn(
        "abc,Ab$1=function(a){a=a.split('');Zz.qq(a,2);return a.join('')};var Zz={qq:function(a,b){a.length=b}};"
            + "r.set(\"n\", Nq(r.get(\"n\")));var Nq=function(a){return a.split('').reverse().join('')};",
        // patterns present but function bodies missing
        "c&&(c=Missing(decodeURIComponent(c)));x.get(\"n\"))&&(b=Gone(b);",
        // nothing at all
        "var nothing=1;",
        // object-literal helper absent, n array without declaration of element
        "Q1=function(a){a=a.split(\"\");a.reverse();return a.join(\"\")};.get(\"n\"))&&(b=Arr[2](b);var Arr=[zz];zz:function(a){return a}",
    };

    static final String[] IFRAMES = {
        "var scriptUrl = 'https:\\/\\/www.youtube.com\\/s\\/player\\/0123abcd\\/www-widgetapi.vflset\\/www-widgetapi.js';",
        "https://www.youtube.com/s/player/9f8e7d6c5b/www-widgetapi.vflset/x.js",
        "player/short/", "no player here", "player\\/a-b_c-d_e\\/",
    };

    static void cipher() throws Exception {
        SignatureCipherSolver solver = (SignatureCipherSolver) unsafe().allocateInstance(SignatureCipherSolver.class);
        Method sig = SignatureCipherSolver.class.getDeclaredMethod("buildSignatureFunction", String.class);
        Method n = SignatureCipherSolver.class.getDeclaredMethod("buildNFunction", String.class);
        sig.setAccessible(true);
        n.setAccessible(true);
        for (String js : PLAYERS) {
            JsonObject out = new JsonObject();
            out.add("sig", str((String) sig.invoke(solver, js)));
            out.add("n", str((String) n.invoke(solver, js)));
            line("cipher", str(js), out);
        }
        Field f = SignatureCipherSolver.class.getDeclaredField("PLAYER_ID_REGEX");
        f.setAccessible(true);
        kotlin.text.Regex regex = (kotlin.text.Regex) f.get(null);
        for (String s : IFRAMES) {
            kotlin.text.MatchResult m = regex.find(s, 0);
            line("playerId", str(s), m == null ? JsonNull.INSTANCE : str(m.getGroupValues().get(1)));
        }
    }
}
