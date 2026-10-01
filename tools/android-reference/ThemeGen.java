import com.google.android.material.color.utilities.DynamicScheme;
import com.google.android.material.color.utilities.Hct;
import com.google.android.material.color.utilities.QuantizerCelebi;
import com.google.android.material.color.utilities.QuantizerWu;
import com.google.android.material.color.utilities.SchemeExpressive;
import com.google.android.material.color.utilities.SchemeFruitSalad;
import com.google.android.material.color.utilities.SchemeMonochrome;
import com.google.android.material.color.utilities.SchemeTonalSpot;
import com.google.android.material.color.utilities.SchemeVibrant;
import com.google.android.material.color.utilities.TonalPalette;
import com.theveloper.pixelplay.ui.theme.ColorExtractionConfig;
import com.theveloper.pixelplay.ui.theme.ColorRolesKt;
import com.theveloper.pixelplay.ui.theme.ColorScoringConfig;
import java.io.PrintStream;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Golden vectors for the album-art theme port (stage 4, PixlLibrary/ArtworkTheme). Runs the real Android code on a
 * desktop JVM and writes Packages/PixlCore/Tests/PixlLibraryTests/Fixtures/theme-golden.jsonl.
 *
 * What runs for real: the colour utilities inside com.google.android.material:material 1.14.0 (Hct, TonalPalette,
 * QuantizerWu, QuantizerCelebi, SchemeTonalSpot/Vibrant/Expressive/FruitSalad/Monochrome and the DynamicScheme
 * getters, i.e. exactly what ColorRoles.kt's createDynamicScheme/toComposeColorScheme read), the app's compiled
 * ColorRolesKt.selectSeedColorArgbFromPixels, and the private ColorRolesKt.shouldUseNeutralArtworkScheme and
 * blendArgb (method handles). The grayscale step of toGrayscaleColorScheme runs AndroidX core 1.19.0
 * ColorUtils.colorToHSL / HSLToColor (with a stub android.graphics.Color); the Compose Color round trip around it is
 * the identity for opaque sRGB colours.
 *
 * Test images are generated procedurally (xorshift32, integer maths only) from a small spec so the Swift test
 * builds the identical pixels (see ThemeGoldenTests.swift `TestImage`).
 *
 * Classpath (Windows separators): the app's compileDebugKotlin/classes, kotlin-stdlib 2.4.0, material 1.14.0
 * classes.jar and androidx core 1.19.0 classes.jar (both extracted from their .aar), the compiled stubs/ directory
 * (LruCache, graphics/Color), android.jar (platforms/android-37.0).
 *   javac -cp "$CP" ThemeGen.java && java -cp "$CP;." ThemeGen <repo root>
 * Generated with JDK 26.
 */
public final class ThemeGen {
    private static PrintStream out;

    public static void main(String[] args) throws Throwable {
        String root = args.length > 0 ? args[0] : ".";
        out = new PrintStream(
            new java.io.FileOutputStream(root + "/Packages/PixlCore/Tests/PixlLibraryTests/Fixtures/theme-golden.jsonl"),
            true, StandardCharsets.UTF_8);

        // 1. HCT round trips of colours.
        int[] probes = probeColors();
        for (int argb : probes) {
            Hct h = Hct.fromInt(argb);
            emit("{\"kind\":\"hct\",\"argb\":\"" + hex(argb) + "\",\"h\":\"" + bits(h.getHue()) + "\",\"c\":\""
                + bits(h.getChroma()) + "\",\"t\":\"" + bits(h.getTone()) + "\"}");
        }

        // 2. The solver over a grid.
        for (int hue = 0; hue < 360; hue += 15) {
            for (int chroma = 0; chroma <= 150; chroma += 10) {
                for (int tone = 0; tone <= 100; tone += 5) {
                    double h = hue + 0.5, c = chroma, t = tone;
                    emit("{\"kind\":\"solve\",\"h\":" + h + ",\"c\":" + c + ",\"t\":" + t + ",\"argb\":\""
                        + hex(Hct.from(h, c, t).toInt()) + "\"}");
                }
            }
        }

        // 3. Tonal palettes (key colour + tones).
        int[] toneList = {0, 4, 6, 10, 12, 17, 20, 22, 24, 25, 30, 35, 40, 49, 50, 60, 70, 80, 87, 90, 92, 94, 95, 96, 98, 99, 100};
        double[][] hcs = {{0, 0}, {25, 84}, {12.5, 36}, {90, 16}, {200, 6}, {280, 48}, {101, 200}, {330, 24}, {60, 8}, {150, 120}};
        for (double[] hc : hcs) {
            TonalPalette p = TonalPalette.fromHueAndChroma(hc[0], hc[1]);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < toneList.length; i++) {
                if (i > 0) sb.append(',');
                sb.append('"').append(hex(p.tone(toneList[i]))).append('"');
            }
            emit("{\"kind\":\"palette\",\"h\":" + hc[0] + ",\"c\":" + hc[1] + ",\"key\":\"" + hex(p.getKeyColor().toInt())
                + "\",\"tones\":[" + sb + "]}");
        }

        // 4. Schemes for every style, light and dark, plus Android's neutral flag.
        // Method handles resolve one method; getDeclaredMethod would load every signature (Compose types).
        MethodHandles.Lookup lookup = MethodHandles.privateLookupIn(ColorRolesKt.class, MethodHandles.lookup());
        MethodHandle neutral = lookup.findStatic(ColorRolesKt.class, "shouldUseNeutralArtworkScheme",
            MethodType.methodType(boolean.class, int.class, Hct.class));
        String[] styles = {"tonal_spot", "vibrant", "expressive", "fruit_salad"};
        for (int seed : seedColors()) {
            Hct source = Hct.fromInt(seed);
            emit("{\"kind\":\"neutral\",\"seed\":\"" + hex(seed) + "\",\"value\":" + (boolean) neutral.invoke(seed, source) + "}");
            for (String style : styles) {
                for (boolean dark : new boolean[] {false, true}) {
                    DynamicScheme s = scheme(style, source, dark);
                    emit("{\"kind\":\"scheme\",\"seed\":\"" + hex(seed) + "\",\"style\":\"" + style + "\",\"dark\":" + dark
                        + ",\"roles\":" + roles(s) + "}");
                }
            }
            for (boolean dark : new boolean[] {false, true}) {
                emit("{\"kind\":\"mono\",\"seed\":\"" + hex(seed) + "\",\"dark\":" + dark + ",\"roles\":"
                    + roles(new SchemeMonochrome(source, dark, 0.0)) + "}");
            }
        }

        // 5. Grayscale conversion (toGrayscaleColorScheme's convert).
        for (int argb : probes) {
            float[] hsl = new float[3];
            androidx.core.graphics.ColorUtils.colorToHSL(argb, hsl);
            hsl[0] = 0f;
            hsl[1] = 0f;
            emit("{\"kind\":\"gray\",\"argb\":\"" + hex(argb) + "\",\"out\":\"" + hex(androidx.core.graphics.ColorUtils.HSLToColor(hsl)) + "\"}");
        }

        // 6. blendArgb (private).
        MethodHandle blend = lookup.findStatic(ColorRolesKt.class, "blendArgb",
            MethodType.methodType(int.class, int.class, int.class, float.class));
        float[] ratios = {0f, 0.21f, 0.42f, 0.5f, 0.57f, 0.72f, 1f, 1.3f, -0.2f};
        for (int i = 0; i + 1 < probes.length; i += 3) {
            for (float r : ratios) {
                int v = (int) blend.invoke(probes[i], probes[i + 1], r);
                emit("{\"kind\":\"blend\",\"a\":\"" + hex(probes[i]) + "\",\"b\":\"" + hex(probes[i + 1]) + "\",\"r\":\""
                    + Integer.toHexString(Float.floatToRawIntBits(r)) + "\",\"out\":\"" + hex(v) + "\"}");
            }
        }

        // 7. Quantizers and seed selection over procedural images.
        String[] kinds = {"noise", "blocks", "gradient", "gray", "accent", "alpha", "dark", "duo"};
        int[] accuracies = {0, 4, 10};
        for (String kind : kinds) {
            for (int variant = 0; variant < 6; variant++) {
                int w = 24 + (variant * 19) % 105;   // 24…128
                int h = 24 + (variant * 37) % 105;
                int seed = 0x1234567 + variant * 7919 + kind.hashCode();
                int[] px = image(kind, w, h, seed);
                String spec = "{\"type\":\"" + kind + "\",\"w\":" + w + ",\"h\":" + h + ",\"seed\":" + seed + "}";
                List<Integer> wu = new ArrayList<>(new QuantizerWu().quantize(px, 128).colorToCount.keySet());
                emit("{\"kind\":\"wu\",\"image\":" + spec + ",\"colors\":" + hexList(wu) + "}");
                Map<Integer, Integer> celebi = QuantizerCelebi.quantize(px, 128);
                List<Integer> keys = new ArrayList<>(celebi.keySet());
                List<Integer> counts = new ArrayList<>();
                for (int k : keys) counts.add(celebi.get(k));
                emit("{\"kind\":\"celebi\",\"image\":" + spec + ",\"colors\":" + hexList(keys) + ",\"counts\":" + counts + "}");
                for (int acc : accuracies) {
                    ColorExtractionConfig config = new ColorExtractionConfig(128, 128, new ColorScoringConfig(), acc);
                    int chosen = ColorRolesKt.selectSeedColorArgbFromPixels(px, config);
                    emit("{\"kind\":\"seedcolor\",\"image\":" + spec + ",\"accuracy\":" + acc + ",\"seed\":\"" + hex(chosen) + "\"}");
                }
            }
        }
        out.close();
    }

    private static DynamicScheme scheme(String style, Hct source, boolean dark) {
        switch (style) {
            case "vibrant": return new SchemeVibrant(source, dark, 0.0);
            case "expressive": return new SchemeExpressive(source, dark, 0.0);
            case "fruit_salad": return new SchemeFruitSalad(source, dark, 0.0);
            default: return new SchemeTonalSpot(source, dark, 0.0);
        }
    }

    /** The 48 roles in ColorRoles.kt's toComposeColorScheme / StoredColorSchemeValues order. */
    private static String roles(DynamicScheme s) {
        int[] v = {
            s.getPrimary(), s.getOnPrimary(), s.getPrimaryContainer(), s.getOnPrimaryContainer(), s.getInversePrimary(),
            s.getSecondary(), s.getOnSecondary(), s.getSecondaryContainer(), s.getOnSecondaryContainer(),
            s.getTertiary(), s.getOnTertiary(), s.getTertiaryContainer(), s.getOnTertiaryContainer(),
            s.getBackground(), s.getOnBackground(), s.getSurface(), s.getOnSurface(), s.getSurfaceVariant(), s.getOnSurfaceVariant(),
            s.getSurfaceTint(), s.getInverseSurface(), s.getInverseOnSurface(), s.getError(), s.getOnError(), s.getErrorContainer(),
            s.getOnErrorContainer(), s.getOutline(), s.getOutlineVariant(), s.getScrim(), s.getSurfaceBright(), s.getSurfaceDim(),
            s.getSurfaceContainer(), s.getSurfaceContainerHigh(), s.getSurfaceContainerHighest(), s.getSurfaceContainerLow(),
            s.getSurfaceContainerLowest(), s.getPrimaryFixed(), s.getPrimaryFixedDim(), s.getOnPrimaryFixed(),
            s.getOnPrimaryFixedVariant(), s.getSecondaryFixed(), s.getSecondaryFixedDim(), s.getOnSecondaryFixed(),
            s.getOnSecondaryFixedVariant(), s.getTertiaryFixed(), s.getTertiaryFixedDim(), s.getOnTertiaryFixed(),
            s.getOnTertiaryFixedVariant(),
        };
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < v.length; i++) {
            if (i > 0) sb.append(',');
            sb.append('"').append(hex(v[i])).append('"');
        }
        return sb.append(']').toString();
    }

    private static int[] probeColors() {
        List<Integer> list = new ArrayList<>();
        int[] fixed = {0xFF000000, 0xFFFFFFFF, 0xFF808080, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFF00FFFF,
            0xFFFF00FF, 0xFF6C4FF5, 0xFFAB47BC, 0xFFF06292, 0xFFFF8A65, 0xFF1E1234, 0xFF7F7F7F, 0xFF010101, 0xFFFEFEFE,
            0x80FF0000, 0x00123456};
        for (int f : fixed) list.add(f);
        int x = 0x2545F491;
        for (int i = 0; i < 120; i++) {
            x = xorshift(x);
            list.add(0xFF000000 | (x & 0xFFFFFF));
        }
        int[] a = new int[list.size()];
        for (int i = 0; i < a.length; i++) a[i] = list.get(i);
        return a;
    }

    private static int[] seedColors() {
        List<Integer> list = new ArrayList<>();
        int[] fixed = {0xFF6C4FF5, 0xFFAB47BC, 0xFF4285F4, 0xFFEA4335, 0xFFFBBC05, 0xFF34A853, 0xFF808080, 0xFF7A7570,
            0xFF000000, 0xFFFFFFFF, 0xFF6B5B2E, 0xFFB0A060, 0xFF2E7D32, 0xFF00BCD4, 0xFFFF5722, 0xFF795548, 0xFF9E9E9E,
            0xFF607D8B, 0xFFC0C2C5, 0xFF3A3A40};
        for (int f : fixed) list.add(f);
        int x = 0x6A09E667;
        for (int i = 0; i < 20; i++) {
            x = xorshift(x);
            list.add(0xFF000000 | (x & 0xFFFFFF));
        }
        int[] a = new int[list.size()];
        for (int i = 0; i < a.length; i++) a[i] = list.get(i);
        return a;
    }

    // --- Procedural test images (mirrored by ThemeGoldenTests.swift) ---

    static int xorshift(int x) {
        x ^= x << 13;
        x ^= x >>> 17;
        x ^= x << 5;
        return x;
    }

    /** A random value in 0..<n from the generator state (state must be advanced by the caller). */
    static int pick(int x, int n) { return Integer.remainderUnsigned(x, n); }

    static int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

    static int[] image(String kind, int w, int h, int seed) {
        int[] px = new int[w * h];
        int x = seed == 0 ? 1 : seed;
        int[] palette = new int[6];
        for (int i = 0; i < palette.length; i++) {
            x = xorshift(x);
            palette[i] = x & 0xFFFFFF;
        }
        x = xorshift(x);
        int baseGray = 30 + pick(x, 191);
        x = xorshift(x);
        int accentW = 2 + pick(x, Math.max(1, w / 2));
        x = xorshift(x);
        int accentH = 2 + pick(x, Math.max(1, h / 2));
        for (int yy = 0; yy < h; yy++) {
            for (int xx = 0; xx < w; xx++) {
                x = xorshift(x);
                int r = x;
                int argb;
                switch (kind) {
                    case "noise":
                        argb = 0xFF000000 | (r & 0xFFFFFF);
                        break;
                    case "blocks": {
                        int block = ((yy / 8) * 31 + (xx / 8) * 17 + seed) & 0x7FFFFFFF;
                        argb = 0xFF000000 | palette[block % 4];
                        break;
                    }
                    case "gradient": {
                        int t = w > 1 ? xx * 255 / (w - 1) : 0;
                        int a = palette[0], b = palette[1];
                        int noise = pick(r, 9) - 4;
                        int cr = clamp255((((a >> 16) & 255) * (255 - t) + ((b >> 16) & 255) * t) / 255 + noise);
                        int cg = clamp255((((a >> 8) & 255) * (255 - t) + ((b >> 8) & 255) * t) / 255 + noise);
                        int cb = clamp255(((a & 255) * (255 - t) + (b & 255) * t) / 255 + noise);
                        argb = 0xFF000000 | (cr << 16) | (cg << 8) | cb;
                        break;
                    }
                    case "gray": {
                        int v = clamp255(baseGray + pick(r, 11) - 5);
                        int tint = pick(r >>> 8, 5);
                        argb = 0xFF000000 | (clamp255(v + tint) << 16) | (v << 8) | v;
                        break;
                    }
                    case "accent": {
                        boolean inside = Math.abs(xx - w / 2) < accentW / 2 + 1 && Math.abs(yy - h / 2) < accentH / 2 + 1;
                        if (inside) {
                            argb = 0xFF000000 | palette[2];
                        } else {
                            int v = 10 + pick(r, 31);
                            argb = 0xFF000000 | (v << 16) | (v << 8) | v;
                        }
                        break;
                    }
                    case "alpha": {
                        int[] alphas = {0, 20, 128, 255};
                        int block = ((yy / 6) * 13 + (xx / 6) * 7) & 0x7FFFFFFF;
                        argb = (alphas[pick(r, 4)] << 24) | palette[block % 5];
                        break;
                    }
                    case "dark": {
                        if (pick(r, 10) == 0) {
                            argb = 0xFF000000 | palette[3];
                        } else {
                            int v = pick(r >>> 4, 12);
                            argb = 0xFF000000 | (v << 16) | (v << 8) | v;
                        }
                        break;
                    }
                    default: { // duo
                        argb = 0xFF000000 | (xx < w / 2 ? palette[4] : palette[5]);
                        break;
                    }
                }
                px[yy * w + xx] = argb;
            }
        }
        return px;
    }

    /** One JSON line, LF-terminated on every OS. */
    private static void emit(String line) { out.print(line + '\n'); }

    private static String hex(int v) { return String.format("%08X", v); }

    private static String hexList(List<Integer> list) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append('"').append(hex(list.get(i))).append('"');
        }
        return sb.append(']').toString();
    }

    private static String bits(double d) { return "0x" + Long.toHexString(Double.doubleToRawLongBits(d)); }
}
