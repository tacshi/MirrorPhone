package com.rockyshi.mirrorphone;

import android.os.SystemClock;
import android.util.Log;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

/**
 * Minimal scrcpy-style touch injector. It is launched on the device via
 * {@code app_process} as the shell user (uid 2000, which holds INJECT_EVENTS)
 * and reads one event per line on stdin, which {@code adb exec-out} forwards
 * raw from the Mac:
 *
 * <pre>
 * d &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;   finger down at (x,y), coords relative to a w×h video frame
 * m &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;   move
 * u &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;   up
 * c                     cancel the current gesture
 * k &lt;d|u&gt; &lt;keycode&gt; &lt;metaState&gt;   Android key down/up (arrows, enter, shortcuts…)
 * t &lt;text&gt;              type percent-encoded UTF-8 text like a hardware keyboard
 * </pre>
 *
 * <p>Coordinates are carried in video-frame pixels because screenrecord may
 * stream below the panel's real resolution; the current logical display size
 * is fetched at each finger-down and the coordinates rescaled to it. A single
 * {@code READY} line is written to stdout once the injector is resolved;
 * diagnostics go to logcat because exec-out merges the remote stderr into the
 * stream the Mac reads.
 */
public final class InputServer {
  private static final String TAG = "mirrorphone-input";
  /** InputManager.INJECT_INPUT_EVENT_MODE_ASYNC (hidden constant). */
  private static final int INJECT_MODE_ASYNC = 0;

  private static Object injectTarget;
  private static Method injectMethod;
  private static Method setDisplayIdMethod;
  private static Object displayManagerGlobal;
  private static Method getDisplayInfoMethod;
  private static Field logicalWidthField;
  private static Field logicalHeightField;

  public static void main(String[] args) throws Exception {
    resolveInjector();
    resolveDisplayInfo();

    System.out.println("READY");
    System.out.flush();

    BufferedReader in =
        new BufferedReader(new InputStreamReader(System.in, StandardCharsets.US_ASCII));
    boolean touching = false;
    long downTime = 0;
    float scaleX = 1f;
    float scaleY = 1f;
    float lastX = 0f;
    float lastY = 0f;

    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) {
        continue;
      }
      char op = line.charAt(0);
      long now = SystemClock.uptimeMillis();

      if (op == 'c') {
        if (touching) {
          touching = false;
          inject(MotionEvent.ACTION_CANCEL, downTime, now, lastX, lastY, 0f);
        }
        continue;
      }
      if (op == 'k') {
        handleKey(line);
        continue;
      }
      if (op == 't') {
        typeText(line.length() > 2 ? line.substring(2) : "");
        continue;
      }

      float x;
      float y;
      int frameWidth;
      int frameHeight;
      try {
        String[] parts = line.split(" ");
        x = Float.parseFloat(parts[1]);
        y = Float.parseFloat(parts[2]);
        frameWidth = Integer.parseInt(parts[3]);
        frameHeight = Integer.parseInt(parts[4]);
      } catch (RuntimeException error) {
        Log.w(TAG, "malformed event line: " + line);
        continue;
      }

