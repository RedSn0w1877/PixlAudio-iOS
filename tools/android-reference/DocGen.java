import com.theveloper.pixelplay.data.model.LyricsDoc;
import com.theveloper.pixelplay.data.model.LyricsDocCodec;
import kotlinx.serialization.json.JsonElementKt;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * Runs the Android app's real LyricsDocCodec (kotlinx.serialization) over every case in cases.txt and
 * prints "IN <json-quoted input>" / "OUT <json-quoted re-encoded doc | null>" pairs.
 * cases.txt: one case per line; "\n" -> newline, "\t" -> tab, "\\" -> backslash.
 */
public class DocGen {
    static String q(String s) { return JsonElementKt.JsonPrimitive(s).toString(); }

    static String unescape(String line) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '\\' && i + 1 < line.length()) {
                char n = line.charAt(i + 1);
                if (n == 'n') { sb.append('\n'); i++; continue; }
                if (n == 't') { sb.append('\t'); i++; continue; }
                if (n == '\\') { sb.append('\\'); i++; continue; }
            }
            sb.append(c);
        }
        return sb.toString();
    }

    public static void main(String[] args) throws Exception {
        List<String> lines = Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8);
        StringBuilder sb = new StringBuilder();
        for (String raw : lines) {
            String c = unescape(raw);
            LyricsDoc d = LyricsDocCodec.INSTANCE.decode(c);
            sb.append("IN ").append(q(c)).append('\n');
            sb.append("OUT ").append(d == null ? "null" : q(LyricsDocCodec.INSTANCE.encode(d))).append('\n');
        }
        System.out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.flush();
    }
}
