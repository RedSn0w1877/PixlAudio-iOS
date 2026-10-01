package android.graphics;

/**
 * Minimal desktop stand-in for android.graphics.Color (android.jar only has stubs that throw), so AndroidX
 * ColorUtils.colorToHSL / HSLToColor run on the JVM for ThemeGen. Same bit layout as the platform class.
 * Put the compiled class before android.jar on the classpath.
 */
public class Color {
    public static int alpha(int color) { return color >>> 24; }
    public static int red(int color) { return (color >> 16) & 0xFF; }
    public static int green(int color) { return (color >> 8) & 0xFF; }
    public static int blue(int color) { return color & 0xFF; }
    public static int rgb(int red, int green, int blue) {
        return 0xff000000 | (red << 16) | (green << 8) | blue;
    }
    public static int argb(int alpha, int red, int green, int blue) {
        return (alpha << 24) | (red << 16) | (green << 8) | blue;
    }
}
