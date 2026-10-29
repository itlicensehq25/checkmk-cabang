package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedList;
import java.util.List;
import java.util.Locale;

/**
 * Tracks Wi-Fi Access Point (BSSID & Channel/Band) roaming across UniFi and multi-AP networks.
 * Persists roaming history on the device and exposes 1h/total roam counts for Checkmk.
 */
public final class WifiRoamingTracker {
    private static final String PREFS = "cmkagent_wifi_roaming_v1";
    private static final String LOG_FILE_NAME = "wifi_roaming.log";
    private static final long ONE_HOUR_MS = 3600_000L;
    private static final long MAX_LOG_BYTES = 2L * 1024L * 1024L;

    private static final String K_CURRENT_BSSID = "current_bssid";
    private static final String K_CURRENT_CHANNEL = "current_channel";
    private static final String K_CURRENT_FREQ = "current_freq";
    private static final String K_PREV_BSSID = "prev_bssid";
    private static final String K_PREV_CHANNEL = "prev_channel";
    private static final String K_LAST_ROAM_MS = "last_roam_ms";
    private static final String K_LAST_ROAM_REASON = "last_roam_reason";
    private static final String K_TOTAL_ROAMS = "total_roams";
    private static final String K_ROAM_TIMESTAMPS = "roam_timestamps_csv";

    // Ubiquiti / UniFi base OUI prefixes (uppercase XX:XX:XX)
    private static final String[] UNIFI_OUIS = {
            "00:15:6D", "00:27:22", "04:18:D6", "18:E8:29", "24:5A:4C", "24:A4:3C",
            "44:D9:E7", "60:22:32", "68:D7:9A", "70:A7:41", "74:83:C2", "74:AC:B9",
            "78:45:58", "78:8A:20", "80:2A:A8", "84:78:48", "94:2A:6F", "9C:05:D6",
            "AC:8B:A9", "B4:FB:E4", "D0:21:F9", "D8:B3:70", "E0:63:DA", "E4:38:83",
            "F0:9F:C2", "F4:92:BF", "FC:EC:DA"
    };

    private WifiRoamingTracker() {}

    public static final class RoamingInfo {
        public String currentBssid = "N/A";
        public String apVendor = "Unknown AP";
        public String bandChannel = "N/A";
        public String previousBssid = "-";
        public String previousChannel = "-";
        public long lastRoamMs = 0L;
        public String lastRoamReason = "-";
        public int roamsLastHour = 0;
        public int totalRoams = 0;
        public String summaryText = "Stable (0 roams)";
    }

