package com.bcp.checkmkagent;

public final class NativeBridge {
    private static volatile boolean loaded = false;
    private static volatile String loadError = "";

    static {
        try {
            System.loadLibrary("cmkagent_jni");
            loaded = true;
        } catch (Throwable t) {
            loaded = false;
            loadError = t.getClass().getSimpleName() + ": " + t.getMessage();
        }
    }

    private NativeBridge() {}

    public static boolean isLoaded() {
        return loaded;
    }

    public static String getLoadError() {
        return loadError;
    }

    public static native boolean startPullServer(String configJson, String dataDir);

    public static native void stopPullServer();

    public static native void updateConfig(String configJson);

    public static native void updateSnapshot(String snapshotJson);

    public static native void collectPingSample(String gatewayIp);

    public static native String buildFullPayload();

    public static native String readPingLogTail(int maxLines);

    public static native String getStatsJson();

    public static native void recordPushResult(boolean success, int httpCode, String detail);

    public static native String normalizeRemoteIp(String ip);

    public static native boolean isClientAllowed(String configJson, String remoteIp);
}
