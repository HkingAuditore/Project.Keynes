package org.fmod;

/**
 * Stub for FMOD's hardware-decoder bridge.
 *
 * 签名是从设备 logcat 里 FMOD 自己的 RegisterNatives 报错反推出来的（权威来源）：
 *   Failed to register native method org.fmod.MediaCodec.fmodReadAt(JJ[BII)I
 *   -> fmodReadAt(long, long, byte[], int, int) : int
 *   fmodGetSize(J)I 与我们的声明一致，注册是通过的。
 *
 * FMOD 对 MediaCodec 注册失败只打一条 "Failed to register native MediaCodec
 * methods" 然后继续；但 pending 的 NoSuchMethodError 会被后续 JNI 调用踩到
 * （CheckJNI abort），所以这里必须签对。
 */
public final class MediaCodec {
    private MediaCodec() {
    }

    public static native long fmodGetSize(long handle);

    public static native int fmodReadAt(long handle, long position, byte[] buffer,
            int offset, int size);
}
