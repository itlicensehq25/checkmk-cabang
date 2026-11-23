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
import java.io.FileReader;
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

        JSONArray checks = new JSONArray();

        // 1. Health_Battery
        int batState = (bs.healthPct < 20.0 || ("Discharging".equals(bs.statusText) && bs.levelPct <= 10)) ? 2
                : (bs.healthPct < 40.0 || ("Discharging".equals(bs.statusText) && bs.levelPct <= 20)) ? 1 : 0;
        String batLbl = batState == 2 ? "CRITICAL" : batState == 1 ? "WARNING" : "OK";
        addCheck(checks, batState, "Health_Battery",
                String.format(Locale.US,
                        "battery_level=%d%%|battery_health=%.1f%%|battery_cycles=%d|battery_temp=%.1f|battery_voltage=%.2f|battery_current=%d",
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

        // 3. WiFi_Status
        int wifiState = "Disconnected".equals(ws.status) ? 1 : (ws.rssiDbm != 0 && ws.rssiDbm < -82 ? 1 : 0);
        String wifiLbl = wifiState == 0 ? "OK" : "WARNING";
        addCheck(checks, wifiState, "WiFi_Status",
                String.format(Locale.US, "wifi_rssi=%ddBm|wifi_speed=%d|wifi_roam_1h=%d", ws.rssiDbm, ws.linkSpeedMbps, ws.roam1h),
                String.format(Locale.US,
                        "Status : %s | SSID : %s | AP BSSID : %s (%s) | Band : %s | Roaming : %dx/1h (Total %dx, Last %s) | Signal : %d dBm | Link Speed : %d Mbps | IP : %s",
                        wifiLbl, ws.ssid, ws.bssid, ws.vendor, ws.bandChannel,
                        ws.roam1h, ws.roamTotal, ws.lastRoam, ws.rssiDbm, ws.linkSpeedMbps, ws.ip),
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
            String dmi = String.format(Locale.US,
                    "System Information\n\tManufacturer: %s\n\tProduct Name: %s\n\tSerial Number: %s\nMemory Device\n\tSize: %d MB",
                    Build.MANUFACTURER, Build.MODEL, cfg.getHostname(), ramMb);
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
