package com.bcp.checkmkagent;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.BufferedWriter;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class CheckmkAgentService extends Service {
    public static final String CHANNEL_ID = "cmkagent_service";
    private static final int NOTIFICATION_ID = 6556;

    private volatile boolean running = false;
    private ServerSocket serverSocket;
    private ExecutorService listenerExecutor;
    private ExecutorService clientWorkerExecutor;
    private ScheduledExecutorService pushExecutor;
    private ScheduledExecutorService monitorExecutor;
    private BroadcastReceiver hardwareEventReceiver;

    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, buildNotification("Starting hybrid agent..."));
        startHybridIfNeeded();
        return START_STICKY;
    }

    private synchronized void startHybridIfNeeded() {
        if (running) return;
        running = true;
        acquireLocks();
        AgentStats.recordStart(this);
        registerHardwareReceiver();
        startPullListener();
        startMinuteMonitorScheduler();
        startPushScheduler();
    }

    private void registerHardwareReceiver() {
        if (hardwareEventReceiver != null) return;
        hardwareEventReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (!running || intent == null) return;
                String action = intent.getAction();
                if (Intent.ACTION_BATTERY_CHANGED.equals(action)
                        || Intent.ACTION_POWER_CONNECTED.equals(action)
                        || Intent.ACTION_POWER_DISCONNECTED.equals(action)) {
                    try {
                        DeviceMetrics.readBattery(getApplicationContext());
                    } catch (Throwable ignored) {}
                } else if (WifiManager.NETWORK_STATE_CHANGED_ACTION.equals(action)
                        || WifiManager.RSSI_CHANGED_ACTION.equals(action)) {
                    try {
                        DeviceMetrics.readWifi(getApplicationContext());
                    } catch (Throwable ignored) {}
                }
            }
        };
        try {
            IntentFilter filter = new IntentFilter();
            filter.addAction(Intent.ACTION_BATTERY_CHANGED);
            filter.addAction(Intent.ACTION_POWER_CONNECTED);
            filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
            filter.addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION);
            filter.addAction(WifiManager.RSSI_CHANGED_ACTION);
            registerReceiver(hardwareEventReceiver, filter);
        } catch (Throwable ignored) {}
    }

    private void unregisterHardwareReceiver() {
        if (hardwareEventReceiver != null) {
            try {
                unregisterReceiver(hardwareEventReceiver);
            } catch (Throwable ignored) {}
            hardwareEventReceiver = null;
        }
    }

    /**
     * Runs every 1 minute (60s):
     * 1) Pings 192.168.122.10 (4x) and 8.8.8.8 (4x), saves to persistent phone log,
     *    and publishes 1-hour summary to Checkmk every 60 minutes.
     * 2) Samples Battery (for continuous cycle counting) and Wi-Fi (for AP roaming tracking).
     */
    private void startMinuteMonitorScheduler() {
        monitorExecutor = Executors.newSingleThreadScheduledExecutor();
        monitorExecutor.scheduleAtFixedRate(() -> {
            if (!running) return;
            try {
                DeviceMetrics.readBattery(getApplicationContext());
                DeviceMetrics.readWifi(getApplicationContext());
                PingMonitor.collectMinuteSample(getApplicationContext());
            } catch (Throwable ignored) {}
        }, 3, 60, TimeUnit.SECONDS);
    }

    private void acquireLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm != null && (wakeLock == null || !wakeLock.isHeld())) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cmkagent:service_wakelock");
                wakeLock.acquire();
            }
        } catch (Throwable ignored) {}

        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null && (wifiLock == null || !wifiLock.isHeld())) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "cmkagent:service_wifilock");
                wifiLock.acquire();
            }
        } catch (Throwable ignored) {}
    }

    private void releaseLocks() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
            }
        } catch (Throwable ignored) {}
        wakeLock = null;

        try {
            if (wifiLock != null && wifiLock.isHeld()) {
                wifiLock.release();
            }
        } catch (Throwable ignored) {}
        wifiLock = null;
    }

    private void startPullListener() {
        listenerExecutor = Executors.newSingleThreadExecutor();
        clientWorkerExecutor = Executors.newCachedThreadPool();

        listenerExecutor.execute(() -> {
            int port = AgentConfig.getPort(this);
            try {
                serverSocket = new ServerSocket();
                serverSocket.setReuseAddress(true);
                serverSocket.bind(new InetSocketAddress("0.0.0.0", port));
                updateNotification(notificationSummary());

                while (running) {
                    try {
                        Socket client = serverSocket.accept();
                        client.setSoTimeout(5000);
                        clientWorkerExecutor.execute(() -> serveClient(client));
                    } catch (Exception e) {
                        if (running) updateNotification("Pull error: " + shortMessage(e));
                    }
                }
            } catch (Exception e) {
                updateNotification("Pull listener error: " + shortMessage(e));
            } finally {
                closeServerSocket();
            }
        });
    }

    private void startPushScheduler() {
        pushExecutor = Executors.newSingleThreadScheduledExecutor();
        int interval = AgentConfig.getPushIntervalSec(this);
        pushExecutor.scheduleWithFixedDelay(() -> {
            if (!running || !AgentConfig.isPushConfigured(this)) return;
            PushClient.Result result = PushClient.pushNow(this);
            if (running) {
                updateNotification(result.ok
                        ? notificationSummary()
                        : "Pull primary active • Push backup failed: " + shortText(result.message));
            }
        }, 8, interval, TimeUnit.SECONDS);
    }

    private void serveClient(Socket client) {
        String remoteIp = client.getInetAddress() == null
                ? "unknown" : client.getInetAddress().getHostAddress();

        if (!AgentConfig.isClientAllowed(this, remoteIp)) {
            AgentStats.recordRejected(this, remoteIp);
            try { client.close(); } catch (Exception ignored) {}
            return;
        }

        AgentStats.recordAccepted(this, remoteIp);
        try (Socket socket = client;
             BufferedWriter writer = new BufferedWriter(
                     new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8))) {
            writer.write(CheckmkOutput.build(this));
            writer.flush();
            updateNotification(notificationSummary());
        } catch (Exception ignored) {}
    }

    @Override
    public void onDestroy() {
        running = false;
        AgentStats.recordStop(this);
        unregisterHardwareReceiver();
        closeServerSocket();
        if (listenerExecutor != null) listenerExecutor.shutdownNow();
        if (clientWorkerExecutor != null) clientWorkerExecutor.shutdownNow();
        if (monitorExecutor != null) monitorExecutor.shutdownNow();
        if (pushExecutor != null) pushExecutor.shutdownNow();
        releaseLocks();
        super.onDestroy();
    }

    private String notificationSummary() {
        String allow = AgentConfig.getAllowedServerDisplay(this);
        return "TCP/" + AgentConfig.getPort(this) + " (" + allow + ") • Ping 4x/1m";
    }

    private void closeServerSocket() {
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (Exception ignored) {}
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                NotificationChannel channel = new NotificationChannel(
                        CHANNEL_ID,
                        "cmkagent hybrid service",
                        NotificationManager.IMPORTANCE_LOW
                );
                channel.setDescription("Checkmk Android hybrid agent: pull primary, ping monitor, and push backup");
                nm.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(
                this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        return builder
                .setContentTitle("cmkagent v" + CheckmkOutput.VERSION)
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_stat_cmkagent)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    private void updateNotification(String text) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification(text));
    }

    private static String shortMessage(Exception e) {
        String m = e.getMessage();
        return m == null || m.isEmpty() ? e.getClass().getSimpleName() : m;
    }

    private static String shortText(String value) {
        if (value == null || value.trim().isEmpty()) return "unknown";
        String clean = value.trim().replace('\n', ' ').replace('\r', ' ');
        return clean.length() > 70 ? clean.substring(0, 70) : clean;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
