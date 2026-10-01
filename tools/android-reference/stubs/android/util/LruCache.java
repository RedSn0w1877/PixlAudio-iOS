package android.util;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Minimal desktop stand-in for android.util.LruCache so ArtworkSpriteBaker's static initialiser runs on the JVM
 * (android.jar only has stubs that throw). Put the compiled class before android.jar on the classpath.
 */
public class LruCache<K, V> {
    private final int maxSize;
    private final LinkedHashMap<K, V> map = new LinkedHashMap<>(16, 0.75f, true);

    public LruCache(int maxSize) { this.maxSize = maxSize; }

    public synchronized V get(K key) { return map.get(key); }

    public synchronized V put(K key, V value) {
        V old = map.put(key, value);
        while (map.size() > maxSize) {
            Map.Entry<K, V> eldest = map.entrySet().iterator().next();
            map.remove(eldest.getKey());
        }
        return old;
    }
}
