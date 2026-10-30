package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

public final class CheckmkOutput {
    public static final String VERSION = "1.3.7";
    private static final String PREFS_CACHE = "cmkagent_metrics_cache";

    private static final long INTERVAL_RAM_SEC = 1800L;         // RAM: 30 Menit
    private static final long INTERVAL_STORAGE_SEC = 86400L;    // Storage: 1 Hari
    private static final long INTERVAL_TRANSPORT_SEC = 10800L;  // Transport Status: 3 Jam

    private CheckmkOutput() {}

    private static final class CachedEntry {
        final String line;
        final long epochSec;

        CachedEntry(String line, long epochSec) {
            this.line = line;
            this.epochSec = epochSec;
        }
    }

    private interface LineGenerator {
        String generate();
    }

    private static CachedEntry getOrUpdateCache(Context context, String key, long intervalSec, LineGenerator generator) {
        SharedPreferences p = context.getSharedPreferences(PREFS_CACHE, Context.MODE_PRIVATE);
        long nowSec = System.currentTimeMillis() / 1000L;
        long lastSec = p.getLong(key + "_ts", 0L);
        String cachedLine = p.getString(key + "_line", null);

        if (cachedLine == null || (nowSec - lastSec) >= intervalSec || lastSec > nowSec) {
            String newLine = generator.generate();
            p.edit()
                    .putString(key + "_line", newLine)
                    .putLong(key + "_ts", nowSec)
                    .apply();
            return new CachedEntry(newLine, nowSec);
        }
        return new CachedEntry(cachedLine, lastSec);
    }

    private static CachedEntry getOrUpdateSundayInventoryCache(Context context, String key, LineGenerator generator) {
        SharedPreferences p = context.getSharedPreferences(PREFS_CACHE, Context.MODE_PRIVATE);
        long nowSec = System.currentTimeMillis() / 1000L;
        long lastSec = p.getLong(key + "_ts", 0L);
        long lastSundayScanMs = p.getLong(key + "_sunday_ms", 0L);
        String cachedLine = p.getString(key + "_line", null);

        boolean needRefresh = false;

        if (cachedLine == null || cachedLine.trim().isEmpty()) {
            needRefresh = true;
        } else {
            Calendar now = Calendar.getInstance();
            boolean isSunday = (now.get(Calendar.DAY_OF_WEEK) == Calendar.SUNDAY);

            if (isSunday) {
                Calendar lastScan = Calendar.getInstance();
                lastScan.setTimeInMillis(lastSundayScanMs);

                boolean alreadyScannedToday = (now.get(Calendar.YEAR) == lastScan.get(Calendar.YEAR))
                        && (now.get(Calendar.DAY_OF_YEAR) == lastScan.get(Calendar.DAY_OF_YEAR));

                if (!alreadyScannedToday) {
                    needRefresh = true;
                }
            }
        }

        if (needRefresh) {
            String newLine = generator.generate();
            p.edit()
                    .putString(key + "_line", newLine)
                    .putLong(key + "_ts", nowSec)
                    .putLong(key + "_sunday_ms", System.currentTimeMillis())
                    .apply();
            return new CachedEntry(newLine, nowSec);
        }

        return new CachedEntry(cachedLine, lastSec > 0 ? lastSec : nowSec);
    }