      switch (op) {
        case 'd':
          downTime = now;
          touching = true;
          float[] scale = frameToDisplayScale(frameWidth, frameHeight);
          scaleX = scale[0];
          scaleY = scale[1];
          lastX = x * scaleX;
          lastY = y * scaleY;
          inject(MotionEvent.ACTION_DOWN, downTime, now, lastX, lastY, 1f);
          break;
        case 'm':
          if (touching) {
            lastX = x * scaleX;
            lastY = y * scaleY;
            inject(MotionEvent.ACTION_MOVE, downTime, now, lastX, lastY, 1f);
          }
          break;
        case 'u':
          if (touching) {
            touching = false;
            lastX = x * scaleX;
            lastY = y * scaleY;
            inject(MotionEvent.ACTION_UP, downTime, now, lastX, lastY, 0f);
          }
          break;
        default:
          Log.w(TAG, "unknown event op: " + line);
          break;
      }
    }

    // stdin EOF: the adb stream closed (Mac quit or unplugged). Never leave a
    // finger stuck on the device.
    if (touching) {
      inject(MotionEvent.ACTION_CANCEL, downTime, SystemClock.uptimeMillis(), lastX, lastY, 0f);
    }
  }

  /**
   * InputManager.getInstance() is hidden and was moved to InputManagerGlobal
   * on Android 14; both expose injectInputEvent(InputEvent, int).
   */
  private static void resolveInjector() {
    for (String className :
        new String[] {
          "android.hardware.input.InputManager", "android.hardware.input.InputManagerGlobal",
        }) {
      try {
        Class<?> managerClass = Class.forName(className);
        Object instance = managerClass.getMethod("getInstance").invoke(null);
        Method method = managerClass.getMethod("injectInputEvent", InputEvent.class, int.class);
        injectTarget = instance;
        injectMethod = method;
        try {
          // Injected events default to INVALID_DISPLAY; the framework then drops
          // them for windows on the default display. Target display 0 explicitly.
          setDisplayIdMethod = MotionEvent.class.getMethod("setDisplayId", int.class);
        } catch (Throwable error) {
          Log.w(TAG, "MotionEvent.setDisplayId unavailable", error);
        }
        return;
      } catch (Throwable error) {
        Log.w(TAG, "injector unavailable via " + className, error);
      }
    }
    Log.e(TAG, "no input injection path on this device");
    System.exit(1);
  }

  /** DisplayManagerGlobal.getDisplayInfo(0) → DisplayInfo.logicalWidth/Height. */
  private static void resolveDisplayInfo() {
    try {
      Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
      displayManagerGlobal = globalClass.getMethod("getInstance").invoke(null);
      getDisplayInfoMethod = globalClass.getMethod("getDisplayInfo", int.class);
      Class<?> infoClass = Class.forName("android.view.DisplayInfo");
      logicalWidthField = infoClass.getField("logicalWidth");
      logicalHeightField = infoClass.getField("logicalHeight");
    } catch (Throwable error) {
      Log.w(TAG, "display size unavailable; injecting frame coordinates as-is", error);
      displayManagerGlobal = null;
    }
  }

  /**
   * Scale factors from video-frame pixels to the current logical display,
   * fetched per gesture so rotation is picked up. If the frame and display
   * orientations disagree (rotation race while screenrecord restarts), the
   * display dimensions are swapped so the scale stays sane; the Mac cancels
   * the gesture on rotation anyway.
   */
  private static float[] frameToDisplayScale(int frameWidth, int frameHeight) {
    if (displayManagerGlobal == null || frameWidth <= 0 || frameHeight <= 0) {
      return new float[] {1f, 1f};
    }
    try {
      Object info = getDisplayInfoMethod.invoke(displayManagerGlobal, 0);
      int displayWidth = logicalWidthField.getInt(info);
      int displayHeight = logicalHeightField.getInt(info);
      if (displayWidth <= 0 || displayHeight <= 0) {
        return new float[] {1f, 1f};
      }
      if ((frameWidth > frameHeight) != (displayWidth > displayHeight)) {
        int swap = displayWidth;
        displayWidth = displayHeight;
        displayHeight = swap;
      }
      return new float[] {(float) displayWidth / frameWidth, (float) displayHeight / frameHeight};
    } catch (Throwable error) {
      Log.w(TAG, "failed to read display size", error);
      return new float[] {1f, 1f};
    }
  }

  /** Wall clock of the last key-down per keycode, so up events pair correctly. */
  private static final long[] keyDownTimes = new long[KeyEvent.getMaxKeyCode() + 1];

  /** Parses and injects "k <d|u> <keycode> <metaState>". */
  private static void handleKey(String line) {
    boolean down;
    int keyCode;
    int metaState;
    try {
      String[] parts = line.split(" ");
      down = parts[1].equals("d");
      keyCode = Integer.parseInt(parts[2]);
      metaState = Integer.parseInt(parts[3]);
    } catch (RuntimeException error) {
      Log.w(TAG, "malformed key line: " + line);
      return;
    }
    long now = SystemClock.uptimeMillis();
    long downTime = now;
    if (keyCode >= 0 && keyCode < keyDownTimes.length) {
      if (down) {
        keyDownTimes[keyCode] = now;
      } else if (keyDownTimes[keyCode] != 0) {
        downTime = keyDownTimes[keyCode];
      }
    }
    KeyEvent event =
        new KeyEvent(
            downTime,
            now,
            down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
            keyCode,
            0 /* repeat */,
            metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            0 /* scancode */,
            0 /* flags */,
            InputDevice.SOURCE_KEYBOARD);
    injectKeyEvent(event);
  }

  /** Types percent-encoded UTF-8 text through the virtual keyboard map. */
  private static void typeText(String encoded) {
    String text;
    try {
      text = URLDecoder.decode(encoded, "UTF-8");
    } catch (Exception error) {
      Log.w(TAG, "malformed text line", error);
      return;
    }
    if (text.isEmpty()) {
      return;
    }
    KeyCharacterMap map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
    KeyEvent[] events = map.getEvents(text.toCharArray());
    if (events == null) {
      Log.w(TAG, "no key mapping for text: " + text);
      return;
    }
    long now = SystemClock.uptimeMillis();
    for (KeyEvent event : events) {
      injectKeyEvent(KeyEvent.changeTimeRepeat(event, now, 0));
    }
  }

  private static void injectKeyEvent(KeyEvent event) {
    try {
      boolean accepted = (Boolean) injectMethod.invoke(injectTarget, event, INJECT_MODE_ASYNC);
      if (!accepted) {
        Log.w(TAG, "key injection rejected (secure screen?)");
      }
    } catch (Throwable error) {
      Log.w(TAG, "injectInputEvent(key) failed", error);
    }
  }

  private static void inject(
      int action, long downTime, long eventTime, float x, float y, float pressure) {
    MotionEvent.PointerProperties properties = new MotionEvent.PointerProperties();
    properties.id = 0;
    properties.toolType = MotionEvent.TOOL_TYPE_FINGER;
    MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
    coords.x = x;
    coords.y = y;
    coords.pressure = pressure;
    coords.size = 1f;

    MotionEvent event =
        MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            1,
            new MotionEvent.PointerProperties[] {properties},
            new MotionEvent.PointerCoords[] {coords},
            0 /* metaState */,
            0 /* buttonState */,
            1f,
            1f /* precision */,
            -1 /* deviceId: virtual */,
            0 /* edgeFlags */,
            InputDevice.SOURCE_TOUCHSCREEN,
            0 /* flags */);
    if (setDisplayIdMethod != null) {
      try {
        setDisplayIdMethod.invoke(event, 0);
      } catch (Throwable error) {
        Log.w(TAG, "setDisplayId failed", error);
      }
    }
    try {
      boolean accepted = (Boolean) injectMethod.invoke(injectTarget, event, INJECT_MODE_ASYNC);
      if (!accepted) {
        Log.w(TAG, "injection rejected (secure screen?)");
      }
    } catch (Throwable error) {
      Log.w(TAG, "injectInputEvent failed", error);
    } finally {
      event.recycle();
    }
  }

  private InputServer() {}
}
