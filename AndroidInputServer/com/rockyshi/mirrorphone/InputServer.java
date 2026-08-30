package com.rockyshi.mirrorphone;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Looper;
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
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * Minimal scrcpy-style input and clipboard server. It runs as the shell user
 * (uid 2000), reads ASCII commands on stdin, and writes framed responses to
 * stdout. Diagnostics always go to logcat.
 *
 * <pre>
 * d|m|u &lt;x&gt; &lt;y&gt; &lt;w&gt; &lt;h&gt;         touch down/move/up
 * c                                   cancel the current gesture
 * k &lt;d|u&gt; &lt;keycode&gt; &lt;metaState&gt;     Android key event
 * t &lt;percent-encoded UTF-8&gt;          type as virtual-keyboard events
 * cb-read &lt;id&gt; &lt;copy|cut&gt;           copy/cut, then return the device clipboard
 * cb-paste &lt;id&gt; &lt;base64|-&gt;          set plain text and inject PASTE
 * </pre>
 */
public final class InputServer {
  private static final String TAG = "mirrorphone-input";
  private static final int INJECT_MODE_ASYNC = 0;
  private static final int INJECT_MODE_WAIT_FOR_FINISH = 2;
  private static final int MAX_CLIPBOARD_BYTES = 256 * 1024;
  private static final Object OUTPUT_LOCK = new Object();

  private static Object injectTarget;
  private static Method injectMethod;
  private static Method setDisplayIdMethod;
  private static Object displayManagerGlobal;
  private static Method getDisplayInfoMethod;
  private static Field logicalWidthField;
  private static Field logicalHeightField;
  private static ClipboardBridge clipboardBridge;

  @SuppressWarnings("deprecation")
  public static void main(String[] args) throws Exception {
    try {
      Looper.prepareMainLooper();
    } catch (Throwable ignored) {
    }

    resolveInjector();
    resolveDisplayInfo();
    clipboardBridge = ClipboardBridge.create();
    String clipboardCapability = clipboardBridge.startListening();

    sendLine("READY clipboard=" + clipboardCapability);

    Thread commandThread =
        new Thread(
            () -> {
              try {
                runCommandLoop();
              } catch (Throwable error) {
                Log.e(TAG, "command loop failed", error);
              } finally {
                Looper mainLooper = Looper.getMainLooper();
                if (mainLooper != null) {
                  mainLooper.quitSafely();
                }
              }
            },
            "mirrorphone-input-commands");
    commandThread.start();

    Looper.loop();
    clipboardBridge.stopListening();
    commandThread.join(1_000);
  }