    public static String build(Context context) {
        DeviceMetrics.BatteryInfo battery = DeviceMetrics.readBattery(context);
        DeviceMetrics.WifiStatus wifi = DeviceMetrics.readWifi(context);
        DeviceMetrics.DeviceInfo device = DeviceMetrics.readDeviceInfo();
        AgentStats.Snapshot stats = AgentStats.read(context);

        StringBuilder sb = new StringBuilder();
        sb.append("<<<check_mk>>>\n");
        sb.append("Version: ").append(VERSION).append("\n");
        sb.append("AgentOS: android\n");
        sb.append("Hostname: ").append(AgentConfig.getHostname(context)).append("\n\n");

        // 1. REAL-TIME: AGENT STATUS, UNIFIED 1-LINE BATTERY, WI-FI (+ ROAMING), ANDROID INFO
        sb.append("<<<local:sep(0)>>>\n");
        sb.append(buildAgentStatusLine(context, stats)).append('\n');
        sb.append(buildBatteryUnifiedLine(battery)).append('\n');
        sb.append(buildWifiLine(wifi)).append('\n');
        sb.append(buildAndroidInfoLine(device)).append('\n');

        // 2. CACHED SYSTEM: RAM (30 Menit), STORAGE (1 Hari), TRANSPORT (3 Jam)
        CachedEntry ramEntry = getOrUpdateCache(context, "ram", INTERVAL_RAM_SEC,
                () -> buildRamLine(DeviceMetrics.readRam(context)));
        sb.append("<<<local:cached(").append(ramEntry.epochSec).append(",")
                .append(INTERVAL_RAM_SEC).append("):sep(0)>>>\n");
        sb.append(ramEntry.line).append('\n');

        CachedEntry storageEntry = getOrUpdateCache(context, "storage", INTERVAL_STORAGE_SEC,
                () -> buildStorageLine(DeviceMetrics.readStorage()));
        sb.append("<<<local:cached(").append(storageEntry.epochSec).append(",")
                .append(INTERVAL_STORAGE_SEC).append("):sep(0)>>>\n");
        sb.append(storageEntry.line).append('\n');

        CachedEntry transportEntry = getOrUpdateCache(context, "transport", INTERVAL_TRANSPORT_SEC,
                () -> buildTransportStatusLine(context, stats));
        sb.append("<<<local:cached(").append(transportEntry.epochSec).append(",")
                .append(INTERVAL_TRANSPORT_SEC).append("):sep(0)>>>\n");
        sb.append(transportEntry.line).append('\n');

        // 3. PING MONITOR (4x every 1 minute on PDA, reported to Checkmk every 1 hour in 2 rows)
        sb.append(PingMonitor.getCheckmkSection(context)).append('\n');

        // 4. HW/SW INVENTORY (MINGGUAN - KHUSUS PENGISI INVENTORY TREE)
        CachedEntry inventoryEntry = getOrUpdateSundayInventoryCache(context, "hw_sw_inventory",
                () -> DeviceMetrics.readAppInventory(context).fullInventoryPayload);
        sb.append(inventoryEntry.line).append('\n');

        return sb.toString();
    }

    private static String buildAgentStatusLine(Context context, AgentStats.Snapshot s) {
        long now = System.currentTimeMillis();
        String lastPull = s.lastPullMs > 0 ? formatDate(s.lastPullMs) : "N/A";
        String age = s.lastPullMs > 0 ? formatDuration(Math.max(0, now - s.lastPullMs)) + " ago" : "N/A";
        String allow = AgentConfig.getAllowedServerDisplay(context);
        return "0 \"Agent_Status\" connections=" + s.accepted + "|rejected=" + s.rejected
                + " Status : OK"
                + " | Version : " + VERSION
                + " | Port : " + AgentConfig.getPort(context)
                + " | Last Pull : " + lastPull + " (" + age + ")"
                + " | Last Client : " + s.lastClient
                + " | Server Cabang : " + allow
                + " | Collection : Hybrid (pull primary + push backup)";
    }

    private static String buildTransportStatusLine(Context context, AgentStats.Snapshot s) {
        String endpoint = AgentConfig.getPushUrl(context);
        boolean configured = AgentConfig.isPushConfigured(context);
        int state = 0;
        String status;
        if (!configured) {
            status = "Push backup not configured";
        } else if (s.lastPushMs <= 0) {
            state = 1;
            status = "Push backup configured, waiting for first delivery";
        } else if (s.lastPushOk) {
            status = "Push backup healthy";
        } else {
            state = 1;
            status = "Push backup last delivery failed";
        }

        String lastPush = s.lastPushMs > 0 ? formatDate(s.lastPushMs) : "N/A";
        String age = s.lastPushMs > 0
                ? formatDuration(Math.max(0, System.currentTimeMillis() - s.lastPushMs)) + " ago"
                : "N/A";
        String safeEndpoint = endpoint.isEmpty() ? "Not configured" : endpoint;

        return state + " \"Transport_Status\" push_success=" + s.pushSuccesses
                + "|push_failure=" + s.pushFailures
                + " Status : " + stateName(state)
                + " | Primary : PULL TCP/" + AgentConfig.getPort(context)
                + " | Backup : PUSH HTTP(S)"
                + " | Receiver : " + safeEndpoint
                + " | Push Interval : " + AgentConfig.getPushIntervalSec(context) + " sec"
                + " | Last Push : " + lastPush + " (" + age + ")"
                + " | Last Push Result : " + status
                + " | HTTP Code : " + (s.lastPushCode > 0 ? s.lastPushCode : "N/A")
                + " | Detail : " + s.lastPushMessage;
    }

