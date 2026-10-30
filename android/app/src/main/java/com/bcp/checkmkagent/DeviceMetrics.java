package com.bcp.checkmkagent;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.RouteInfo;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.SystemClock;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

public final class DeviceMetrics {

    public static final double MT93_FULL_CAPACITY_MAH = 2946.0;
    public static final double MT93_DESIGN_CAPACITY_MAH = 4800.0;

    private DeviceMetrics() {}

    public static final class BatteryInfo {
        public int level = -1;
        public boolean plugged = false;
        public double temperatureC = Double.NaN;
        public double voltageV = Double.NaN;
        public String status = "Unknown";
        public String healthStatus = "Good";
        public double chargeCounterMah = Double.NaN;
        public double currentNowMa = Double.NaN;
        public double currentAverageMa = Double.NaN;
        public double designCapacityMah = Double.NaN;
        public String designCapacitySource = "Unavailable";
        public double fullCapacityMah = Double.NaN;
        public double fullChargeVoltageV = Double.NaN;
        public String fullCapacitySource = "Unavailable";
        public boolean fullCapacityEstimated = false;
        public double healthPercent = 100.0;
        public int estimateSamples = 0;
        public int cycleCount = 0;
        public int chargeSessions = 0;
        public double totalChargedMah = 0.0;
    }

    public static final class UsageInfo {
        public double totalGb;
        public double freeGb;
        public double usedGb;
        public double usedPercent;
    }

    public static final class WifiStatus {
        public boolean connected;
        public String ssid = "Not Connected";
        public String bssid = "N/A";
        public String apVendor = "AP";
        public String bandChannel = "N/A";
        public String ip = "N/A";
        public int rssi = Integer.MIN_VALUE;
        public int linkSpeedMbps = -1;
        public int frequencyMhz = -1;
        public int roamsLastHour = 0;
        public int totalRoams = 0;
        public String previousBssid = "-";
        public String lastRoamReason = "-";
        public String roamSummary = "Stable on AP (0x/1h)";
        public String detectionSource = "Unavailable";
        public String detailsSource = "Unavailable";
    }

    public static final class DeviceInfo {
        public String manufacturer;
        public String model;
        public String androidVersion;
        public int sdk;
        public long uptimeMs;
        public String profile;
        public String hardwareSoc;
        public String board;
        public String kernelVersion;
        public String arch;
    }

    public static final class AppInventoryInfo {
        public int totalApps = 0;
        public int userApps = 0;
        public int systemApps = 0;
        public String fullInventoryPayload = "";
    }

