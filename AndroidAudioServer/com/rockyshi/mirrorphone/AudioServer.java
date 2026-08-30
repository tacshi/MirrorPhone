package com.rockyshi.mirrorphone;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Looper;
import android.util.Log;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;

/**
 * Minimal scrcpy-style audio capturer. It is launched on the device via
 * {@code app_process} as the shell user (uid 2000). Captured 48 kHz / stereo /
 * 16-bit little-endian PCM is written straight to stdout, which
 * {@code adb exec-out} streams back to the Mac unmodified.
 *
 * <p>On Android 13+ it captures through a dynamic audio-policy mix with the
 * {@code LOOP_BACK} route flag (the mechanism behind scrcpy's
 * {@code --audio-source=playback}): streams that were already playing when
 * capture starts are re-routed into the mix, and the device itself goes
 * silent while mirroring — matching how iOS/iPadOS mirroring behaves. Sound
 * returns to the device when this process exits and the policy dies with it.
 * On Android 11–12 it falls back to {@code REMOTE_SUBMIX}, which also
 * silences the device but misses streams that were already playing.
 */
public final class AudioServer {
  private static final int SAMPLE_RATE = 48_000;
  private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;
  private static final int ENCODING = AudioFormat.ENCODING_PCM_16BIT;
  private static final int BYTES_PER_FRAME = 4; // 2 channels * 16-bit
  // Diagnostics go to logcat: `adb exec-out` merges the remote stderr into the
  // stream the Mac plays, so nothing but PCM may be written to either fd.
  private static final String TAG = "mirrorphone-audio";

  // android.media.audiopolicy hidden-API constants.
  private static final int RULE_MATCH_ATTRIBUTE_USAGE = 0x1;
  private static final int ROUTE_FLAG_RENDER = 0x1;
  private static final int ROUTE_FLAG_LOOP_BACK = 0x2;

  @SuppressWarnings("deprecation") // prepareMainLooper is required for app_process servers
  public static void main(String[] args) {
    try {
      // Some framework paths create Handlers on the "main" thread.
      Looper.prepareMainLooper();
    } catch (Throwable ignored) {
    }
    try {
      capture();
    } catch (Throwable error) {
      Log.e(TAG, "capture failed", error);
      System.exit(1);
    }
  }

  private static void capture() throws Exception {
    AudioRecord record = null;
    if (Build.VERSION.SDK_INT >= 33) {
      try {
        record = createPlaybackCaptureRecord();
        Log.i(TAG, "playback capture active (device muted while mirroring)");
      } catch (Throwable error) {
        Log.w(TAG, "playback capture unavailable; falling back to REMOTE_SUBMIX", error);
      }
    }
    if (record == null) {
      record = createRemoteSubmixRecord();
    }

    record.startRecording();
    OutputStream out = new FileOutputStream(FileDescriptor.out);
    byte[] chunk = new byte[chunkSize()];
    try {
      while (true) {
        int read = record.read(chunk, 0, chunk.length);
        if (read < 0) {
          throw new IllegalStateException("AudioRecord.read failed with " + read);
        }
        if (read > 0) {
          out.write(chunk, 0, read);
          out.flush();
        }
      }
    } finally {
      record.stop();
      record.release();
    }
  }