    /**
     * Unified 1-line Battery service ("Health_Battery") combining Level, Charging State,
     * Real Health (based on 2946 mAh @ 100% full charge on MT93), Cycles, Capacities,
     * Temperature, Voltage, and Current into a single Checkmk service row.
     */
    private static String buildBatteryUnifiedLine(DeviceMetrics.BatteryInfo b) {
        int state = 0;

        // 1. Evaluate Level thresholds
        if (b.level >= 0) {
            if (b.level < 15) state = Math.max(state, 2);
            else if (b.level < 30) state = Math.max(state, 1);
        }

        // 2. Evaluate Health & Cycle thresholds
        if (!Double.isNaN(b.healthPercent)) {
            if (b.healthPercent < 65.0 || b.cycleCount >= 800) {
                state = Math.max(state, 2);
            } else if (b.healthPercent < 80.0 || b.cycleCount >= 500) {
                state = Math.max(state, 1);
            }
        }

        // 3. Evaluate Temperature thresholds
        if (!Double.isNaN(b.temperatureC)) {
            if (b.temperatureC >= 48.0) state = Math.max(state, 2);
            else if (b.temperatureC >= 42.0) state = Math.max(state, 1);
        }

        String levelStr = b.level >= 0 ? (b.level + "% (" + b.status + ")") : ("N/A (" + b.status + ")");
        String healthStr = Double.isNaN(b.healthPercent) ? "100.0%" : String.format(Locale.US, "%.1f%%", b.healthPercent);
        String fullStr = Double.isNaN(b.fullCapacityMah) ? "2946 mAh" : Math.round(b.fullCapacityMah) + " mAh";
        String designStr = Double.isNaN(b.designCapacityMah) ? "4800 mAh" : Math.round(b.designCapacityMah) + " mAh";
        String chargeStr = Double.isNaN(b.chargeCounterMah) ? "N/A" : Math.round(b.chargeCounterMah) + " mAh";
        String tempStr = !Double.isNaN(b.temperatureC) ? String.format(Locale.US, "%.1f C", b.temperatureC) : "N/A";
        String voltStr = !Double.isNaN(b.voltageV) ? String.format(Locale.US, "%.2f V", b.voltageV) : "N/A";

        double activeCurrentMa = !Double.isNaN(b.currentNowMa) ? b.currentNowMa : b.currentAverageMa;
        String currentStr = !Double.isNaN(activeCurrentMa)
                ? String.format(Locale.US, "%.0f mA", activeCurrentMa) : "N/A";

        int cycles = Math.max(0, b.cycleCount);

        StringBuilder perf = new StringBuilder();
        perf.append("battery_level=").append(b.level >= 0 ? b.level : 0).append(";30:;15:;0;100");
        perf.append("|battery_health=").append(String.format(Locale.US, "%.1f",
                Double.isNaN(b.healthPercent) ? 100.0 : b.healthPercent)).append(";80;65;0;100");
        perf.append("|battery_cycles=").append(cycles).append(";500;800;0");
        if (!Double.isNaN(b.temperatureC)) {
            perf.append("|battery_temp=").append(String.format(Locale.US, "%.1f;42;48", b.temperatureC));
        }
        if (!Double.isNaN(b.voltageV)) {
            perf.append("|battery_voltage=").append(String.format(Locale.US, "%.3f", b.voltageV));
        }
        if (!Double.isNaN(activeCurrentMa)) {
            perf.append("|battery_current=").append(String.format(Locale.US, "%.0f", activeCurrentMa));
        }

        return state + " \"Health_Battery\" " + perf
                + " Status : " + stateName(state)
                + " | Level : " + levelStr
                + " | Real Health : " + healthStr
                + " | Cycles : " + cycles
                + " | Full Capacity : " + fullStr
                + " | Design Spec : " + designStr
                + " | Current Charge : " + chargeStr
                + " | Temp : " + tempStr
                + " | Voltage : " + voltStr
                + " | Current : " + currentStr
                + " | Calculation : " + b.fullCapacitySource;
    }

