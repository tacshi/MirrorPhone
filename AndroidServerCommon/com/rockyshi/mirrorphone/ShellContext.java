package com.rockyshi.mirrorphone;

import android.app.Application;
import android.app.Instrumentation;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;
import android.os.Process;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;

/**
 * Builds a framework Context attributed to the shell uid and package for
 * device-side helpers launched through {@code app_process}.
 *
 * <p>Framework services otherwise see the synthetic process as package
 * {@code android}, which fails modern attribution checks even though the
 * process actually runs as uid 2000. Both the audio and input helpers need the
 * same ActivityThread setup, so it lives in the common dex payload.
 */
final class ShellContext extends ContextWrapper {
  static final String PACKAGE_NAME = "com.android.shell";

  static ShellContext create() throws Exception {
    Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
    Constructor<?> activityThreadConstructor = activityThreadClass.getDeclaredConstructor();
    activityThreadConstructor.setAccessible(true);
    Object activityThread = activityThreadConstructor.newInstance();

    Field currentThreadField = activityThreadClass.getDeclaredField("sCurrentActivityThread");
    currentThreadField.setAccessible(true);
    currentThreadField.set(null, activityThread);

    Field systemThreadField = activityThreadClass.getDeclaredField("mSystemThread");
    systemThreadField.setAccessible(true);
    systemThreadField.setBoolean(activityThread, true);

    Class<?> appBindDataClass = Class.forName("android.app.ActivityThread$AppBindData");
    Constructor<?> appBindDataConstructor = appBindDataClass.getDeclaredConstructor();
    appBindDataConstructor.setAccessible(true);
    Object appBindData = appBindDataConstructor.newInstance();
    ApplicationInfo applicationInfo = new ApplicationInfo();
    applicationInfo.packageName = PACKAGE_NAME;
    Field appInfoField = appBindDataClass.getDeclaredField("appInfo");
    appInfoField.setAccessible(true);
    appInfoField.set(appBindData, applicationInfo);
    Field boundApplicationField = activityThreadClass.getDeclaredField("mBoundApplication");
    boundApplicationField.setAccessible(true);
    boundApplicationField.set(activityThread, appBindData);

    // Samsung and other OEM framework paths may consult configuration while
    // the system context is being created. This field exists on Android 12+.
    try {
      Class<?> configurationControllerClass = Class.forName("android.app.ConfigurationController");
      Class<?> activityThreadInternalClass = Class.forName("android.app.ActivityThreadInternal");
      Constructor<?> configurationControllerConstructor =
          configurationControllerClass.getDeclaredConstructor(activityThreadInternalClass);
      configurationControllerConstructor.setAccessible(true);
      Object configurationController = configurationControllerConstructor.newInstance(activityThread);
      Field configurationControllerField =
          activityThreadClass.getDeclaredField("mConfigurationController");
      configurationControllerField.setAccessible(true);
      configurationControllerField.set(activityThread, configurationController);
    } catch (Throwable ignored) {
    }

    Context system =
        (Context) activityThreadClass.getMethod("getSystemContext").invoke(activityThread);
    ShellContext context = new ShellContext(system);

    // Some service constructors consult ActivityThread.currentApplication().
    // Populate it best-effort without turning an OEM-only failure into a hard
    // requirement for every device.
    try {
      Application application =
          Instrumentation.newApplication(Application.class, context);
      Field initialApplicationField =
          activityThreadClass.getDeclaredField("mInitialApplication");
      initialApplicationField.setAccessible(true);
      initialApplicationField.set(activityThread, application);
    } catch (Throwable ignored) {
    }

    return context;
  }

  private ShellContext(Context base) {
    super(base);
  }

  @Override
  public String getPackageName() {
    return PACKAGE_NAME;
  }

  @Override
  public String getOpPackageName() {
    return PACKAGE_NAME;
  }

  @Override
  public AttributionSource getAttributionSource() {
    AttributionSource.Builder builder =
        new AttributionSource.Builder(Process.SHELL_UID).setPackageName(PACKAGE_NAME);
    // Android 15+ validates the pid in the attribution. setPid is not public
    // on every SDK level, so invoke it reflectively when present.
    try {
      AttributionSource.Builder.class
          .getMethod("setPid", int.class)
          .invoke(builder, Process.myPid());
    } catch (ReflectiveOperationException ignored) {
    }
    return builder.build();
  }

  // Added to Context after the minimum supported API. Keeping this method
  // without @Override lets the same dex load on Android 11.
  @SuppressWarnings("unused")
  public int getDeviceId() {
    return 0;
  }

  @Override
  public Context getApplicationContext() {
    return this;
  }

  @Override
  public Context createPackageContext(String packageName, int flags) {
    return this;
  }

  @Override
  public Object getSystemService(String name) {
    Object service = super.getSystemService(name);
    if (service == null) {
      return null;
    }

    // ContextWrapper delegates service creation to the system context. Replace
    // the context retained by clipboard wrappers so binder calls identify as
    // com.android.shell. Samsung's semclipboard wrapper needs the same repair.
    if (Context.CLIPBOARD_SERVICE.equals(name)
        || "semclipboard".equals(name)
        || Context.ACTIVITY_SERVICE.equals(name)) {
      try {
        Field contextField = findField(service.getClass(), "mContext");
        contextField.setAccessible(true);
        contextField.set(service, this);
      } catch (ReflectiveOperationException error) {
        throw new IllegalStateException("Could not attribute " + name + " to the shell", error);
      }
    }
    return service;
  }

  private static Field findField(Class<?> type, String name) throws NoSuchFieldException {
    Class<?> current = type;
    while (current != null) {
      try {
        return current.getDeclaredField(name);
      } catch (NoSuchFieldException ignored) {
        current = current.getSuperclass();
      }
    }
    throw new NoSuchFieldException(name);
  }
}