    public static AppInventoryInfo readAppInventory(Context context) {
        AppInventoryInfo info = new AppInventoryInfo();
        if (context == null) return info;

        StringBuilder sb = new StringBuilder();
        DeviceInfo dev = readDeviceInfo();
        UsageInfo ram = readRam(context);
        UsageInfo storage = readStorage();

        // 1. HARDWARE: SYSTEM & MEMORY (RAM)
        long ramTotalMb = Math.round(ram.totalGb * 1024.0);
        sb.append("<<<dmidecode:sep(58)>>>\n");
        sb.append("System Information\n");
        sb.append(":Manufacturer: ").append(dev.manufacturer).append("\n");
        sb.append(":Product Name: ").append(dev.model).append("\n");
        sb.append(":Version: Android ").append(dev.androidVersion).append("\n");
        sb.append(":Serial Number: ").append(dev.board).append("\n");
        sb.append(":UUID: ").append(dev.profile.hashCode()).append("\n\n");

        sb.append("Physical Memory Array\n");
        sb.append(":Location: System Board\n");
        sb.append(":Use: System Memory\n");
        sb.append(":Maximum Capacity: ").append(ramTotalMb).append(" MB\n");
        sb.append(":Number Of Devices: 1\n\n");

        sb.append("Memory Device\n");
        sb.append(":Array Handle: 0x0001\n");
        sb.append(":Total Width: 64 bits\n");
        sb.append(":Data Width: 64 bits\n");
        sb.append(":Size: ").append(ramTotalMb).append(" MB\n");
        sb.append(":Form Factor: Row Of Chips\n");
        sb.append(":Locator: RAM 0\n");
        sb.append(":Bank Locator: Bank 0\n");
        sb.append(":Type: LPDDR4\n");
        sb.append(":Type Detail: Synchronous\n");
        sb.append(":Speed: 1866 MT/s\n");
        sb.append(":Manufacturer: ").append(dev.manufacturer).append("\n\n");

        // 2. HARDWARE: PROCESSOR
        int cores = Math.max(1, Runtime.getRuntime().availableProcessors());
        sb.append("<<<lnx_cpuinfo:sep(58)>>>\n");
        for (int i = 0; i < cores; i++) {
            sb.append("processor: ").append(i).append("\n");
            sb.append("model name: ").append(dev.hardwareSoc).append(" (").append(dev.board).append(")\n");
            sb.append("cpu MHz: 2000.000\n");
            sb.append("cache size: 1024 KB\n");
            sb.append("flags: fp asimd evtstrm aes pmull sha1 sha2 crc32\n\n");
        }

        // 3. HARDWARE: STORAGE
        long storageSectors512 = Math.round(storage.totalGb * 1024.0 * 1024.0 * 2.0);
        sb.append("<<<lnx_block_devices:sep(0)>>>\n");
        sb.append("|device|/sys/block/internal_storage|\n");
        sb.append("|size|").append(storageSectors512).append("|\n");
        sb.append("|device/vendor|Internal|\n");
        sb.append("|device/model|eMMC/UFS Internal Storage (").append(Math.round(storage.totalGb)).append(" GB)|\n");
        sb.append("|device/type|MMC|\n\n");

        // 4. SOFTWARE: OPERATING SYSTEM
        sb.append("<<<lnx_distro:sep(124)>>>\n");
        sb.append("[[[/etc/os-release]]]\n");
        sb.append("NAME=\"Android\"|VERSION=\"").append(dev.androidVersion)
          .append(" (SDK ").append(dev.sdk).append(")\"|ID=android|PRETTY_NAME=\"Android ")
          .append(dev.androidVersion).append(" (").append(dev.manufacturer).append(" ")
          .append(dev.model).append(")\"\n\n");

        sb.append("<<<lnx_uname>>>\n");
        sb.append("Linux ").append(AgentConfig.getHostname(context)).append(" ")
          .append(dev.kernelVersion).append(" #1 SMP PREEMPT ")
          .append(dev.arch).append(" Android\n\n");

        // 5. SOFTWARE: PACKAGES
        sb.append("<<<lnx_packages:sep(124)>>>\n");
        try {
            PackageManager pm = context.getPackageManager();
            List<PackageInfo> packages = pm.getInstalledPackages(0);

            for (PackageInfo pkg : packages) {
                if (pkg == null || pkg.packageName == null) continue;

                boolean isSystem = false;
                String appLabel = pkg.packageName;

                if (pkg.applicationInfo != null) {
                    isSystem = (pkg.applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                    try {
                        CharSequence label = pkg.applicationInfo.loadLabel(pm);
                        if (label != null && label.length() > 0) {
                            appLabel = label.toString().replace('|', ' ')
                                    .replace('\n', ' ').replace('\r', ' ').trim();
                        }
                    } catch (Throwable ignored) {}
                }

                info.totalApps++;
                if (isSystem) info.systemApps++;
                else info.userApps++;

                String ver = pkg.versionName != null ? pkg.versionName.trim().replace('|', ' ') : "1.0";
                String pkgType = isSystem ? "system" : "apk";
                long verCode = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                        ? pkg.getLongVersionCode() : pkg.versionCode;

                sb.append(pkg.packageName).append('|')
                  .append(ver).append('|')
                  .append(dev.arch).append('|')
                  .append(pkgType).append('|')
                  .append(verCode).append('|')
                  .append(appLabel).append('|')
                  .append("installed\n");
            }
        } catch (Throwable ignored) {}

        info.fullInventoryPayload = sb.toString();
        return info;
    }

    public static BatteryInfo readBattery(Context context) {
        BatteryInfo out = new BatteryInfo();
        if (context == null) return out;

        boolean isMt93 = isNewlandMt93();
        int hwCycles = -1;

        try {
            Intent battery = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery != null) {
                int rawLevel = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                if (rawLevel >= 0 && scale > 0) {
                    out.level = (int) Math.round(rawLevel * 100.0 / scale);
                }

                int plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
                out.plugged = plugged > 0;

                int tempTenths = battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE);
                if (tempTenths != Integer.MIN_VALUE && tempTenths != 0) {
                    out.temperatureC = tempTenths / 10.0;
                }

                int voltageMv = battery.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1);
                if (voltageMv > 0) {
                    out.voltageV = voltageMv > 100 ? (voltageMv / 1000.0) : voltageMv;
                }

                int status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN);
                switch (status) {
                    case BatteryManager.BATTERY_STATUS_CHARGING:
                        out.status = "Charging";
                        break;
                    case BatteryManager.BATTERY_STATUS_DISCHARGING:
                        out.status = "Discharging";
                        break;
                    case BatteryManager.BATTERY_STATUS_FULL:
                        out.status = "Full";
                        break;
                    case BatteryManager.BATTERY_STATUS_NOT_CHARGING:
                        out.status = "Not Charging";
                        break;
                    default:
                        out.status = "Unknown";
                }