    private static String buildRamLine(DeviceMetrics.UsageInfo r) {
        int state = thresholdHigh(r.usedPercent, 85.0, 95.0);
        return state + " \"RAM_Usage\" ram_used=" + Math.round(r.usedPercent) + ";85;95"
                + " Status : " + stateName(state)
                + " | Used : " + Math.round(r.usedPercent) + "% (" + DeviceMetrics.fmt2(r.usedGb) + " GB)"
                + " | Free : " + DeviceMetrics.fmt2(r.freeGb) + " GB"
                + " | Total : " + DeviceMetrics.fmt2(r.totalGb) + " GB";
    }

    private static String buildStorageLine(DeviceMetrics.UsageInfo s) {
        int state = thresholdHigh(s.usedPercent, 85.0, 95.0);
        return state + " \"Storage_Usage\" storage_used=" + Math.round(s.usedPercent) + ";85;95"
                + " Status : " + stateName(state)
                + " | Used : " + Math.round(s.usedPercent) + "% (" + DeviceMetrics.fmt2(s.usedGb) + " GB)"
                + " | Free : " + DeviceMetrics.fmt2(s.freeGb) + " GB"
                + " | Total : " + DeviceMetrics.fmt2(s.totalGb) + " GB";
    }

    private static String buildWifiLine(DeviceMetrics.WifiStatus w) {
        if (!w.connected) {
            return "1 \"WiFi_Status\" - Status : Not Connected | WiFi not connected"
                    + " | IP : " + w.ip
                    + " | Roaming : " + w.roamSummary;
        }
        int state = 0;
        if (w.rssi != Integer.MIN_VALUE) {
            if (w.rssi <= -75) state = 2;
            else if (w.rssi <= -68) state = 1;
        }
        StringBuilder metric = new StringBuilder();
        if (w.rssi != Integer.MIN_VALUE) {
            metric.append("wifi_rssi=").append(w.rssi);
        } else {
            metric.append("wifi_rssi=0");
        }
        metric.append("|wifi_roams_1h=").append(w.roamsLastHour);
        metric.append("|wifi_roams_total=").append(w.totalRoams);

        String rssi = w.rssi != Integer.MIN_VALUE ? w.rssi + " dBm" : "N/A";
        String speed = w.linkSpeedMbps >= 0 ? w.linkSpeedMbps + " Mbps" : "N/A";
        String freq = w.frequencyMhz >= 0 ? w.frequencyMhz + " MHz" : "N/A";
        String apLabel = "N/A".equals(w.bssid) ? w.bssid : (w.bssid + " (" + w.apVendor + ")");

        return state + " \"WiFi_Status\" " + metric
                + " Status : " + stateName(state)
                + " | SSID : " + w.ssid
                + " | AP BSSID : " + apLabel
                + " | Band : " + w.bandChannel + " (" + freq + ")"
                + " | Roaming : " + w.roamSummary
                + " | Signal : " + rssi
                + " | Link Speed : " + speed
                + " | IP : " + w.ip;
    }

    private static String buildAndroidInfoLine(DeviceMetrics.DeviceInfo d) {
        return "0 \"Android_Info\" - Status : OK"
                + " | Manufacturer : " + d.manufacturer
                + " | Model : " + d.model
                + " | Profile : " + d.profile
                + " | Android : " + d.androidVersion
                + " | SDK : " + d.sdk
                + " | Uptime : " + formatDuration(d.uptimeMs);
    }

    private static int thresholdHigh(double value, double warn, double crit) {
        if (value >= crit) return 2;
        if (value >= warn) return 1;
        return 0;
    }

    private static String stateName(int state) {
        switch (state) {
            case 1: return "WARNING";
            case 2: return "CRITICAL";
            case 3: return "UNKNOWN";
            default: return "OK";
        }
    }

    public static String formatDuration(long ms) {
        long totalMinutes = Math.max(0L, TimeUnit.MILLISECONDS.toMinutes(ms));
        long days = totalMinutes / (24 * 60);
        long hours = (totalMinutes / 60) % 24;
        long minutes = totalMinutes % 60;
        if (days > 0) return days + "d " + hours + "h " + minutes + "m";
        if (hours > 0) return hours + "h " + minutes + "m";
        return minutes + "m";
    }

    private static String formatDate(long millis) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
                .format(new Date(millis));
    }
}