  private static int chunkSize() {
    int minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, ENCODING);
    if (minBuffer <= 0) {
      minBuffer = SAMPLE_RATE * BYTES_PER_FRAME / 10; // ~100 ms fallback
    }
    return minBuffer;
  }

  private static AudioRecord createRemoteSubmixRecord() {
    int chunk = chunkSize();
    AudioRecord record =
        new AudioRecord(
            MediaRecorder.AudioSource.REMOTE_SUBMIX,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            ENCODING,
            Math.max(chunk, SAMPLE_RATE * BYTES_PER_FRAME / 5)); // ~200 ms buffer

    if (record.getState() != AudioRecord.STATE_INITIALIZED) {
      record.release();
      throw new IllegalStateException("REMOTE_SUBMIX capture is unavailable on this device");
    }
    return record;
  }

  /**
   * Registers an {@code AudioPolicy} whose mix matches media playback by usage
   * and both renders it on the device and loops it back to an AudioRecord.
   * Everything lives in {@code android.media.audiopolicy}, which is hidden, so
   * it is reached by reflection (the same way scrcpy does).
   */
  private static AudioRecord createPlaybackCaptureRecord() throws Exception {
    Class<?> ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule");
    Class<?> ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
    Object ruleBuilder = ruleBuilderClass.getConstructor().newInstance();
    int[] usages = {
      AudioAttributes.USAGE_UNKNOWN, AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_GAME,
    };
    for (int usage : usages) {
      AudioAttributes attributes = new AudioAttributes.Builder().setUsage(usage).build();
      addMixRule(ruleBuilderClass, ruleBuilder, attributes);
    }
    Object rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder);

    // Mixes use output channel masks; createAudioRecordSink derives the
    // matching input mask itself.
    AudioFormat mixFormat =
        new AudioFormat.Builder()
            .setEncoding(ENCODING)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build();

    Class<?> mixClass = Class.forName("android.media.audiopolicy.AudioMix");
    Class<?> mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix$Builder");
    Object mixBuilder = mixBuilderClass.getConstructor(ruleClass).newInstance(rule);
    mixBuilderClass.getMethod("setFormat", AudioFormat.class).invoke(mixBuilder, mixFormat);
    // LOOP_BACK without RENDER: captured streams play only on the Mac and the
    // device stays silent while mirroring, like iOS/iPadOS mirroring. Adding
    // ROUTE_FLAG_RENDER would duplicate the sound on the device instead.
    mixBuilderClass.getMethod("setRouteFlags", int.class).invoke(mixBuilder, ROUTE_FLAG_LOOP_BACK);
    Object mix = mixBuilderClass.getMethod("build").invoke(mixBuilder);

    Context context = ShellContext.create();
    Class<?> policyClass = Class.forName("android.media.audiopolicy.AudioPolicy");
    Class<?> policyBuilderClass = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");
    Object policyBuilder = policyBuilderClass.getConstructor(Context.class).newInstance(context);
    policyBuilderClass.getMethod("addMix", mixClass).invoke(policyBuilder, mix);
    Object policy = policyBuilderClass.getMethod("build").invoke(policyBuilder);

    AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    Method register = AudioManager.class.getMethod("registerAudioPolicy", policyClass);
    int status = (Integer) register.invoke(audioManager, policy);
    if (status != 0) {
      throw new IllegalStateException("registerAudioPolicy failed with " + status);
    }

    AudioRecord record =
        (AudioRecord) policyClass.getMethod("createAudioRecordSink", mixClass).invoke(policy, mix);
    if (record == null || record.getState() != AudioRecord.STATE_INITIALIZED) {
      if (record != null) {
        record.release();
      }
      // Leaving the render+loopback mix registered without a sink would keep
      // re-routing media, so tear it down before the REMOTE_SUBMIX fallback.
      try {
        AudioManager.class
            .getMethod("unregisterAudioPolicyAsync", policyClass)
            .invoke(audioManager, policy);
      } catch (Throwable ignored) {
      }
      throw new IllegalStateException("playback-capture AudioRecord failed to initialize");
    }
    // On success the policy is intentionally never unregistered: it must
    // outlive this method, and audioserver cleans it up when the process dies.
    return record;
  }

  private static void addMixRule(Class<?> builderClass, Object builder, AudioAttributes attributes)
      throws Exception {
    try {
      builderClass
          .getMethod("addMixRule", int.class, Object.class)
          .invoke(builder, RULE_MATCH_ATTRIBUTE_USAGE, attributes);
    } catch (NoSuchMethodException error) {
      builderClass
          .getMethod("addRule", AudioAttributes.class, int.class)
          .invoke(builder, attributes, RULE_MATCH_ATTRIBUTE_USAGE);
    }
  }

}