                int rawHealth = battery.getIntExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_UNKNOWN);
                switch (rawHealth) {
                    case BatteryManager.BATTERY_HEALTH_GOOD:
                        out.healthStatus = "Good";
                        break;
                    case BatteryManager.BATTERY_HEALTH_OVERHEAT:
                        out.healthStatus = "Overheat";
                        break;
                    case BatteryManager.BATTERY_HEALTH_DEAD:
                        out.healthStatus = "Dead";
                        break;
                    case BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE:
                        out.healthStatus = "Over Voltage";
                        break;
                    case BatteryManager.BATTERY_HEALTH_COLD:
                        out.healthStatus = "Cold";
                        break;
                    default:
                        out.healthStatus = "Unknown";
                }

                String[] cycleExtras = {
                        "android.os.extra.CYCLE_COUNT",
                        "cycle_count",
                        "charge_cycles",
                        "battery_cycle"
                };
                for (String key : cycleExtras) {
                    int c = battery.getIntExtra(key, -1);
                    if (c > 0) {
                        hwCycles = c;
                        break;
                    }
                }
            }
        } catch (Throwable ignored) {}

        boolean hasHardwareChargeCounter = false;
        try {
            BatteryManager bm = (BatteryManager) context.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                try {
                    int chargeCounterUah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
                    if (validBatteryProperty(chargeCounterUah) && chargeCounterUah > 0) {
                        out.chargeCounterMah = chargeCounterUah > 10000
                                ? (chargeCounterUah / 1000.0) : chargeCounterUah;
                        hasHardwareChargeCounter = true;
                    }
                } catch (Throwable ignored) {}

                try {
                    int currentNowUa = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW);
                    if (validBatteryProperty(currentNowUa) && currentNowUa != 0) {
                        out.currentNowMa = Math.abs(currentNowUa) > 20000
                                ? (currentNowUa / 1000.0) : currentNowUa;
                    }
                } catch (Throwable ignored) {}

                try {
                    int currentAvgUa = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE);
                    if (validBatteryProperty(currentAvgUa)) {
                        out.currentAverageMa = Math.abs(currentAvgUa) > 20000
                                ? (currentAvgUa / 1000.0) : currentAvgUa;
                    }
                } catch (Throwable ignored) {}

                try {
                    int cycles = bm.getIntProperty(7); // BATTERY_PROPERTY_CYCLE_COUNT
                    if (validBatteryProperty(cycles) && cycles > 0) {
                        hwCycles = Math.max(hwCycles, cycles);
                    }
                } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}

        // 1. Check Sysfs Kernel nodes for cycle count if not already > 0
        if (hwCycles <= 0) {
            String[] cyclePaths = {
                    "/sys/class/power_supply/battery/cycle_count",
                    "/sys/class/power_supply/bms/cycle_count",
                    "/sys/class/power_supply/battery/battery_cycle",
                    "/sys/devices/platform/charger/power_supply/battery/cycle_count",
                    "/sys/devices/platform/mtk-battery/power_supply/battery/cycle_count",
                    "/sys/devices/platform/battery/power_supply/battery/cycle_count",
                    "/sys/class/power_supply/fg_adc/cycle_count"
            };
            for (String path : cyclePaths) {
                try {
                    Double val = readNumber(path);
                    if (val != null && val > 0) {
                        hwCycles = val.intValue();
                        break;
                    }
                } catch (Throwable ignored) {}
            }
        }

        // 2. Design Spec (4800 mAh for Newland MT93)
        try {
            double manual = AgentConfig.getDesignCapacityMah(context);
            if (isPositive(manual)) {
                out.designCapacityMah = manual;
                out.designCapacitySource = "Manual Configuration";
            } else {
                double profileVal = readPowerProfileCapacityMah(context);
                if (isPositive(profileVal)) {
                    out.designCapacityMah = profileVal;
                    out.designCapacitySource = "Android System (" + Math.round(profileVal) + " mAh)";
                } else {
                    out.designCapacityMah = isMt93 ? MT93_DESIGN_CAPACITY_MAH : 5000.0;
                    out.designCapacitySource = "Factory Spec (" + Math.round(out.designCapacityMah) + " mAh)";
                }
            }
        } catch (Throwable ignored) {
            out.designCapacityMah = isMt93 ? MT93_DESIGN_CAPACITY_MAH : 5000.0;
            out.designCapacitySource = "Factory Spec";
        }

        // 3. Full Capacity Reference Scale at 100% Charge: 2946 mAh on Newland MT93
        final double FULL_CHARGE_REF_MAH = isMt93 ? MT93_FULL_CAPACITY_MAH : out.designCapacityMah;

        if (!isPositive(out.chargeCounterMah) && out.level >= 0) {
            out.chargeCounterMah = Math.round(FULL_CHARGE_REF_MAH * (out.level / 100.0));
        }

        // 4. Update continuous battery charge session & cycle accumulator
        BatteryHistory.updateChargeSession(
                context, out.level, out.status, out.plugged,
                out.chargeCounterMah, out.voltageV, FULL_CHARGE_REF_MAH);
        out.estimateSamples = BatteryHistory.getSampleCount(context);
        out.chargeSessions = BatteryHistory.getChargeSessionCount(context);
        out.totalChargedMah = BatteryHistory.getAccumulatedChargedMah(context);

        int trackedCycles = BatteryHistory.getEstimatedCycles(context, FULL_CHARGE_REF_MAH);
        if (hwCycles > 0) {
            out.cycleCount = Math.max(hwCycles, trackedCycles);
        } else {
            out.cycleCount = Math.max(0, trackedCycles);
        }

        // 5. Health Calculation Based on 100% Full Capacity = 2946 mAh
        double calibratedFullMah = BatteryHistory.getCalibratedFullChargeMah(context);
        double calibratedVolt = BatteryHistory.getCalibratedFullVoltage(context);
        if (!Double.isNaN(calibratedVolt)) {
            out.fullChargeVoltageV = calibratedVolt;
        }

        if (isMt93) {
            if (out.level == 100 || "Full".equalsIgnoreCase(out.status)) {
                out.fullCapacityMah = (hasHardwareChargeCounter && out.chargeCounterMah > 1500.0)
                        ? out.chargeCounterMah : FULL_CHARGE_REF_MAH;
                out.fullChargeVoltageV = !Double.isNaN(out.voltageV) ? out.voltageV : 4.34;
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / FULL_CHARGE_REF_MAH) * 100.0);
                out.fullCapacitySource = "100% Full Charge (" + Math.round(out.fullCapacityMah) + " / 2946 mAh)";
            } else if (out.level >= 15 && isPositive(out.chargeCounterMah)) {
                double dynamicFullMah = out.chargeCounterMah / (out.level / 100.0);
                out.fullCapacityMah = !Double.isNaN(calibratedFullMah) ? calibratedFullMah : FULL_CHARGE_REF_MAH;
                out.healthPercent = Math.min(100.0, (dynamicFullMah / FULL_CHARGE_REF_MAH) * 100.0);
                out.fullCapacitySource = "Full Capacity 2946 mAh @ 100% (" + out.level + "% State)";
            } else {
                out.fullCapacityMah = !Double.isNaN(calibratedFullMah) ? calibratedFullMah : FULL_CHARGE_REF_MAH;
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / FULL_CHARGE_REF_MAH) * 100.0);
                out.fullCapacitySource = "Full Capacity 2946 mAh @ 100% Baseline";
            }
        } else {
            if (out.level == 100 || "Full".equalsIgnoreCase(out.status)) {
                out.fullCapacityMah = (isPositive(out.chargeCounterMah) && out.chargeCounterMah > 1500.0)
                        ? out.chargeCounterMah : out.designCapacityMah;
                out.fullChargeVoltageV = !Double.isNaN(out.voltageV) ? out.voltageV : 4.35;
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / out.designCapacityMah) * 100.0);
                out.fullCapacitySource = "100% Full Cut-off";
            } else if (out.level >= 15 && isPositive(out.chargeCounterMah)) {
                out.fullCapacityMah = out.chargeCounterMah / (out.level / 100.0);
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / out.designCapacityMah) * 100.0);
                out.fullCapacitySource = "Dynamic Estimate (" + out.level + "% State)";
                out.fullCapacityEstimated = true;
            } else {
                out.fullCapacityMah = out.designCapacityMah;
                out.healthPercent = 100.0;
                out.fullCapacitySource = "System Baseline";
            }
        }

        return out;
    }

    public static UsageInfo readRam(Context context) {
        ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
        if (am != null) am.getMemoryInfo(mi);

        UsageInfo out = new UsageInfo();
        out.totalGb = bytesToGb(mi.totalMem);
        out.freeGb = bytesToGb(mi.availMem);
        out.usedGb = Math.max(0, out.totalGb - out.freeGb);
        out.usedPercent = out.totalGb > 0 ? (out.usedGb / out.totalGb * 100.0) : 0.0;
        return out;
    }

    public static UsageInfo readStorage() {
        StatFs stat = new StatFs(Environment.getDataDirectory().getAbsolutePath());
        UsageInfo out = new UsageInfo();
        out.totalGb = bytesToGb(stat.getTotalBytes());
        out.freeGb = bytesToGb(stat.getAvailableBytes());
        out.usedGb = Math.max(0, out.totalGb - out.freeGb);
        out.usedPercent = out.totalGb > 0 ? (out.usedGb / out.totalGb * 100.0) : 0.0;
        return out;
    }

    @SuppressWarnings("deprecation")
    public static WifiStatus readWifi(Context context) {
        WifiStatus out = new WifiStatus();
        out.ip = getLocalIpv4();

        WifiManager wm = null;
        try {
            wm = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            ConnectivityManager cm = (ConnectivityManager) context
                    .getSystemService(Context.CONNECTIVITY_SERVICE);

            Network wifiNetwork = null;
            NetworkCapabilities wifiCaps = null;

            if (cm != null) {
                Network[] networks = cm.getAllNetworks();
                if (networks != null) {
                    for (Network network : networks) {
                        NetworkCapabilities caps = cm.getNetworkCapabilities(network);
                        if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                            wifiNetwork = network;
                            wifiCaps = caps;
                            break;
                        }
                    }
                }
            }

            if (wifiNetwork != null) {
                out.connected = true;
                out.detectionSource = "ConnectivityManager Wi-Fi transport";

                LinkProperties lp = cm.getLinkProperties(wifiNetwork);
                String ip = ipv4FromLinkProperties(lp);
                if (ip != null) out.ip = ip;

                WifiInfo info = wifiInfoFromCapabilities(wifiCaps);
                if (info != null) {
                    fillWifiInfo(out, info, "NetworkCapabilities WifiInfo");
                }
            }

            if (!out.connected) {
                String wlanIp = getWifiInterfaceIpv4();
                if (wlanIp != null) {
                    out.connected = true;
                    out.ip = wlanIp;
                    out.detectionSource = "wlan interface";
                }
            }

            // Always merge WifiManager.getConnectionInfo() so SSID and BSSID are populated on Android 11
            // even when NetworkCapabilities redacts them!
            if (wm != null && wm.isWifiEnabled()) {
                WifiInfo legacy = wm.getConnectionInfo();
                if (legacy != null) {
                    if (!out.connected && hasUsefulWifiInfo(legacy)) {
                        out.connected = true;
                        out.detectionSource = "WifiManager connection info";
                    }
                    if (out.connected) {
                        fillWifiInfo(out, legacy, "WifiManager connection info");
                    }
                }

                // Fallback to ScanResults matching if BSSID or SSID is still missing
                if (out.connected && ("N/A".equals(out.bssid) || "Not Connected".equals(out.ssid))) {
                    enrichFromScanResults(wm, out);
                }
            }

            if (out.connected && "Not Connected".equals(out.ssid)) {
                out.ssid = "Connected (SSID restricted by Android)";
            }
        } catch (SecurityException e) {
            String wlanIp = getWifiInterfaceIpv4();
            if (wlanIp != null) {
                out.connected = true;
                out.ip = wlanIp;
                out.detectionSource = "wlan interface (permission fallback)";
                out.ssid = "Connected (permission restricted)";
            }
        } catch (Exception ignored) {
            String wlanIp = getWifiInterfaceIpv4();
            if (wlanIp != null) {
                out.connected = true;
                out.ip = wlanIp;
                out.detectionSource = "wlan interface (fallback)";
                out.ssid = "Connected (details unavailable)";
            }
        }

        // Update AP Roaming Tracker (UniFi / Multi-AP BSSID & Channel Roaming)
        WifiRoamingTracker.RoamingInfo roam = WifiRoamingTracker.updateAndRead(
                context, out.connected, out.ssid, out.bssid, out.frequencyMhz, out.rssi, out.ip);
        out.bssid = roam.currentBssid;
        out.apVendor = roam.apVendor;
        out.bandChannel = roam.bandChannel;
        out.roamsLastHour = roam.roamsLastHour;
        out.totalRoams = roam.totalRoams;
        out.previousBssid = roam.previousBssid;
        out.lastRoamReason = roam.lastRoamReason;
        out.roamSummary = roam.summaryText;

        return out;
    }

    public static String getDetectedGatewayIp(Context context) {
        if (context == null) return "";
        try {
            ConnectivityManager cm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Network active = cm.getActiveNetwork();
                    if (active != null) {
                        LinkProperties lp = cm.getLinkProperties(active);
                        if (lp != null) {
                            for (RouteInfo route : lp.getRoutes()) {
                                if (route.isDefaultRoute() && route.getGateway() != null) {
                                    String gw = route.getGateway().getHostAddress();
                                    if (gw != null && !gw.isEmpty() && !"0.0.0.0".equals(gw)) {
                                        return gw;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                android.net.DhcpInfo dhcp = wm.getDhcpInfo();
                if (dhcp != null && dhcp.gateway != 0) {
                    int g = dhcp.gateway;
                    return (g & 0xFF) + "." + ((g >> 8) & 0xFF) + "." + ((g >> 16) & 0xFF) + "." + ((g >> 24) & 0xFF);
                }
            }
        } catch (Throwable ignored) {}
        return "";
    }

    private static WifiInfo wifiInfoFromCapabilities(NetworkCapabilities caps) {
        if (caps == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null;
        try {
            Object transportInfo = caps.getTransportInfo();
            return transportInfo instanceof WifiInfo ? (WifiInfo) transportInfo : null;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void fillWifiInfo(WifiStatus out, WifiInfo info, String source) {
        if (info == null) return;
        out.detailsSource = source;

        String ssid = info.getSSID();
        if (ssid != null && !ssid.isEmpty()
                && !"<unknown ssid>".equalsIgnoreCase(ssid)
                && !WifiManager.UNKNOWN_SSID.equals(ssid)) {
            if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length() >= 2) {
                ssid = ssid.substring(1, ssid.length() - 1);
            }
            out.ssid = ssid;
        }

        String cleanBssid = WifiRoamingTracker.normalizeBssid(info.getBSSID());
        if (cleanBssid != null) {
            out.bssid = cleanBssid;
        }

        int rssi = info.getRssi();
        if (isUsableRssi(rssi)) {
            out.rssi = rssi;
        }

        int speed = info.getLinkSpeed();
        if (speed >= 0) out.linkSpeedMbps = speed;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            int frequency = info.getFrequency();
            if (frequency > 0) out.frequencyMhz = frequency;
        }
    }

    private static void enrichFromScanResults(WifiManager wm, WifiStatus out) {
        try {
            List<ScanResult> results = wm.getScanResults();
            if (results == null || results.isEmpty()) return;
            ScanResult best = null;
            int bestDiff = Integer.MAX_VALUE;
            for (ScanResult sr : results) {
                if (sr == null || sr.BSSID == null) continue;
                if (out.frequencyMhz > 0 && sr.frequency != out.frequencyMhz) continue;
                if (!"Not Connected".equals(out.ssid) && sr.SSID != null && !sr.SSID.isEmpty()
                        && !out.ssid.equals(sr.SSID)) {
                    continue;
                }
                int diff = (out.rssi != Integer.MIN_VALUE) ? Math.abs(sr.level - out.rssi) : -sr.level;
                if (diff < bestDiff && diff <= 8) {
                    bestDiff = diff;
                    best = sr;
                }
            }
            if (best != null) {
                String cleanBssid = WifiRoamingTracker.normalizeBssid(best.BSSID);
                if ("N/A".equals(out.bssid) && cleanBssid != null) {
                    out.bssid = cleanBssid;
                }
                if ("Not Connected".equals(out.ssid) && best.SSID != null && !best.SSID.isEmpty()) {
                    out.ssid = best.SSID;
                }
            }
        } catch (Throwable ignored) {}
    }

    private static boolean hasUsefulWifiInfo(WifiInfo info) {
        if (info == null) return false;
        int rssi = info.getRssi();
        if (isUsableRssi(rssi)) return true;
        if (info.getLinkSpeed() > 0) return true;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && info.getFrequency() > 0) return true;
        String ssid = info.getSSID();
        return ssid != null && !ssid.isEmpty()
                && !"<unknown ssid>".equalsIgnoreCase(ssid)
                && !WifiManager.UNKNOWN_SSID.equals(ssid);
    }

    private static String ipv4FromLinkProperties(LinkProperties lp) {
        if (lp == null) return null;
        for (LinkAddress la : lp.getLinkAddresses()) {
            if (la.getAddress() instanceof Inet4Address && !la.getAddress().isLoopbackAddress()) {
                String ip = la.getAddress().getHostAddress();
                if (ip != null && !ip.startsWith("169.254.")) return ip;
            }
        }
        return null;
    }

    private static String getWifiInterfaceIpv4() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                String name = ni.getName() == null ? "" : ni.getName().toLowerCase(Locale.US);
                if (!ni.isUp() || ni.isLoopback()
                        || !(name.startsWith("wlan") || name.startsWith("wifi"))) {
                    continue;
                }
                for (java.net.InetAddress addr : Collections.list(ni.getInetAddresses())) {
                    if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                        String ip = addr.getHostAddress();
                        if (ip != null && !ip.startsWith("169.254.")) return ip;
                    }
                }
            }
        } catch (Exception ignored) {}
        return null;
    }

    public static DeviceInfo readDeviceInfo() {
        DeviceInfo out = new DeviceInfo();
        out.manufacturer = safe(Build.MANUFACTURER);
        out.model = safe(Build.MODEL);
        out.androidVersion = safe(Build.VERSION.RELEASE);
        out.sdk = Build.VERSION.SDK_INT;
        out.uptimeMs = SystemClock.elapsedRealtime();
        out.profile = out.manufacturer + " " + out.model;
        out.hardwareSoc = safe(Build.HARDWARE);
        out.board = safe(Build.BOARD);
        out.arch = safe(System.getProperty("os.arch"));
        out.kernelVersion = safe(System.getProperty("os.version"));
        return out;
    }

    public static String getLocalIpv4() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (java.net.InetAddress addr : Collections.list(ni.getInetAddresses())) {
                    if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                        String ip = addr.getHostAddress();
                        if (ip != null && !ip.startsWith("169.254.")) return ip;
                    }
                }
            }
        } catch (Exception ignored) {}
        return "N/A";
    }

    public static boolean isNewlandMt93() {
        String joined = (safe(Build.MANUFACTURER) + " " + safe(Build.MODEL) + " "
                + safe(Build.PRODUCT) + " " + safe(Build.DEVICE)).toUpperCase(Locale.US);
        return joined.contains("NEWLAND") || joined.contains("MT93") || joined.contains("NLS-MT93");
    }

    private static boolean isUsableRssi(int rssi) {
        return rssi > -127 && rssi <= 0;
    }

    private static boolean validBatteryProperty(int value) {
        return value != Integer.MIN_VALUE && value != Integer.MAX_VALUE;
    }

    private static Double readNumber(String path) {
        try {
            File f = new File(path);
            if (!f.isFile() || !f.canRead()) return null;
            try (BufferedReader reader = new BufferedReader(new FileReader(f))) {
                String line = reader.readLine();
                if (line == null) return null;
                return Double.parseDouble(line.trim());
            }
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static double readPowerProfileCapacityMah(Context context) {
        try {
            Class<?> clazz = Class.forName("com.android.internal.os.PowerProfile");
            Constructor<?> ctor = clazz.getConstructor(Context.class);
            Object profile = ctor.newInstance(context);
            Method method = clazz.getMethod("getBatteryCapacity");
            Object value = method.invoke(profile);
            if (value instanceof Double) {
                double mah = (Double) value;
                if (mah >= 500.0 && mah <= 30000.0) return mah;
            }
        } catch (Throwable ignored) {}
        return Double.NaN;
    }

    private static boolean isPositive(double value) {
        return !Double.isNaN(value) && !Double.isInfinite(value) && value > 0;
    }

    private static double bytesToGb(long bytes) {
        return bytes / 1024.0 / 1024.0 / 1024.0;
    }

    private static String safe(String value) {
        return value == null || value.trim().isEmpty() ? "Unknown" : value.trim();
    }

    public static String fmt1(double value) {
        return String.format(Locale.US, "%.1f", value);
    }

    public static String fmt2(double value) {
        return String.format(Locale.US, "%.2f", value);
    }
}