  private static void runCommandLoop() throws Exception {
    BufferedReader in =
        new BufferedReader(new InputStreamReader(System.in, StandardCharsets.US_ASCII));
    boolean touching = false;
    long downTime = 0;
    float scaleX = 1f;
    float scaleY = 1f;
    float lastX = 0f;
    float lastY = 0f;

    try {
      String line;
      while ((line = in.readLine()) != null) {
        line = line.trim();
        if (line.isEmpty()) {
          continue;
        }
        if (line.startsWith("cb-read ")) {
          handleClipboardRead(line);
          continue;
        }
        if (line.startsWith("cb-paste ")) {
          handleClipboardPaste(line);
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
    } finally {
      if (touching) {
        inject(
            MotionEvent.ACTION_CANCEL,
            downTime,
            SystemClock.uptimeMillis(),
            lastX,
            lastY,
            0f);
      }
    }
  }

  private static void handleClipboardRead(String line) {
    String requestID = "0";
    try {
      String[] parts = line.split(" ", 3);
      if (parts.length != 3) {
        throw new IllegalArgumentException("Malformed clipboard read request");
      }
      requestID = validatedRequestID(parts[1]);
      int keyCode;
      if ("copy".equals(parts[2])) {
        keyCode = KeyEvent.KEYCODE_COPY;
      } else if ("cut".equals(parts[2])) {
        keyCode = KeyEvent.KEYCODE_CUT;
      } else {
        throw new IllegalArgumentException("Unknown clipboard selection operation");
      }

      if (!clipboardBridge.isAvailable()) {
        throw new IllegalStateException("Android clipboard access is unavailable on this device");
      }
      if (!pressAndReleaseKey(keyCode, INJECT_MODE_WAIT_FOR_FINISH)) {
        throw new IllegalStateException("Android rejected the copy or cut key event");
      }
      sendContent("cb-result " + requestID, clipboardBridge.readContent());
    } catch (Throwable error) {
      clipboardBridge.handleOperationFailure(error);
      sendError(requestID, error);
    }
  }

  private static void handleClipboardPaste(String line) {
    String requestID = "0";
    try {
      String[] parts = line.split(" ", 3);
      if (parts.length != 3) {
        throw new IllegalArgumentException("Malformed clipboard paste request");
      }
      requestID = validatedRequestID(parts[1]);
      String text = decodeText(parts[2]);
      if (!clipboardBridge.isAvailable()) {
        throw new IllegalStateException("Android clipboard access is unavailable on this device");
      }
      clipboardBridge.setText(text);
      if (!pressAndReleaseKey(KeyEvent.KEYCODE_PASTE, INJECT_MODE_ASYNC)) {
        throw new IllegalStateException("Android set the clipboard but rejected the paste key event");
      }
      sendLine("cb-result " + requestID + " ok");
    } catch (Throwable error) {
      clipboardBridge.handleOperationFailure(error);
      sendError(requestID, error);
    }
  }

  private static String validatedRequestID(String value) {
    long id = Long.parseLong(value);
    if (id <= 0) {
      throw new IllegalArgumentException("Invalid clipboard request id");
    }
    return Long.toString(id);
  }

  private static String decodeText(String encoded) throws CharacterCodingException {
    byte[] bytes;
    if ("-".equals(encoded)) {
      bytes = new byte[0];
    } else {
      bytes = Base64.getDecoder().decode(encoded);
    }
    if (bytes.length > MAX_CLIPBOARD_BYTES) {
      throw new IllegalArgumentException("Clipboard text exceeds the 256 KiB limit");
    }
    return StandardCharsets.UTF_8
        .newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString();
  }

  private static String encodeText(String text) {
    byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
    if (bytes.length > MAX_CLIPBOARD_BYTES) {
      throw new IllegalArgumentException("Clipboard text exceeds the 256 KiB limit");
    }
    return bytes.length == 0 ? "-" : Base64.getEncoder().encodeToString(bytes);
  }

  private static void sendContent(String prefix, ClipboardContent content) {
    switch (content.kind) {
      case TEXT:
        sendLine(prefix + " text " + encodeText(content.text));
        break;
      case EMPTY:
        sendLine(prefix + " empty");
        break;
      case UNSUPPORTED:
        sendLine(prefix + " unsupported");
        break;
    }
  }

  private static void sendError(String requestID, Throwable error) {
    String message = error.getMessage();
    if (message == null || message.isEmpty()) {
      message = "Android clipboard request failed";
    }
    if (message.length() > 1_024) {
      message = message.substring(0, 1_024);
    }
    sendLine("cb-result " + requestID + " error " + encodeText(message));
  }

  private static void sendLine(String line) {
    synchronized (OUTPUT_LOCK) {
      System.out.println(line);
      System.out.flush();
    }
  }

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

  private static final long[] keyDownTimes = new long[KeyEvent.getMaxKeyCode() + 1];

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
    injectKeyEvent(
        createKeyEvent(down, downTime, now, keyCode, metaState),
        INJECT_MODE_ASYNC);
  }

  private static boolean pressAndReleaseKey(int keyCode, int mode) {
    long downTime = SystemClock.uptimeMillis();
    boolean downAccepted =
        injectKeyEvent(createKeyEvent(true, downTime, downTime, keyCode, 0), mode);
    long upTime = SystemClock.uptimeMillis();
    boolean upAccepted =
        injectKeyEvent(createKeyEvent(false, downTime, upTime, keyCode, 0), mode);
    return downAccepted && upAccepted;
  }

  private static KeyEvent createKeyEvent(
      boolean down, long downTime, long eventTime, int keyCode, int metaState) {
    return new KeyEvent(
        downTime,
        eventTime,
        down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
        keyCode,
        0,
        metaState,
        KeyCharacterMap.VIRTUAL_KEYBOARD,
        0,
        0,
        InputDevice.SOURCE_KEYBOARD);
  }

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
      injectKeyEvent(KeyEvent.changeTimeRepeat(event, now, 0), INJECT_MODE_ASYNC);
    }
  }

  private static boolean injectKeyEvent(KeyEvent event, int mode) {
    try {
      boolean accepted = (Boolean) injectMethod.invoke(injectTarget, event, mode);
      if (!accepted) {
        Log.w(TAG, "key injection rejected (secure screen?)");
      }
      return accepted;
    } catch (Throwable error) {
      Log.w(TAG, "injectInputEvent(key) failed", error);
      return false;
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
            0,
            0,
            1f,
            1f,
            -1,
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0);
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

  private enum ClipboardContentKind {
    TEXT,
    EMPTY,
    UNSUPPORTED,
  }

  private static final class ClipboardContent {
    final ClipboardContentKind kind;
    final String text;

    private ClipboardContent(ClipboardContentKind kind, String text) {
      this.kind = kind;
      this.text = text;
    }

    static ClipboardContent text(String text) {
      return new ClipboardContent(ClipboardContentKind.TEXT, text);
    }

    static ClipboardContent empty() {
      return new ClipboardContent(ClipboardContentKind.EMPTY, null);
    }

    static ClipboardContent unsupported() {
      return new ClipboardContent(ClipboardContentKind.UNSUPPORTED, null);
    }
  }

  private static final class ClipboardBridge {
    private final ClipboardManager manager;
    private ClipboardManager.OnPrimaryClipChangedListener listener;
    private boolean listening;
    private long eventSequence;
    private String capability;

    static ClipboardBridge create() {
      try {
        Context context = ShellContext.create();
        ClipboardManager manager =
            (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager == null) {
          return new ClipboardBridge(null);
        }
        return new ClipboardBridge(manager);
      } catch (Throwable error) {
        Log.w(TAG, "clipboard service unavailable", error);
        return new ClipboardBridge(null);
      }
    }

    private ClipboardBridge(ClipboardManager manager) {
      this.manager = manager;
      capability = manager == null ? "none" : "manual";
    }

    String startListening() {
      if (manager == null) {
        return "none";
      }
      listener = this::onPrimaryClipChanged;
      try {
        manager.addPrimaryClipChangedListener(listener);
        listening = true;
        capability = "sync";
      } catch (Throwable error) {
        Log.w(TAG, "automatic clipboard updates unavailable", error);
        capability = "manual";
      }
      return capability;
    }

    void stopListening() {
      if (!listening || manager == null || listener == null) {
        return;
      }
      listening = false;
      try {
        manager.removePrimaryClipChangedListener(listener);
      } catch (Throwable ignored) {
      }
    }

    boolean isAvailable() {
      return manager != null && !"none".equals(capability);
    }

    ClipboardContent readContent() {
      ClipData clip = manager.getPrimaryClip();
      if (clip == null || clip.getItemCount() == 0) {
        return ClipboardContent.empty();
      }
      CharSequence text = clip.getItemAt(0).getText();
      if (text == null) {
        return ClipboardContent.unsupported();
      }
      String value = text.toString();
      if (value.getBytes(StandardCharsets.UTF_8).length > MAX_CLIPBOARD_BYTES) {
        throw new IllegalArgumentException("Clipboard text exceeds the 256 KiB limit");
      }
      return ClipboardContent.text(value);
    }

    void setText(String text) {
      manager.setPrimaryClip(ClipData.newPlainText("MirrorPhone", text));
    }

    void handleOperationFailure(Throwable error) {
      if (error instanceof SecurityException) {
        markUnavailable("Android denied clipboard access to the shell helper");
      }
    }

    private void onPrimaryClipChanged() {
      if (!listening) {
        return;
      }
      try {
        sendContent("cb-event " + (++eventSequence), readContent());
      } catch (SecurityException error) {
        markUnavailable("Android denied background clipboard access");
      } catch (Throwable error) {
        Log.w(TAG, "automatic clipboard update failed; retaining manual commands", error);
        stopListening();
        capability = "manual";
        sendState("manual", "Automatic clipboard updates stopped on this device");
      }
    }

    private void markUnavailable(String reason) {
      stopListening();
      capability = "none";
      sendState("none", reason);
    }

    private void sendState(String state, String reason) {
      sendLine("cb-state " + state + " " + encodeText(reason));
    }
  }

  private InputServer() {}
}
