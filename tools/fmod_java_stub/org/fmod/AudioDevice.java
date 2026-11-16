package org.fmod;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;

/**
 * Minimal stand-in for FMOD's Android audio-device class.
 *
 * 真实 fmod.jar 里这个类包着一个 AudioTrack，native 侧通过它输出声音。我们没有
 * 官方 jar，所以这里自己实现：`init` 能建 AudioTrack 就建，建不了也返回 true，
 * 目的是让 FMOD 认为设备可用、继续把 system 建起来（验证 bank/事件链路）；音质
 * 不是目标，参数含义按 FMOD 的调用顺序打日志，真机上再据此校准。
 */
public final class AudioDevice {
    private static final String TAG = "FmodStub";

    public int id = -1;
    public String name = "";
    public int type = 0;
    public String guid = "";
    public int channels = 2;
    public int sampleRate = 48000;

    private AudioTrack track;

    public AudioDevice() {
    }

    /** FMOD 反射表里出现过的初始化入口（android.content.Context）。 */
    public void init(android.content.Context context) {
        Log.i(TAG, "AudioDevice.init(Context)");
    }

    /**
     * 设备初始化。四个 int 的语义 FMOD 没有公开文档，这里先按
     * "哪个像采样率就用哪个、哪个像声道数就用哪个"的宽松策略，并把原始值打出来。
     * 永远返回 true：即使建不出 AudioTrack，也让 FMOD 继续往下走。
     */
    public boolean init(int arg0, int arg1, int arg2, int arg3) {
        Log.i(TAG, "AudioDevice.init(" + arg0 + ", " + arg1 + ", " + arg2 + ", " + arg3 + ")");
        int rate = 48000;
        int channelCount = 2;
        if (arg0 >= 8000 && arg0 <= 192000) {
            rate = arg0;
        } else if (arg1 >= 8000 && arg1 <= 192000) {
            rate = arg1;
        }
        if (arg1 == 1 || arg1 == 2) {
            channelCount = arg1;
        } else if (arg2 == 1 || arg2 == 2) {
            channelCount = arg2;
        }
        this.sampleRate = rate;
        this.channels = channelCount;
        try {
            int channelMask = channelCount == 1
                    ? AudioFormat.CHANNEL_OUT_MONO
                    : AudioFormat.CHANNEL_OUT_STEREO;
            int minBuffer = AudioTrack.getMinBufferSize(rate, channelMask,
                    AudioFormat.ENCODING_PCM_16BIT);
            int bufferSize = Math.max(minBuffer, rate / 10 * channelCount * 2);
            track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_GAME)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(channelMask)
                            .build())
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            track.play();
            Log.i(TAG, "AudioTrack started rate=" + rate + " channels=" + channelCount
                    + " buffer=" + bufferSize);
        } catch (Throwable error) {
            Log.w(TAG, "AudioTrack unavailable: " + error);
            track = null;
        }
        return true;
    }

    /** native 侧 AudioTrack.write(short[], ...) 的等价物。 */
    public void write(short[] data, int size) {
        if (track == null || data == null) {
            return;
        }
        try {
            track.write(data, 0, Math.min(size, data.length));
        } catch (Throwable ignored) {
        }
    }

    public void close() {
        if (track != null) {
            try {
                track.stop();
            } catch (Throwable ignored) {
            }
            track.release();
            track = null;
        }
    }

    public int getId() {
        return id;
    }

    public int getType() {
        return type;
    }

    public String getName() {
        return name;
    }

    @Override
    public String toString() {
        return "AudioDevice{id=" + id + ", name='" + name + "', type=" + type + "}";
    }
}
