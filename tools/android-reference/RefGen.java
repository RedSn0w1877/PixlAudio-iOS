import androidx.compose.animation.core.*;
import java.util.*;

/**
 * Prints reference vectors from the real Compose animation-core classes (FloatSpringSpec, CubicBezierEasing,
 * FloatExponentialDecaySpec) for PixlFoundation's ComposeReferenceTests. See README.md for the classpath.
 */
public class RefGen {
    static String f(float v) { return String.format("0x%08X", Float.floatToRawIntBits(v)); }
    public static void main(String[] args) {
        StringBuilder sb = new StringBuilder();
        // ---- springs
        float[][] cfg = {
            {1.1f / (float)Math.sqrt(0.9f), (170f + 50f) / 0.9f, 0.5f},  // normal fastest
            {1.1f / (float)Math.sqrt(0.9f), 170f / 0.9f, 0.5f},          // normal slowest
            {15f / (2f * (float)Math.sqrt(90f * 0.9f)), 90f / 0.9f, 0.5f}, // slow
            {22f / (2f * (float)Math.sqrt(140f * 0.9f)), 140f / 0.9f, 0.5f}, // ended
            {25f / (2f * (float)Math.sqrt(100f * 2f)), 100f / 2f, 0.0005f}, // scale
            {0.9f, 150f, 0.001f},  // background
            {1.0f, 200f, 0.01f},   // critical
            {1.0f, 1500f, 0.01f},  // critical, medium stiffness
            {0.2f, 400f, 0.01f},   // bouncy
            {0.0f, 100f, 0.01f},   // undamped
            {2.0f, 50f, 0.01f},    // overdamped
            {5.0f, 1500f, 0.01f},  // heavily overdamped
        };
        float[][] starts = { {0f, 100f, 0f}, {250f, -40f, 800f}, {1f, 0.97f, 0f}, {-12.5f, 30f, -300f}, {0f, 0f, 50f} };
        long[] times = {0L, 999_999L, 1_000_000L, 8_333_333L, 16_666_667L, 33_333_334L, 50_000_000L, 100_000_000L,
                        250_000_000L, 500_000_000L, 1_000_000_000L, 2_500_000_000L};
        sb.append("// springs: dampingRatio, stiffness, threshold, initial, target, velocity0, nanos, value, velocity\n");
        for (float[] c : cfg) {
            FloatSpringSpec s = new FloatSpringSpec(c[0], c[1], c[2]);
            for (float[] st : starts) {
                for (long t : times) {
                    float v = s.getValueFromNanos(t, st[0], st[1], st[2]);
                    float vel = s.getVelocityFromNanos(t, st[0], st[1], st[2]);
                    sb.append(String.format("S %s %s %s %s %s %s %d %s %s\n", f(c[0]), f(c[1]), f(c[2]), f(st[0]), f(st[1]), f(st[2]), t, f(v), f(vel)));
                }
                long d = s.getDurationNanos(st[0], st[1], st[2]);
                sb.append(String.format("D %s %s %s %s %s %s %d\n", f(c[0]), f(c[1]), f(c[2]), f(st[0]), f(st[1]), f(st[2]), d));
            }
        }
        // ---- cubic bezier
        float[][] curves = { {0f,0f,0.58f,1f}, {0.2f,0.4f,0.58f,1f}, {0.3f,0f,0.58f,1f}, {0.4f,0f,0.2f,1f},
                             {0f,0f,0.2f,1f}, {0.4f,0f,1f,1f}, {0.34f,1.56f,0.64f,1f}, {0.68f,-0.6f,0.32f,1.6f},
                             {0.25f,0.1f,0.25f,1f}, {0.42f,0f,0.58f,1f}, {0f,0f,1f,1f}, {0.5f,-0.5f,0.5f,1.5f} };
        for (float[] c : curves) {
            CubicBezierEasing e = new CubicBezierEasing(c[0], c[1], c[2], c[3]);
            for (int i = -2; i <= 202; i++) {
                float x = i / 200f;
                float y = e.transform(x);
                sb.append(String.format("B %s %s %s %s %s %s\n", f(c[0]), f(c[1]), f(c[2]), f(c[3]), f(x), f(y)));
            }
            float[] odd = {1e-9f, 1e-7f, 0.999999f, 0.3333333f};
            for (float x : odd) sb.append(String.format("B %s %s %s %s %s %s\n", f(c[0]), f(c[1]), f(c[2]), f(c[3]), f(x), f(e.transform(x))));
        }
        // ---- decay
        float[][] decays = { {0.733f, 50f}, {1f, 0.1f}, {2f, 5f} };
        float[] vels = {100f, -100f, 2500f, -8000f, 51f};
        for (float[] dcfg : decays) {
            FloatExponentialDecaySpec d = new FloatExponentialDecaySpec(dcfg[0], dcfg[1]);
            for (float v0 : vels) {
                float init = 37.5f;
                for (long t : times) {
                    sb.append(String.format("X %s %s %s %s %d %s %s\n", f(dcfg[0]), f(dcfg[1]), f(init), f(v0), t,
                        f(d.getValueFromNanos(t, init, v0)), f(d.getVelocityFromNanos(t, init, v0))));
                }
                sb.append(String.format("Y %s %s %s %s %d %s\n", f(dcfg[0]), f(dcfg[1]), f(init), f(v0),
                    d.getDurationNanos(init, v0), f(d.getTargetValue(init, v0))));
            }
        }
        System.out.print(sb);
    }
}
