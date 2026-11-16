package org.fmod;

/**
 * Minimal stand-in for FMOD's own fmod.jar class.
 *
 * Why: FMOD's Android runtime calls FindClass("org/fmod/FMOD") during JNI_OnLoad and
 * RegisterNatives on it. Without that class the process aborts inside CheckJNI
 * ("JNI FindClass called with pending exception java.lang.ClassNotFoundException:
 * org.fmod.FMOD"). The official class ships in fmod.jar inside the FMOD Android SDK;
 * this stub only declares the natives the native library registers, so that
 * JNI_OnLoad completes and FMOD can be initialised through
 * FMOD_Android_JNI_Init (see addons/fmod_android_bootstrap).
 *
 * Signatures are the ones FMOD's callbacks use: no arguments, void return. If
 * RegisterNatives complains ("Failed to register ... methods. JNI result: %d" in
 * logcat, tag "fmod"), fix the signature here and rebuild the dex.
 */
public final class FMOD {
    private FMOD() {
    }

    public static native void SetInputEnumerationChanged();

    public static native void SetOutputEnumerationChanged();

    public static native void OutputAAudioHeadphonesChanged();

    /**
     * FMOD 的 native 侧会 GetStaticMethodID("checkInit", "()Z")。官方实现里它是
     * "Java 层是否已经 init 过"的开关（init() 成功后返回 true）。我们是从 native
     * 走 FMOD_Android_JNI_Init 初始化的，Java 层什么都没做，所以返回 false，
     * 让 FMOD 走它自己的 native 初始化路径。
     */
    public static boolean checkInit() {
        return false;
    }

    /** 录制预设名；native 侧按字段读取（GetFieldID）。 */
    public static String androidRecordingPreset = "";

    /** native 会 GetStaticMethodID("supportsLowLatency", "()Z")。 */
    public static boolean supportsLowLatency() {
        return false;
    }

    /** native 会 GetStaticMethodID("supportsAAudio", "()Z")。 */
    public static boolean supportsAAudio() {
        return false;
    }

    /**
     * 由 FMOD 的 JNI 反射表反推出来的成员（签名见
     * Build/PK_AUDIO_FMOD_ANDROID_REPORT.md §6）：`(Ljava/lang/String;)I`。
     * 语义是"把 content:// URI 变成 fd"，我们没有任何 Java 侧初始化，返回 -1。
     */
    public static int fileDescriptorFromUri(String uri) {
        return -1;
    }
}