    public static synchronized RoamingInfo updateAndRead(
            Context context, boolean connected, String ssid, String rawBssid,
            int frequencyMhz, int rssi, String ip) {
        RoamingInfo out = new RoamingInfo();
        if (context == null) return out;

        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long nowMs = System.currentTimeMillis();

        String cleanBssid = normalizeBssid(rawBssid);
        String bandCh = frequencyToBandChannel(frequencyMhz);
        String vendor = detectApVendor(cleanBssid);

        out.currentBssid = cleanBssid != null ? cleanBssid : "Restricted (Enable Location)";
        out.apVendor = vendor;
        out.bandChannel = bandCh;

        String prevStoredBssid = p.getString(K_CURRENT_BSSID, "");
        String prevStoredCh = p.getString(K_CURRENT_CHANNEL, "");
        int prevStoredFreq = p.getInt(K_CURRENT_FREQ, -1);

        List<Long> recentRoams = pruneOldTimestamps(parseTimestamps(p.getString(K_ROAM_TIMESTAMPS, "")), nowMs);
        int totalRoams = p.getInt(K_TOTAL_ROAMS, 0);
        long lastRoamMs = p.getLong(K_LAST_ROAM_MS, 0L);
        String prevApBssid = p.getString(K_PREV_BSSID, "-");
        String prevApCh = p.getString(K_PREV_CHANNEL, "-");
        String lastReason = p.getString(K_LAST_ROAM_REASON, "-");

        if (connected) {
            boolean roamedByBssid = cleanBssid != null
                    && !prevStoredBssid.isEmpty()
                    && !cleanBssid.equalsIgnoreCase(prevStoredBssid);

            // Fallback when Android Location is OFF (BSSID redacted as 02:00:00:00:00:00):
            // still catch AP/radio roaming whenever the Wi-Fi frequency/channel changes!
            boolean roamedByChannel = (cleanBssid == null)
                    && frequencyMhz > 0
                    && prevStoredFreq > 0
                    && frequencyMhz != prevStoredFreq;

            if (roamedByBssid || roamedByChannel) {
                totalRoams++;
                lastRoamMs = nowMs;
                recentRoams.add(nowMs);
                prevApBssid = !prevStoredBssid.isEmpty() ? prevStoredBssid : "AP(" + prevStoredCh + ")";
                prevApCh = !prevStoredCh.isEmpty() ? prevStoredCh : "N/A";
                String newApDesc = cleanBssid != null ? (cleanBssid + " [" + vendor + "]") : ("AP(" + bandCh + ")");
                lastReason = prevApBssid + " (" + prevApCh + ") -> " + newApDesc + " (" + bandCh + ")";

                appendRoamLog(context, nowMs, ssid, prevApBssid, prevApCh,
                        cleanBssid != null ? cleanBssid : "Hidden-BSSID", vendor, bandCh, rssi, ip);
            }

            SharedPreferences.Editor ed = p.edit();
            if (cleanBssid != null) {
                ed.putString(K_CURRENT_BSSID, cleanBssid);
            }
            if (frequencyMhz > 0) {
                ed.putString(K_CURRENT_CHANNEL, bandCh);
                ed.putInt(K_CURRENT_FREQ, frequencyMhz);
            }
            ed.putString(K_PREV_BSSID, prevApBssid);
            ed.putString(K_PREV_CHANNEL, prevApCh);
            ed.putLong(K_LAST_ROAM_MS, lastRoamMs);
            ed.putString(K_LAST_ROAM_REASON, lastReason);
            ed.putInt(K_TOTAL_ROAMS, totalRoams);
            ed.putString(K_ROAM_TIMESTAMPS, serializeTimestamps(recentRoams));
            ed.apply();
        }

        out.previousBssid = prevApBssid;
        out.previousChannel = prevApCh;
        out.lastRoamMs = lastRoamMs;
        out.lastRoamReason = lastReason;
        out.roamsLastHour = recentRoams.size();
        out.totalRoams = totalRoams;

        if (lastRoamMs > 0L) {
            String ago = CheckmkOutput.formatDuration(Math.max(0L, nowMs - lastRoamMs)) + " ago";
            out.summaryText = out.roamsLastHour + "x/1h (Total " + out.totalRoams
                    + "x, Last " + ago + " from " + out.previousBssid + " " + out.previousChannel + ")";
        } else {
            out.summaryText = "Stable on AP (0x/1h, Total " + out.totalRoams + "x)";
        }

        return out;
    }

    public static String normalizeBssid(String raw) {
        if (raw == null) return null;
        String clean = raw.trim().toUpperCase(Locale.US);
        if (clean.isEmpty()
                || "02:00:00:00:00:00".equals(clean)
                || "00:00:00:00:00:00".equals(clean)
                || "<NONE>".equals(clean)
                || "NONE".equals(clean)) {
            return null;
        }
        if (clean.matches("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")) {
            return clean;
        }
        return null;
    }

    public static String detectApVendor(String bssid) {
        if (bssid == null || bssid.length() < 8) return "AP";
        String prefix = bssid.substring(0, 8).toUpperCase(Locale.US);
        for (String u : UNIFI_OUIS) {
            if (u.equals(prefix)) return "UniFi AP";
        }
        // Check locally-administered virtual BSSID used by UniFi multi-SSID radios
        try {
            int firstOctet = Integer.parseInt(bssid.substring(0, 2), 16);
            if ((firstOctet & 0x02) != 0) {
                String baseFirst = String.format(Locale.US, "%02X", firstOctet & 0xFC);
                String basePrefix = baseFirst + bssid.substring(2, 8).toUpperCase(Locale.US);
                for (String u : UNIFI_OUIS) {
                    if (u.equals(basePrefix)) return "UniFi AP";
                }
            }
        } catch (Throwable ignored) {}

        if (prefix.startsWith("D8:C7:C8") || prefix.startsWith("24:DE:C6") || prefix.startsWith("94:B4:0F")) {
            return "Aruba AP";
        }
        if (prefix.startsWith("00:1B:D5") || prefix.startsWith("C0:62:6B") || prefix.startsWith("F8:72:EA")) {
            return "Cisco AP";
        }
        if (prefix.startsWith("4C:5E:0C") || prefix.startsWith("64:D1:54") || prefix.startsWith("CC:2D:E0")
                || prefix.startsWith("DC:2C:6E") || prefix.startsWith("E4:8D:8C")) {
            return "MikroTik AP";
        }
        return "AP";
    }

