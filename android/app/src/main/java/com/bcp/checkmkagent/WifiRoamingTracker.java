package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class WifiRoamingTracker {
    private static final WifiRoamingTracker INSTANCE = new WifiRoamingTracker();
    private static final String PREF_NAME = "cmk_wifi_roam_cache";
    private static final String KEY_LAST_SSID = "last_ssid";
    private static final String KEY_LAST_BSSID = "last_bssid";
    private static final String KEY_LAST_IP = "last_ip";

    private String currentBssid = "";
    private String currentSsid = "";
    private String currentIp = "";
    private String currentBandChan = "";
    private String lastTransition = "";
    private final List<Long> roamTimestampsMs = new ArrayList<>();
    private int totalRoamCount = 0;

    public static WifiRoamingTracker getInstance() {
        return INSTANCE;
    }

    public static boolean isValidSsid(String ssid) {
        if (ssid == null) return false;
        String clean = ssid.replace("\"", "").trim();
        return !clean.isEmpty()
                && !"<unknown ssid>".equalsIgnoreCase(clean)
                && !"N/A".equalsIgnoreCase(clean)
                && !clean.startsWith("Connected (");
    }

    public static boolean isValidBssid(String bssid) {
        if (bssid == null) return false;
        String clean = bssid.trim();
        return clean.length() == 17
                && clean.contains(":")
                && !"02:00:00:00:00:00".equalsIgnoreCase(clean)
                && !"00:00:00:00:00:00".equalsIgnoreCase(clean);
    }

    private static boolean startsWithAny(String upper, String... prefixes) {
        for (String p : prefixes) {
            if (upper.startsWith(p)) return true;
        }
        return false;
    }

    public static String identifyApVendor(String bssid) {
        if (!isValidBssid(bssid)) {
            return "AP";
        }
        String upper = bssid.trim().toUpperCase(Locale.US);
        if (startsWithAny(upper,
                "F0:9F:C2", "78:8A:20", "B4:FB:E4", "68:D7:9A", "74:83:C2", "18:E8:29",
                "E0:63:DA", "24:5A:4C", "D0:21:F9", "70:A7:41", "74:AC:B9", "80:2A:A8",
                "44:D9:E7", "FC:EC:DA", "60:22:32", "AC:8B:A9", "E4:38:83", "9C:05:D6",
                "28:70:4E", "0C:EA:14", "F4:92:BF", "DC:9F:DB", "04:18:D6", "00:27:22")) {
            return "UniFi AP";
        }
        if (startsWithAny(upper,
                "48:8F:5A", "CC:2D:E0", "B8:69:F4", "DC:2C:6E", "E4:8D:8C", "4C:5E:0C",
                "6C:3B:6B", "D4:CA:6D", "64:D1:54", "74:4D:28", "08:55:31", "18:FD:74",
                "2C:C8:1B", "C4:AD:34", "F4:1E:57", "78:9A:18", "D4:01:C3")) {
            return "MikroTik AP";
        }
        if (startsWithAny(upper,
                "58:69:6C", "00:74:9C", "30:0D:9E", "C4:70:AB", "80:05:88", "EC:B9:70", "00:1A:A9")) {
            return "Ruijie AP";
        }
        if (startsWithAny(upper,
                "50:C7:BF", "60:32:B1", "74:DA:88", "98:DA:C4", "B0:95:75", "C0:06:C3",
                "E8:48:B8", "14:EB:B6", "1C:3B:F3", "30:DE:4B", "40:ED:00", "54:AF:97",
                "5C:A6:E6", "AC:84:C6", "D8:07:B6")) {
            return "TP-Link/Omada AP";
        }
        if (startsWithAny(upper,
                "10:08:1D", "00:0B:86", "24:DE:C6", "9C:1C:12", "D8:C7:C8", "20:4C:03",
                "40:E3:D6", "6C:F3:7F", "84:D4:7E", "94:B4:0F", "B4:5D:50")) {
            return "Aruba AP";
        }
        if (startsWithAny(upper,
                "00:1A:1E", "F4:CF:E2", "00:18:0A", "88:15:44", "E0:55:3D", "E0:CB:BC",
                "0C:8D:DB", "34:56:FE", "68:3A:1E", "AC:17:C8")) {
            return "Cisco AP";
        }
        if (startsWithAny(upper,
                "00:E0:FC", "48:8E:EF", "60:DE:44", "70:7B:E8", "88:28:B3", "CC:B1:82", "D4:94:E8")) {
            return "Huawei AP";
        }
        if (startsWithAny(upper, "F8:DF:A8", "D0:76:E7", "C8:7B:5B", "10:93:97", "74:A7:8E")) {
            return "ZTE AP";
        }
        return "AP";
    }

    public static String formatBandAndChannel(int freqMhz) {
        if (freqMhz <= 0) return "Unknown";
        String band;
        int chan;
        if (freqMhz >= 2412 && freqMhz <= 2484) {
            band = "2.4GHz";
            chan = freqMhz == 2484 ? 14 : ((freqMhz - 2412) / 5) + 1;
        } else if (freqMhz >= 5180 && freqMhz <= 5885) {
            band = "5GHz";
            chan = (freqMhz - 5000) / 5;
        } else if (freqMhz >= 5955) {
            band = "6GHz";
            chan = (freqMhz - 5950) / 5;
        } else {
            return freqMhz + " MHz";
        }
        return String.format(Locale.US, "%s Ch %d (%d MHz)", band, chan, freqMhz);
    }

    public synchronized void recordWifiSample(Context ctx, String ssidRaw, String bssidRaw, int freqMhz, String ip) {
        String bandChan = formatBandAndChannel(freqMhz);
        if (ip != null && !ip.isEmpty() && !"0.0.0.0".equals(ip)) {
            currentIp = ip;
        }

        if (isValidSsid(ssidRaw)) {
            currentSsid = ssidRaw.replace("\"", "").trim();
        }

        if (isValidBssid(bssidRaw)) {
            String cleanBssid = bssidRaw.trim().toUpperCase(Locale.US);
            if (!currentBssid.isEmpty() && !cleanBssid.equals(currentBssid)) {
                long now = System.currentTimeMillis();
                roamTimestampsMs.add(now);
                totalRoamCount++;
                String ts = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date(now));
                lastTransition = String.format(Locale.US, "%s (%s) -> %s (%s) [%s]",
                        currentBssid, currentBandChan, cleanBssid, bandChan, ts);
            }
            currentBssid = cleanBssid;
            currentBandChan = bandChan;
        }

        if (ctx != null && (!currentSsid.isEmpty() || !currentBssid.isEmpty())) {
            try {
                SharedPreferences sp = ctx.getApplicationContext().getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
                SharedPreferences.Editor ed = sp.edit();
                if (!currentSsid.isEmpty()) ed.putString(KEY_LAST_SSID, currentSsid);
                if (!currentBssid.isEmpty()) ed.putString(KEY_LAST_BSSID, currentBssid);
                if (!currentIp.isEmpty()) ed.putString(KEY_LAST_IP, currentIp);
                ed.apply();
            } catch (Throwable ignored) {}
        }
        pruneOldRoams();
    }

    public synchronized String getCachedSsid(Context ctx, String activeIp) {
        if (isValidSsid(currentSsid)) return currentSsid;
        if (ctx != null && activeIp != null && !activeIp.isEmpty() && !"0.0.0.0".equals(activeIp)) {
            try {
                SharedPreferences sp = ctx.getApplicationContext().getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
                if (activeIp.equals(sp.getString(KEY_LAST_IP, ""))) {
                    String s = sp.getString(KEY_LAST_SSID, "");
                    if (isValidSsid(s)) {
                        currentSsid = s;
                        return s;
                    }
                }
            } catch (Throwable ignored) {}
        }
        return "";
    }

    public synchronized String getCachedBssid(Context ctx, String activeIp) {
        if (isValidBssid(currentBssid)) return currentBssid;
        if (ctx != null && activeIp != null && !activeIp.isEmpty() && !"0.0.0.0".equals(activeIp)) {
            try {
                SharedPreferences sp = ctx.getApplicationContext().getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
                if (activeIp.equals(sp.getString(KEY_LAST_IP, ""))) {
                    String b = sp.getString(KEY_LAST_BSSID, "");
                    if (isValidBssid(b)) {
                        currentBssid = b;
                        return b;
                    }
                }
            } catch (Throwable ignored) {}
        }
        return "";
    }

    private void pruneOldRoams() {
        long cutoff = System.currentTimeMillis() - 3600_000L;
        roamTimestampsMs.removeIf(t -> t < cutoff);
    }

    public synchronized int getRoamCountLastHour() {
        pruneOldRoams();
        return roamTimestampsMs.size();
    }

    public synchronized int getTotalRoamCount() {
        return totalRoamCount;
    }

    public synchronized String getLastTransition() {
        return lastTransition.isEmpty() ? "Stabil (0 roam)" : lastTransition;
    }
}
