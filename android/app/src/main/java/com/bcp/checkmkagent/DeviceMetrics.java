package com.bcp.checkmkagent;

import android.Manifest;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.TrafficStats;
import android.net.TransportInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.SupplicantState;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.SystemClock;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class DeviceMetrics {
    public static class BatterySnapshot {
        public int levelPct;
        public String statusText;
        public double tempC;
        public double voltageV;
        public int currentMa;
        public double designMah;
        public double estFullMah;
        public double healthPct;
        public int cycles;
        public String calcMethod;
    }

    public static class RamStorageSnapshot {
        public int ramPct;
        public double ramUsedGb;
        public double ramFreeGb;
        public double ramTotalGb;
        public int storagePct;
        public double storageUsedGb;
        public double storageFreeGb;
        public double storageTotalGb;
    }

    public static class WifiSnapshot {
        public String status;
        public String ssid;
        public String bssid;
        public String vendor;
        public String bandChannel;
        public int rssiDbm;
        public int linkSpeedMbps;
        public String ip;
        public int roam1h;
        public int roamTotal;
        public String lastRoam;
    }

    public static class AppCountSnapshot {
        public int totalApps;
        public int userApps;
        public int systemApps;
    }

    public static class NetworkTrafficSnapshot {
        public long rxTotalBytes;
        public long txTotalBytes;
        public long rxRateBps;
        public long txRateBps;
        public String rxTotalHuman = "0.00 KB";
        public String txTotalHuman = "0.00 KB";
        public String rxRateHuman = "0 B/s";
        public String txRateHuman = "0 B/s";
    }

    public static final String TRAFFIC_CSV_FILE = "network_traffic.csv";
    private static final long MAX_TRAFFIC_CSV_BYTES = 5L * 1024L * 1024L; // 5 MB rolling CSV
    private static long prevSampleRxBytes = -1L;
    private static long prevSampleTxBytes = -1L;
    private static long prevSampleElapsedMs = 0L;
    private static long lastCsvAppendWallMs = 0L;
    private static NetworkTrafficSnapshot latestTraffic = null;

    public static synchronized NetworkTrafficSnapshot sampleNetworkTraffic(Context ctx, String ip, String ssid) {
        long rawRx = TrafficStats.getTotalRxBytes();
        long rawTx = TrafficStats.getTotalTxBytes();
        long rx = rawRx < 0 ? 0L : rawRx;
        long tx = rawTx < 0 ? 0L : rawTx;
        long nowElapsed = SystemClock.elapsedRealtime();

        long rxRate = 0L;
        long txRate = 0L;
        if (prevSampleRxBytes >= 0 && prevSampleTxBytes >= 0 && nowElapsed > prevSampleElapsedMs) {
            double dtSec = (nowElapsed - prevSampleElapsedMs) / 1000.0;
            if (dtSec >= 1.0) {
                long dRx = rx >= prevSampleRxBytes ? (rx - prevSampleRxBytes) : 0L;
                long dTx = tx >= prevSampleTxBytes ? (tx - prevSampleTxBytes) : 0L;
                rxRate = Math.round(dRx / dtSec);
                txRate = Math.round(dTx / dtSec);
            } else if (latestTraffic != null) {
                rxRate = latestTraffic.rxRateBps;
                txRate = latestTraffic.txRateBps;
            }
        }
        if (prevSampleRxBytes < 0 || (nowElapsed - prevSampleElapsedMs) >= 1000L) {
            prevSampleRxBytes = rx;
            prevSampleTxBytes = tx;
            prevSampleElapsedMs = nowElapsed;
        }

        NetworkTrafficSnapshot snap = new NetworkTrafficSnapshot();
        snap.rxTotalBytes = rx;
        snap.txTotalBytes = tx;
        snap.rxRateBps = rxRate;
        snap.txRateBps = txRate;
        snap.rxTotalHuman = formatBytesHuman(rx);
        snap.txTotalHuman = formatBytesHuman(tx);
        snap.rxRateHuman = formatRateHuman(rxRate);
        snap.txRateHuman = formatRateHuman(txRate);
        latestTraffic = snap;

        long nowWall = System.currentTimeMillis();
        if (ctx != null && (nowWall - lastCsvAppendWallMs) >= 25_000L) {
            lastCsvAppendWallMs = nowWall;
            appendTrafficCsv(ctx, nowWall, ip, ssid, snap);
        }
        return snap;
    }

    public static synchronized NetworkTrafficSnapshot peekNetworkTraffic(Context ctx) {
        long rawRx = TrafficStats.getTotalRxBytes();
        long rawTx = TrafficStats.getTotalTxBytes();
        long rx = rawRx < 0 ? 0L : rawRx;
        long tx = rawTx < 0 ? 0L : rawTx;
        NetworkTrafficSnapshot snap = new NetworkTrafficSnapshot();
        snap.rxTotalBytes = rx;
        snap.txTotalBytes = tx;
        snap.rxRateBps = latestTraffic != null ? latestTraffic.rxRateBps : 0L;
        snap.txRateBps = latestTraffic != null ? latestTraffic.txRateBps : 0L;
        snap.rxTotalHuman = formatBytesHuman(rx);
        snap.txTotalHuman = formatBytesHuman(tx);
        snap.rxRateHuman = formatRateHuman(snap.rxRateBps);
        snap.txRateHuman = formatRateHuman(snap.txRateBps);
        return snap;
    }

    private static void appendTrafficCsv(Context ctx, long wallMs, String ip, String ssid, NetworkTrafficSnapshot s) {
        try {
            File csvFile = new File(ctx.getFilesDir(), TRAFFIC_CSV_FILE);
            if (csvFile.exists() && csvFile.length() > MAX_TRAFFIC_CSV_BYTES) {
                pruneTrafficCsv(csvFile);
            }
            boolean writeHeader = !csvFile.exists() || csvFile.length() == 0L;
            String ts = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date(wallMs));
            String safeIp = (ip == null ? "0.0.0.0" : ip).replace(",", ";");
            String safeSsid = (ssid == null ? "N/A" : ssid).replace(",", " ").replace("\"", "");
            try (FileWriter fw = new FileWriter(csvFile, true)) {
                if (writeHeader) {
                    fw.write("timestamp,ip_address,ssid,rx_total_bytes,tx_total_bytes,rx_rate_bps,tx_rate_bps,rx_total,tx_total,rx_rate,tx_rate\n");
                }
                fw.write(String.format(Locale.US,
                        "%s,%s,%s,%d,%d,%d,%d,%s,%s,%s,%s\n",
                        ts, safeIp, safeSsid,
                        s.rxTotalBytes, s.txTotalBytes, s.rxRateBps, s.txRateBps,
                        s.rxTotalHuman, s.txTotalHuman, s.rxRateHuman, s.txRateHuman));
            }
        } catch (Throwable ignored) {}
    }

    private static void pruneTrafficCsv(File csvFile) {
        try {
            List<String> lines = new ArrayList<>();
            try (BufferedReader br = new BufferedReader(new FileReader(csvFile))) {
                String line;
                while ((line = br.readLine()) != null) {
                    lines.add(line);
                }
            }
            if (lines.size() <= 2) return;
            String header = lines.get(0);
            int startIdx = Math.max(1, lines.size() / 2);
            try (FileWriter fw = new FileWriter(csvFile, false)) {
                fw.write(header + "\n");
                for (int i = startIdx; i < lines.size(); i++) {
                    fw.write(lines.get(i) + "\n");
                }
            }
        } catch (Throwable ignored) {}
    }

    public static String readTrafficCsvTail(Context ctx, int maxLines) {
        try {
            File csvFile = new File(ctx.getFilesDir(), TRAFFIC_CSV_FILE);
            if (!csvFile.exists() || csvFile.length() == 0L) {
                return "File CSV belum berisi data (" + csvFile.getAbsolutePath() + ").\nData otomatis dicatat setiap 1 menit saat Agent berjalan.";
            }
            List<String> lines = new ArrayList<>();
            try (BufferedReader br = new BufferedReader(new FileReader(csvFile))) {
                String line;
                while ((line = br.readLine()) != null) {
                    if (!line.trim().isEmpty()) lines.add(line);
                }
            }
            if (lines.isEmpty()) return "File CSV kosong.";
            StringBuilder sb = new StringBuilder();
            sb.append("# File: ").append(csvFile.getAbsolutePath()).append("\n");
            sb.append(lines.get(0)).append("\n");
            int start = Math.max(1, lines.size() - maxLines);
            for (int i = start; i < lines.size(); i++) {
                sb.append(lines.get(i)).append("\n");
            }
            return sb.toString();
        } catch (Throwable t) {
            return "Gagal membaca CSV: " + t.getMessage();
        }
    }

    public static String formatBytesHuman(long bytes) {
        if (bytes >= 1_073_741_824L) {
            return String.format(Locale.US, "%.2f GB", bytes / 1_073_741_824.0);
        } else if (bytes >= 1_048_576L) {
            return String.format(Locale.US, "%.2f MB", bytes / 1_048_576.0);
        } else {
            return String.format(Locale.US, "%.2f KB", bytes / 1024.0);
        }
    }

    public static String formatRateHuman(long bps) {
        if (bps >= 1_048_576L) {
            return String.format(Locale.US, "%.2f MB/s", bps / 1_048_576.0);
        } else if (bps >= 1024L) {
            return String.format(Locale.US, "%.2f KB/s", bps / 1024.0);
        } else {
            return String.format(Locale.US, "%d B/s", bps);
        }
    }

    private static AppCountSnapshot cachedAppCounts = null;
    private static long lastAppCountMillis = 0L;

    public static AppCountSnapshot readAppCounts(Context ctx) {
        long now = System.currentTimeMillis();
        if (cachedAppCounts != null && (now - lastAppCountMillis) < 300_000L) {
            return cachedAppCounts;
        }
        AppCountSnapshot ac = new AppCountSnapshot();
        try {
            PackageManager pm = ctx.getPackageManager();
            List<PackageInfo> pkgs = pm.getInstalledPackages(0);
            ac.totalApps = pkgs.size();
            for (PackageInfo pi : pkgs) {
                if (pi == null || pi.applicationInfo == null) continue;
                if ((pi.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0) {
                    ac.systemApps++;
                } else {
                    ac.userApps++;
                }
            }
        } catch (Throwable ignored) {}
        cachedAppCounts = ac;
        lastAppCountMillis = now;
        return ac;
    }

    private static JSONArray cachedInventorySections = null;
    private static long lastInventoryMillis = 0L;

    public static BatterySnapshot readBattery(Context ctx, AgentConfig cfg) {
        BatterySnapshot bs = new BatterySnapshot();
        Intent batIntent = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        int level = -1;
        int scale = 100;
        int status = -1;
        int tempTenths = 0;
        int voltMv = 0;
        int sysCycles = -1;
        if (batIntent != null) {
            level = batIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            scale = Math.max(1, batIntent.getIntExtra(BatteryManager.EXTRA_SCALE, 100));
            status = batIntent.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            tempTenths = batIntent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0);
            voltMv = batIntent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0);
            sysCycles = batIntent.getIntExtra("android.os.extra.CYCLE_COUNT", -1);
        }

        bs.levelPct = level >= 0 ? (level * 100) / scale : 0;
        boolean charging = status == BatteryManager.BATTERY_STATUS_CHARGING;
        bs.statusText = status == BatteryManager.BATTERY_STATUS_FULL ? "Full"
                : charging ? "Charging"
                : status == BatteryManager.BATTERY_STATUS_DISCHARGING ? "Discharging"
                : "Not Charging";
        bs.tempC = tempTenths / 10.0;
        bs.voltageV = voltMv / 1000.0;

        BatteryManager bm = (BatteryManager) ctx.getSystemService(Context.BATTERY_SERVICE);
        int chargeCounterUah = 0;
        if (bm != null) {
            try {
                chargeCounterUah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
                int curUa = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW);
                if (Math.abs(curUa) > 10000) curUa /= 1000;
                bs.currentMa = curUa;
            } catch (Throwable ignored) {}
        }

        double sysDesign = getDesignCapacityMah(ctx, cfg);
        BatteryHistory hist = new BatteryHistory(ctx);
        hist.recordSample(ctx, bs.levelPct, charging, chargeCounterUah, sysDesign, sysCycles);
        BatteryHistory.BatteryData hd = hist.getStats(cfg, sysDesign);

        bs.designMah = hd.designCapMah;
        bs.estFullMah = hd.estFullCapMah;
        bs.healthPct = hd.healthPercent;
        bs.cycles = hd.estimatedCycles;
        bs.calcMethod = hd.calcMethod;
        return bs;
    }

    private static double getDesignCapacityMah(Context ctx, AgentConfig cfg) {
        int override = cfg.getBatteryDesignMahOverride();
        if (override > 200) return override;
        try {
            Class<?> ppClass = Class.forName("com.android.internal.os.PowerProfile");
            Object pp = ppClass.getConstructor(Context.class).newInstance(ctx);
            Object capObj = ppClass.getMethod("getBatteryCapacity").invoke(pp);
            if (capObj instanceof Number) {
                double val = ((Number) capObj).doubleValue();
                if (val > 500 && val < 20000) return val;
            }
        } catch (Throwable ignored) {}
        String model = (Build.MODEL == null ? "" : Build.MODEL).toUpperCase(Locale.US);
        if (model.contains("MT93")) return 4800.0;
        return 4500.0;
    }

    public static RamStorageSnapshot readRamStorage(Context ctx) {
        RamStorageSnapshot rs = new RamStorageSnapshot();
        try {
            ActivityManager am = (ActivityManager) ctx.getSystemService(Context.ACTIVITY_SERVICE);
            ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
            if (am != null) {
                am.getMemoryInfo(mi);
                double div = 1024.0 * 1024.0 * 1024.0;
                rs.ramTotalGb = mi.totalMem / div;
                rs.ramFreeGb = mi.availMem / div;
                rs.ramUsedGb = Math.max(0.0, rs.ramTotalGb - rs.ramFreeGb);
                rs.ramPct = mi.totalMem > 0 ? (int) Math.round((rs.ramUsedGb / rs.ramTotalGb) * 100.0) : 0;
            }
        } catch (Throwable ignored) {}

        try {
            StatFs sf = new StatFs(Environment.getDataDirectory().getPath());
            long total = sf.getTotalBytes();
            long avail = sf.getAvailableBytes();
            long used = Math.max(0L, total - avail);
            double div = 1024.0 * 1024.0 * 1024.0;
            rs.storageTotalGb = total / div;
            rs.storageFreeGb = avail / div;
            rs.storageUsedGb = used / div;
            rs.storagePct = total > 0 ? (int) Math.round(((double) used / total) * 100.0) : 0;
        } catch (Throwable ignored) {}

        return rs;
    }

    public static boolean hasFineLocationPermission(Context ctx) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true;
        try {
            return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    == PackageManager.PERMISSION_GRANTED;
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static boolean isLocationServiceEnabled(Context ctx) {
        try {
            LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
            if (lm == null) return true;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                return lm.isLocationEnabled();
            }
            return lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
                    || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
        } catch (Throwable ignored) {
            return true;
        }
    }

    @SuppressWarnings("deprecation")
    public static WifiSnapshot readWifi(Context ctx) {
        WifiSnapshot ws = new WifiSnapshot();
        ws.ip = AgentConfig.getDeviceIpv4(ctx);
        ws.status = "Disconnected";
        ws.ssid = "N/A";
        ws.bssid = "N/A";
        ws.vendor = "AP";
        ws.bandChannel = "N/A";

        boolean hasWifiTransport = false;
        WifiInfo capWifiInfo = null;
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network active = cm.getActiveNetwork();
                NetworkCapabilities nc = active != null ? cm.getNetworkCapabilities(active) : null;
                if (nc != null && nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    hasWifiTransport = true;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        TransportInfo ti = nc.getTransportInfo();
                        if (ti instanceof WifiInfo) {
                            capWifiInfo = (WifiInfo) ti;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}

        try {
            WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null && wm.isWifiEnabled()) {
                WifiInfo wi = wm.getConnectionInfo();
                if (wi == null) wi = capWifiInfo;

                int rssi = wi != null ? wi.getRssi() : -127;
                int freq = wi != null ? wi.getFrequency() : 0;
                int speed = wi != null ? wi.getLinkSpeed() : 0;
                if (capWifiInfo != null) {
                    if (rssi <= -127 && capWifiInfo.getRssi() > -127) rssi = capWifiInfo.getRssi();
                    if (freq <= 0 && capWifiInfo.getFrequency() > 0) freq = capWifiInfo.getFrequency();
                    if (speed <= 0 && capWifiInfo.getLinkSpeed() > 0) speed = capWifiInfo.getLinkSpeed();
                }

                boolean supplicantCompleted = wi != null && wi.getSupplicantState() == SupplicantState.COMPLETED;
                boolean validRssi = rssi > -127 && rssi < 0;
                boolean hasLocalIp = ws.ip != null && !ws.ip.isEmpty() && !"0.0.0.0".equals(ws.ip);
                boolean isConnected = hasWifiTransport
                        || (wi != null && wi.getNetworkId() != -1)
                        || supplicantCompleted
                        || validRssi
                        || freq > 0
                        || hasLocalIp;

                if (isConnected) {
                    ws.status = "Connected";
                    ws.rssiDbm = validRssi ? rssi : 0;
                    ws.linkSpeedMbps = Math.max(0, speed);
                    ws.bandChannel = WifiRoamingTracker.formatBandAndChannel(freq);

                    String rawSsid = wi != null ? wi.getSSID() : null;
                    if (!WifiRoamingTracker.isValidSsid(rawSsid) && capWifiInfo != null) {
                        rawSsid = capWifiInfo.getSSID();
                    }
                    String rawBssid = wi != null ? wi.getBSSID() : null;
                    if (!WifiRoamingTracker.isValidBssid(rawBssid) && capWifiInfo != null) {
                        rawBssid = capWifiInfo.getBSSID();
                    }

                    // Fallback ke ScanResults jika BSSID diketahui tetapi SSID tersembunyi (atau sebaliknya)
                    if ((!WifiRoamingTracker.isValidSsid(rawSsid) || !WifiRoamingTracker.isValidBssid(rawBssid))
                            && hasFineLocationPermission(ctx) && isLocationServiceEnabled(ctx)) {
                        try {
                            List<ScanResult> scans = wm.getScanResults();
                            if (scans != null) {
                                if (WifiRoamingTracker.isValidBssid(rawBssid) && !WifiRoamingTracker.isValidSsid(rawSsid)) {
                                    for (ScanResult sr : scans) {
                                        if (sr != null && sr.BSSID != null && sr.BSSID.equalsIgnoreCase(rawBssid)
                                                && WifiRoamingTracker.isValidSsid(sr.SSID)) {
                                            rawSsid = sr.SSID;
                                            break;
                                        }
                                    }
                                } else if (WifiRoamingTracker.isValidSsid(rawSsid) && !WifiRoamingTracker.isValidBssid(rawBssid)) {
                                    String cleanTarget = rawSsid.replace("\"", "").trim();
                                    ScanResult best = null;
                                    for (ScanResult sr : scans) {
                                        if (sr != null && cleanTarget.equals(sr.SSID) && WifiRoamingTracker.isValidBssid(sr.BSSID)) {
                                            if (best == null || sr.level > best.level) best = sr;
                                        }
                                    }
                                    if (best != null) rawBssid = best.BSSID;
                                }
                            }
                        } catch (Throwable ignored) {}
                    }

                    WifiRoamingTracker rt = WifiRoamingTracker.getInstance();
                    rt.recordWifiSample(ctx, rawSsid, rawBssid, freq, ws.ip);

                    String resolvedSsid = WifiRoamingTracker.isValidSsid(rawSsid)
                            ? rawSsid.replace("\"", "").trim()
                            : rt.getCachedSsid(ctx, ws.ip);
                    String resolvedBssid = WifiRoamingTracker.isValidBssid(rawBssid)
                            ? rawBssid.trim().toUpperCase(Locale.US)
                            : rt.getCachedBssid(ctx, ws.ip);

                    boolean fineGranted = hasFineLocationPermission(ctx);
                    boolean gpsEnabled = isLocationServiceEnabled(ctx);

                    if (!resolvedSsid.isEmpty()) {
                        ws.ssid = resolvedSsid;
                    } else if (!fineGranted) {
                        ws.ssid = "Connected (Izin Lokasi Akurat diperlukan)";
                    } else if (!gpsEnabled) {
                        ws.ssid = "Connected (Nyalakan GPS/Lokasi HP)";
                    } else {
                        ws.ssid = "Connected (SSID restricted by OS)";
                    }

                    if (!resolvedBssid.isEmpty()) {
                        ws.bssid = resolvedBssid;
                    } else if (!fineGranted) {
                        ws.bssid = "Butuh Izin Lokasi Akurat";
                    } else if (!gpsEnabled) {
                        ws.bssid = "Nyalakan GPS/Lokasi HP";
                    } else {
                        ws.bssid = "Restricted (Enable Location)";
                    }

                    ws.vendor = WifiRoamingTracker.identifyApVendor(resolvedBssid);
                }
            }
        } catch (Throwable ignored) {}

        WifiRoamingTracker rt = WifiRoamingTracker.getInstance();
        ws.roam1h = rt.getRoamCountLastHour();
        ws.roamTotal = rt.getTotalRoamCount();
        ws.lastRoam = rt.getLastTransition();
        return ws;
    }

    public static String buildSnapshotJson(Context ctx, AgentConfig cfg) {
        long nowSec = System.currentTimeMillis() / 1000L;
        BatterySnapshot bs = readBattery(ctx, cfg);
        RamStorageSnapshot rs = readRamStorage(ctx);
        WifiSnapshot ws = readWifi(ctx);
        NetworkTrafficSnapshot nt = sampleNetworkTraffic(ctx, ws.ip, ws.ssid);

        JSONArray checks = new JSONArray();

        // 1. Health_Battery (Standar Mobile PDA WMS: OK >= 60%, Warning 40% s.d. 59%, Critical < 40%)
        int batState = bs.healthPct < 40.0 ? 2 : (bs.healthPct < 60.0 ? 1 : 0);
        String batLbl = batState == 2 ? "CRITICAL" : batState == 1 ? "WARNING" : "OK";
        addCheck(checks, batState, "Health_Battery",
                String.format(Locale.US,
                        "battery_level=%d%%|battery_health=%.1f%%;60;40|battery_cycles=%d|battery_temp=%.1f|battery_voltage=%.2f|battery_current=%d",
                        bs.levelPct, bs.healthPct, bs.cycles, bs.tempC, bs.voltageV, bs.currentMa),
                String.format(Locale.US,
                        "Status : %s | Level : %d%% (%s) | Real Health : %.1f%% | Cycles : %d | Full Capacity : %.0f mAh | Design Spec : %.0f mAh | Current Charge : %.0f mAh | Temp : %.1f C | Voltage : %.2f V | Current : %d mA | Calculation : %s",
                        batLbl, bs.levelPct, bs.statusText, bs.healthPct, bs.cycles,
                        bs.estFullMah, bs.designMah, bs.estFullMah, bs.tempC, bs.voltageV, bs.currentMa, bs.calcMethod),
                null, null);

        // 2. Android_Info
        String uptimeStr = formatUptime(SystemClock.elapsedRealtime() / 1000L);
        String profile = (Build.MANUFACTURER + " " + Build.MODEL).trim();
        addCheck(checks, 0, "Android_Info", "-",
                String.format(Locale.US,
                        "Status : OK | Manufacturer : %s | Model : %s | Profile : %s | Android : %s | SDK : %d | Uptime : %s",
                        Build.MANUFACTURER, Build.MODEL, profile, Build.VERSION.RELEASE, Build.VERSION.SDK_INT, uptimeStr),
                null, null);

        // 3. WiFi_Status (Standar Mobile PDA WMS: OK <=70dBm [>=-70], Warning >71 & <=80 [-71 s.d. -80], Critical >80 [<-80] / Disconnected)
        int wifiState;
        if ("Disconnected".equals(ws.status) || (ws.rssiDbm != 0 && ws.rssiDbm < -80)) {
            wifiState = 2;
        } else if (ws.rssiDbm != 0 && ws.rssiDbm < -70) {
            wifiState = 1;
        } else {
            wifiState = 0;
        }
        String wifiLbl = wifiState == 2 ? "CRITICAL" : wifiState == 1 ? "WARNING" : "OK";
        addCheck(checks, wifiState, "WiFi_Status",
                String.format(Locale.US, "wifi_rssi=%ddBm;-71;-81|wifi_speed=%d|wifi_roam_1h=%d", ws.rssiDbm, ws.linkSpeedMbps, ws.roam1h),
                String.format(Locale.US,
                        "Status : %s | SSID : %s | AP BSSID : %s (%s) | Band : %s | Roaming : %dx/1h (Total %dx, Last %s) | Signal : %d dBm | Link Speed : %d Mbps | IP : %s",
                        wifiLbl, ws.ssid, ws.bssid, ws.vendor, ws.bandChannel,
                        ws.roam1h, ws.roamTotal, ws.lastRoam, ws.rssiDbm, ws.linkSpeedMbps, ws.ip),
                null, null);

        // 4. Info_Network (Standar Mobile PDA WMS: Mengetahui trafik network & log file CSV, selalu Status OK = 0)
        addCheck(checks, 0, "Info_Network",
                String.format(Locale.US, "in=%dc|out=%dc|rx_rate=%d|tx_rate=%d",
                        nt.rxTotalBytes, nt.txTotalBytes, nt.rxRateBps, nt.txRateBps),
                String.format(Locale.US,
                        "Status : OK | IP Address : %s | Total Download : %s | Total Upload : %s | RX Rate : %s | TX Rate : %s | CSV : %s",
                        ws.ip, nt.rxTotalHuman, nt.txTotalHuman, nt.rxRateHuman, nt.txRateHuman, TRAFFIC_CSV_FILE),
                null, null);

        // 4. RAM_Usage (cached 1800s)
        int ramState = rs.ramPct >= 95 ? 2 : rs.ramPct >= 85 ? 1 : 0;
        String ramLbl = ramState == 2 ? "CRITICAL" : ramState == 1 ? "WARNING" : "OK";
        addCheck(checks, ramState, "RAM_Usage",
                String.format(Locale.US, "ram_used=%d%%;85;95", rs.ramPct),
                String.format(Locale.US, "Status : %s | Used : %d%% (%.2f GB) | Free : %.2f GB | Total : %.2f GB",
                        ramLbl, rs.ramPct, rs.ramUsedGb, rs.ramFreeGb, rs.ramTotalGb),
                1800L, nowSec);

        // 5. Storage_Usage (cached 86400s)
        int stState = rs.storagePct >= 95 ? 2 : rs.storagePct >= 85 ? 1 : 0;
        String stLbl = stState == 2 ? "CRITICAL" : stState == 1 ? "WARNING" : "OK";
        addCheck(checks, stState, "Storage_Usage",
                String.format(Locale.US, "storage_used=%d%%;85;95", rs.storagePct),
                String.format(Locale.US, "Status : %s | Used : %d%% (%.2f GB) | Free : %.2f GB | Total : %.2f GB",
                        stLbl, rs.storagePct, rs.storageUsedGb, rs.storageFreeGb, rs.storageTotalGb),
                86400L, nowSec);

        JSONObject root = new JSONObject();
        try {
            root.put("hostname", cfg.getHostname());
            root.put("gateway_ip", cfg.getGatewayIp());
            root.put("local_checks", checks);
            root.put("raw_sections", getOrBuildInventory(ctx, rs, cfg));
        } catch (Throwable ignored) {}
        return root.toString();
    }

    private static void addCheck(JSONArray arr, int state, String name, String metrics, String summary, Long cacheTtl, Long cacheEpoch) {
        try {
            JSONObject o = new JSONObject();
            o.put("state", state);
            o.put("service_name", name);
            o.put("metrics", metrics);
            o.put("summary", summary);
            if (cacheTtl != null && cacheEpoch != null) {
                o.put("cache_ttl_sec", cacheTtl);
                o.put("cache_epoch_sec", cacheEpoch);
            }
            arr.put(o);
        } catch (Throwable ignored) {}
    }

    private static synchronized JSONArray getOrBuildInventory(Context ctx, RamStorageSnapshot rs, AgentConfig cfg) {
        long now = System.currentTimeMillis();
        if (cachedInventorySections != null && (now - lastInventoryMillis) < 21_600_000L) {
            return cachedInventorySections;
        }
        JSONArray arr = new JSONArray();
        try {
            addRaw(arr, "<<<lnx_uname>>>", Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "aarch64");
            addRaw(arr, "<<<lnx_distro:sep(124)>>>",
                    "Distributor ID|Android\nDescription|Android " + Build.VERSION.RELEASE + "\nRelease|" + Build.VERSION.RELEASE + "\nCodename|" + Build.VERSION.CODENAME);

            String cpuinfo = readTextFile("/proc/cpuinfo");
            if (!cpuinfo.isEmpty()) {
                addRaw(arr, "<<<lnx_cpuinfo:sep(58)>>>", cpuinfo);
            }

            long ramMb = Math.round(rs.ramTotalGb * 1024.0);
            String safeMfg = (Build.MANUFACTURER == null ? "Android" : Build.MANUFACTURER).replace(":", "-");
            String safeModel = (Build.MODEL == null ? "Device" : Build.MODEL).replace(":", "-");
            String safeSerial = (cfg.getHostname() == null ? "unknown" : cfg.getHostname()).replace(":", "-");
            String dmi = String.format(Locale.US,
                    "System Information\n:Manufacturer: %s\n:Product Name: %s\n:Serial Number: %s\n"
                            + "Physical Memory Array\n:Location: System Board Or Motherboard\n:Use: System Memory\n:Number Of Devices: 1\n"
                            + "Memory Device\n:Size: %d MB\n:Locator: Internal RAM\n:Type: RAM",
                    safeMfg, safeModel, safeSerial, ramMb);
            addRaw(arr, "<<<dmidecode:sep(58)>>>", dmi);

            long diskBytes = Math.round(rs.storageTotalGb * 1024.0 * 1024.0 * 1024.0);
            addRaw(arr, "<<<lnx_block_devices:sep(0)>>>",
                    "|mmcblk0|\nsize|" + diskBytes + "\ndevice/model|" + Build.MODEL);

            PackageManager pm = ctx.getPackageManager();
            List<PackageInfo> pkgs = pm.getInstalledPackages(0);
            StringBuilder sb = new StringBuilder();
            for (PackageInfo pi : pkgs) {
                if (pi == null || pi.packageName == null) continue;
                String ver = pi.versionName == null ? "0" : pi.versionName.replace("|", "_");
                boolean isSys = pi.applicationInfo != null && (pi.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                String cat = isSys ? "system" : "android";
                sb.append(pi.packageName).append('|').append(ver).append('|')
                        .append(Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "arm64")
                        .append('|').append(cat).append("|apk|Android Package\n");
            }
            if (sb.length() > 0) {
                addRaw(arr, "<<<lnx_packages:sep(124)>>>", sb.toString());
            }
        } catch (Throwable ignored) {}

        cachedInventorySections = arr;
        lastInventoryMillis = now;
        return arr;
    }

    private static void addRaw(JSONArray arr, String header, String body) {
        try {
            JSONObject o = new JSONObject();
            o.put("header", header);
            o.put("body", body);
            arr.put(o);
        } catch (Throwable ignored) {}
    }

    private static String readTextFile(String path) {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader br = new BufferedReader(new FileReader(path))) {
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append('\n');
            }
        } catch (Throwable ignored) {}
        return sb.toString();
    }

    public static String formatUptime(long totalSec) {
        long days = totalSec / 86400;
        long hrs = (totalSec % 86400) / 3600;
        long mins = (totalSec % 3600) / 60;
        if (days > 0) return String.format(Locale.US, "%dd %dh %dm", days, hrs, mins);
        if (hrs > 0) return String.format(Locale.US, "%dh %dm", hrs, mins);
        return String.format(Locale.US, "%dm", mins);
    }
}