    public static String frequencyToBandChannel(int freqMhz) {
        if (freqMhz <= 0) return "N/A";
        if (freqMhz == 2484) return "2.4GHz Ch 14";
        if (freqMhz >= 2412 && freqMhz <= 2472) {
            int ch = (freqMhz - 2407) / 5;
            return "2.4GHz Ch " + ch;
        }
        if (freqMhz >= 5170 && freqMhz <= 5835) {
            int ch = (freqMhz - 5000) / 5;
            return "5GHz Ch " + ch;
        }
        if (freqMhz >= 5955 && freqMhz <= 7115) {
            int ch = (freqMhz - 5950) / 5;
            return "6GHz Ch " + ch;
        }
        return freqMhz + " MHz";
    }

    public static String readRecentRoamLog(Context context, int maxLines) {
        File file = getLogFile(context);
        if (!file.exists()) return "Belum ada riwayat perpindahan (roaming) AP yang tercatat.";
        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            LinkedList<String> lines = new LinkedList<>();
            String line;
            while ((line = reader.readLine()) != null) {
                lines.addLast(line);
                if (lines.size() > maxLines) lines.removeFirst();
            }
            StringBuilder sb = new StringBuilder();
            sb.append("File Log: ").append(file.getAbsolutePath()).append("\n\n");
            for (String l : lines) sb.append(l).append('\n');
            return sb.toString();
        } catch (Exception e) {
            return "Gagal membaca log roaming: " + e.getMessage();
        }
    }

    private static void appendRoamLog(
            Context context, long tsMs, String ssid, String fromBssid, String fromCh,
            String toBssid, String vendor, String toCh, int rssi, String ip) {
        String ts = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date(tsMs));
        String line = String.format(Locale.US,
                "[%s] ROAM | SSID: %s | %s (%s) -> %s [%s] (%s) | RSSI: %s dBm | IP: %s\n",
                ts, ssid, fromBssid, fromCh, toBssid, vendor, toCh,
                rssi != Integer.MIN_VALUE ? String.valueOf(rssi) : "N/A", ip);
        try {
            File file = getLogFile(context);
            File parent = file.getParentFile();
            if (parent != null && !parent.exists()) parent.mkdirs();
            if (file.exists() && file.length() > MAX_LOG_BYTES) {
                File old = new File(file.getParentFile(), "wifi_roaming.old.log");
                if (old.exists()) old.delete();
                file.renameTo(old);
            }
            try (FileOutputStream fos = new FileOutputStream(file, true)) {
                fos.write(line.getBytes(StandardCharsets.UTF_8));
                fos.flush();
            }
        } catch (Throwable ignored) {}
    }

    public static File getLogFile(Context context) {
        try {
            File extDir = context.getExternalFilesDir(null);
            if (extDir != null) {
                if (!extDir.exists()) extDir.mkdirs();
                return new File(extDir, LOG_FILE_NAME);
            }
        } catch (Throwable ignored) {}
        return new File(context.getFilesDir(), LOG_FILE_NAME);
    }

    private static List<Long> parseTimestamps(String csv) {
        List<Long> list = new ArrayList<>();
        if (csv == null || csv.trim().isEmpty()) return list;
        for (String part : csv.split(",")) {
            try {
                long v = Long.parseLong(part.trim());
                if (v > 0) list.add(v);
            } catch (Throwable ignored) {}
        }
        return list;
    }

    private static List<Long> pruneOldTimestamps(List<Long> input, long nowMs) {
        List<Long> out = new ArrayList<>();
        for (long ts : input) {
            if (nowMs - ts <= ONE_HOUR_MS && ts <= nowMs) {
                out.add(ts);
            }
        }
        return out;
    }

    private static String serializeTimestamps(List<Long> list) {
        StringBuilder sb = new StringBuilder();
        for (long ts : list) {
            if (sb.length() > 0) sb.append(',');
            sb.append(ts);
        }
        return sb.toString();
    }
}
