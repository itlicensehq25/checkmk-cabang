package com.bcp.checkmkagent;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class CheckmkAgentService extends Service {
    public static final String ACTION_START_OR_RELOAD = "com.bcp.checkmkagent.START_OR_RELOAD";
    public static final String ACTION_STOP_SERVICE = "com.bcp.checkmkagent.STOP_SERVICE";
    public static final String ACTION_PING_NOW = "com.bcp.checkmkagent.PING_NOW";
    public static final String ACTION_PUSH_NOW = "com.bcp.checkmkagent.PUSH_NOW";

    private static final String CHANNEL_ID = "cmkagent_rust_fg";
    private static final int NOTIF_ID = 6556;
    private static volatile boolean running = false;

    private ScheduledExecutorService scheduler;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private long lastPushElapsedMs = 0L;

    public static boolean isRunning() {
        return running;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        acquireLocks();
        running = true;

        AgentConfig cfg = new AgentConfig(this);
        String dataDir = getFilesDir().getAbsolutePath();

        if (NativeBridge.isLoaded()) {
            NativeBridge.startPullServer(cfg.toNativeConfigJson(), dataDir);
            String snap = DeviceMetrics.buildSnapshotJson(this, cfg);
            NativeBridge.updateSnapshot(snap);
        }

        startScheduler();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_STOP_SERVICE.equals(action)) {
            stopAgentEngine();
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }

        running = true;
        AgentConfig cfg = new AgentConfig(this);
        String mode = cfg.isAllowAllPrivate() ? "Open" : "Restricted";
        Notification notif = buildNotification(cfg.getHostname(), mode);

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, notif);
        }

        if (scheduler == null || scheduler.isShutdown()) {
            startScheduler();
        }

        if (ACTION_START_OR_RELOAD.equals(action) && NativeBridge.isLoaded()) {
            NativeBridge.startPullServer(cfg.toNativeConfigJson(), getFilesDir().getAbsolutePath());
            if (scheduler != null) {
                scheduler.execute(() -> {
                    String snap = DeviceMetrics.buildSnapshotJson(this, cfg);
                    NativeBridge.updateSnapshot(snap);
                });
            }
        } else if (ACTION_PING_NOW.equals(action) && scheduler != null && NativeBridge.isLoaded()) {
            scheduler.execute(() -> NativeBridge.collectPingSample(cfg.getGatewayIp()));
        } else if (ACTION_PUSH_NOW.equals(action) && scheduler != null && NativeBridge.isLoaded()) {
            scheduler.execute(() -> performPush(cfg));
        }

        return START_STICKY;
    }

    private void startScheduler() {
        if (scheduler != null && !scheduler.isShutdown()) {
            scheduler.shutdownNow();
        }
        scheduler = Executors.newSingleThreadScheduledExecutor();
        scheduler.scheduleAtFixedRate(() -> {
            try {
                if (!running || !NativeBridge.isLoaded()) return;
                AgentConfig cfg = new AgentConfig(this);
                NativeBridge.updateConfig(cfg.toNativeConfigJson());
                String snap = DeviceMetrics.buildSnapshotJson(this, cfg);
                NativeBridge.updateSnapshot(snap);
                NativeBridge.collectPingSample(cfg.getGatewayIp());

                if (cfg.isPushEnabled() && !cfg.getPushUrl().trim().isEmpty()) {
                    long now = System.currentTimeMillis();
                    if (now - lastPushElapsedMs >= cfg.getPushIntervalSec() * 1000L) {
                        performPush(cfg);
                        lastPushElapsedMs = now;
                    }
                }
            } catch (Throwable ignored) {}
        }, 1, 60, TimeUnit.SECONDS);
    }

    private void performPush(AgentConfig cfg) {
        String payload = NativeBridge.buildFullPayload();
        if (payload != null && !payload.isEmpty()) {
            PushClient.pushNow(cfg, payload);
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_ID, "BMS Monitoring Service", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("Agen BMS Monitoring & 4x/1m ping monitor");
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) nm.createNotificationChannel(ch);
        }
    }

    private Notification buildNotification(String host, String mode) {
        Intent i = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder nb = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        return nb.setSmallIcon(R.drawable.ic_stat_cmkagent)
                .setContentTitle("Agen BMS ACTIVE (" + host + ")")
                .setContentText("Status: " + mode + " • Pull Primary")
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    private void acquireLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm != null && (wakeLock == null || !wakeLock.isHeld())) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cmkagent:WakeLock");
                wakeLock.acquire();
            }
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null && (wifiLock == null || !wifiLock.isHeld())) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "cmkagent:WifiLock");
                wifiLock.acquire();
            }
        } catch (Throwable ignored) {}
    }

    private void stopAgentEngine() {
        running = false;
        if (scheduler != null) {
            scheduler.shutdownNow();
            scheduler = null;
        }
        if (NativeBridge.isLoaded()) {
            NativeBridge.stopPullServer();
        }
        try {
            if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
            if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
        } catch (Throwable ignored) {}
    }

    @Override
    public void onDestroy() {
        stopAgentEngine();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
