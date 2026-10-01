package android.os;

/** Compile/run stub so the Android app's Parcelable models load on a desktop JVM (LyricsGen only). */
public interface Parcelable {
    int describeContents();
    void writeToParcel(Parcel dest, int flags);
    interface Creator<T> {
        T createFromParcel(Parcel source);
        T[] newArray(int size);
    }
}
