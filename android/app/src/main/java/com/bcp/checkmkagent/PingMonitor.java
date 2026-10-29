package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Executes 4x ICMP ping every 1 minute to 3 targets:
 * 1) 192.168.122.10 (Local / Core Server)
 * 2) 8.8.8.8 (Internet / Google DNS)
 * 3) IP Gateway Kantor Cabang (dikonfigurasi manual saat setting PDA)
 *
 * Stores minute-by-minute logs on the device with a 30-day rolling retention
 * (CCTV-style: automatically deletes logs from day 31 onwards), and publishes
 * the aggregated summary to Checkmk every 1 hour (3600 seconds) in 3 separate lines.
 */
public final class PingMonitor {
    public static final String TARGET_LOCAL = "192.168.122.10";
    public static final String TARGET_INTERNET = "8.8.8.8";
    public static final String TARGET_GATEWAY_KEY = "gateway";

    public static final String SERVICE_LOCAL = "Ping_192.168.122.10";
    public static final String SERVICE_INTERNET = "Ping_8.8.8.8";
    public static final String SERVICE_GATEWAY = "Ping_Gateway";

    public static final int PINGS_PER_MINUTE = 4;
    public static final long REPORT_INTERVAL_SEC = 3600L; // 1 Jam (3600 detik)
    public static final int LOG_RETENTION_DAYS = 30;      // Retensi 30 hari (CCTV style)

    private static final long REPORT_INTERVAL_MS = REPORT_INTERVAL_SEC * 1000L;
    private static final long LOG_RETENTION_MS = LOG_RETENTION_DAYS * 24L * 60L * 60L * 1000L;
    private static final long PRUNE_INTERVAL_MS = 3600L * 1000L; // Cek pembersihan tiap 1 jam
    private static final int SAMPLES_PER_HOUR = 60;
    private static final long EMERGENCY_MAX_LOG_BYTES = 35L * 1024L * 1024L; // Batas darurat 35 MB

    private static final String PREFS = "cmkagent_ping_hourly_v1";
    private static final String LOG_FILE_NAME = "ping_history.log";
    private static final String LOG_TMP_FILE_NAME = "ping_history.tmp";
    private static final String LOG_OLD_FILE_NAME = "ping_history.old.log";

    private static final Pattern LOSS_PATTERN = Pattern.compile("(\\d+)\\s+packets transmitted,\\s+(\\d+)\\s+received");
    private static final Pattern RTT_SUMMARY_PATTERN = Pattern.compile("=\\s*([0-9.]+)/([0-9.]+)/([0-9.]+)");
    private static final Pattern TIME_LINE_PATTERN = Pattern.compile("time=([0-9.]+)\\s*ms");

    private PingMonitor() {}

    public static final class PingSample {
        public final String target;
        public final long timestampMs;
        public final int tx;
        public final int rx;
        public final double lossPercent;
        public final double minMs;
        public final double avgMs;
        public final double maxMs;

        PingSample(String target, long timestampMs, int tx, int rx,
                   double lossPercent, double minMs, double avgMs, double maxMs) {
            this.target = target;
            this.timestampMs = timestampMs;
            this.tx = tx;
            this.rx = rx;
            this.lossPercent = lossPercent;
            this.minMs = minMs;
            this.avgMs = avgMs;
            this.maxMs = maxMs;
        }
    }

    public static final class TargetStatus {
        public String target;
        public int windowSamples;
        public int windowTx;
        public int windowRx;
        public double windowLossPercent;
        public double windowAvgMs;
        public double windowMinMs;
        public double windowMaxMs;
        public int windowFailedMinutes;
        public long windowStartMs;
        public long lastSampleMs;
        public double lastAvgMs;
        public double lastLossPercent;
        public long lastPublishedSec;
        public String publishedCheckmkLine;
        public String logFilePath;
    }

    /**
     * Called every 1 minute by CheckmkAgentService.
     * Runs 4x ping to 192.168.122.10, 8.8.8.8, and branch gateway (if configured),
     * saves to local phone log (30-day retention), and rotates 1-hour Checkmk snapshots.
     */
    public static synchronized void collectMinuteSample(Context context) {
        if (context == null) return;
        long nowMs = System.currentTimeMillis();

        PingSample localSample = executePing(TARGET_LOCAL, PINGS_PER_MINUTE, nowMs);
        PingSample internetSample = executePing(TARGET_INTERNET, PINGS_PER_MINUTE, nowMs);

        String gatewayIp = AgentConfig.getGatewayIp(context);
        PingSample gatewaySample = null;
        if (AgentConfig.isValidIpv4(gatewayIp)) {
            checkGatewayIpChange(context, gatewayIp, nowMs);
            gatewaySample = executePing(gatewayIp, PINGS_PER_MINUTE, nowMs);
        }

        appendMinuteLog(context, localSample, internetSample, gatewaySample);

        updateTargetAccumulator(context, TARGET_LOCAL, SERVICE_LOCAL, TARGET_LOCAL, localSample, 100.0, 250.0);
        updateTargetAccumulator(context, TARGET_INTERNET, SERVICE_INTERNET, TARGET_INTERNET, internetSample, 150.0, 300.0);

        if (gatewaySample != null) {
            updateTargetAccumulator(context, TARGET_GATEWAY_KEY, SERVICE_GATEWAY,
                    gatewayIp + " (Gateway Cabang)", gatewaySample, 50.0, 150.0);
        }

        pruneLogsIfDue(context, nowMs);
    }

    private static void checkGatewayIpChange(Context context, String currentGwIp, long nowMs) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String lastTracked = p.getString("gateway_ip_tracked", "");
        if (!currentGwIp.equals(lastTracked)) {
            p.edit()
                    .putString("gateway_ip_tracked", currentGwIp)
                    .putLong(key(TARGET_GATEWAY_KEY, "win_start_ms"), nowMs)
                    .putInt(key(TARGET_GATEWAY_KEY, "win_samples"), 0)
                    .putInt(key(TARGET_GATEWAY_KEY, "win_tx"), 0)
                    .putInt(key(TARGET_GATEWAY_KEY, "win_rx"), 0)
                    .putInt(key(TARGET_GATEWAY_KEY, "win_fail_min"), 0)
                    .putInt(key(TARGET_GATEWAY_KEY, "win_rtt_count"), 0)
                    .putFloat(key(TARGET_GATEWAY_KEY, "win_rtt_sum"), 0f)
                    .putFloat(key(TARGET_GATEWAY_KEY, "win_rtt_min"), -1f)
                    .putFloat(key(TARGET_GATEWAY_KEY, "win_rtt_max"), -1f)
                    .remove(key(TARGET_GATEWAY_KEY, "pub_line"))
                    .remove(key(TARGET_GATEWAY_KEY, "pub_sec"))
                    .apply();
        }
    }

    /**
     * Ensures at least one baseline sample exists if Checkmk pulls immediately after install.
     */
    public static synchronized void ensureInitialized(Context context) {
        if (context == null) return;
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long lastSample = p.getLong(key(TARGET_LOCAL, "last_sample_ms"), 0L);
        if (lastSample <= 0L) {
            collectMinuteSample(context);
        } else {
            pruneLogsIfDue(context, System.currentTimeMillis());
        }
    }

    /**
     * Generates 3 separate cached Checkmk service sections:
     * 1) Ping_192.168.122.10
     * 2) Ping_8.8.8.8
     * 3) Ping_Gateway
     */
    public static String getCheckmkSection(Context context) {
        ensureInitialized(context);
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long nowSec = System.currentTimeMillis() / 1000L;

        long pubLocalSec = p.getLong(key(TARGET_LOCAL, "pub_sec"), 0L);
        long pubNetSec = p.getLong(key(TARGET_INTERNET, "pub_sec"), 0L);
        long pubGwSec = p.getLong(key(TARGET_GATEWAY_KEY, "pub_sec"), 0L);

        String lineLocal = p.getString(key(TARGET_LOCAL, "pub_line"), null);
        String lineNet = p.getString(key(TARGET_INTERNET, "pub_line"), null);
        String lineGw = p.getString(key(TARGET_GATEWAY_KEY, "pub_line"), null);

        if (lineLocal == null || lineLocal.isEmpty()) {
            lineLocal = buildCurrentBufferLine(p, TARGET_LOCAL, TARGET_LOCAL, SERVICE_LOCAL, 100.0, 250.0);
            pubLocalSec = p.getLong(key(TARGET_LOCAL, "win_start_ms"), System.currentTimeMillis()) / 1000L;
        }
        if (lineNet == null || lineNet.isEmpty()) {
            lineNet = buildCurrentBufferLine(p, TARGET_INTERNET, TARGET_INTERNET, SERVICE_INTERNET, 150.0, 300.0);
            pubNetSec = p.getLong(key(TARGET_INTERNET, "win_start_ms"), System.currentTimeMillis()) / 1000L;
        }

        String gatewayIp = AgentConfig.getGatewayIp(context);
        if (!AgentConfig.isValidIpv4(gatewayIp)) {
            pubGwSec = nowSec;
            lineGw = "1 \"" + SERVICE_GATEWAY + "\" - Status : WARNING | Target : Belum Diisi | Remark : Wajib isi IP Gateway Cabang di Settings PDA";
        } else if (lineGw == null || lineGw.isEmpty()) {
            lineGw = buildCurrentBufferLine(p, TARGET_GATEWAY_KEY, gatewayIp + " (Gateway Cabang)", SERVICE_GATEWAY, 50.0, 150.0);
            pubGwSec = p.getLong(key(TARGET_GATEWAY_KEY, "win_start_ms"), System.currentTimeMillis()) / 1000L;
        }

        if (pubLocalSec <= 0L || pubLocalSec > nowSec) pubLocalSec = nowSec;
        if (pubNetSec <= 0L || pubNetSec > nowSec) pubNetSec = nowSec;
        if (pubGwSec <= 0L || pubGwSec > nowSec) pubGwSec = nowSec;

        StringBuilder sb = new StringBuilder();
        sb.append("<<<local:cached(").append(pubLocalSec).append(",")
          .append(REPORT_INTERVAL_SEC).append("):sep(0)>>>\n");
        sb.append(lineLocal).append('\n');

        sb.append("<<<local:cached(").append(pubNetSec).append(",")
          .append(REPORT_INTERVAL_SEC).append("):sep(0)>>>\n");
        sb.append(lineNet).append('\n');

        sb.append("<<<local:cached(").append(pubGwSec).append(",")
          .append(REPORT_INTERVAL_SEC).append("):sep(0)>>>\n");
        sb.append(lineGw);

        return sb.toString();
    }

    public static TargetStatus readStatus(Context context, String targetKey) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        TargetStatus s = new TargetStatus();
        if (TARGET_GATEWAY_KEY.equals(targetKey)) {
            String gw = AgentConfig.getGatewayIp(context);
            s.target = gw.isEmpty() ? "Gateway Cabang" : gw;
        } else {
            s.target = targetKey;
        }
        s.windowSamples = p.getInt(key(targetKey, "win_samples"), 0);
        s.windowTx = p.getInt(key(targetKey, "win_tx"), 0);
        s.windowRx = p.getInt(key(targetKey, "win_rx"), 0);
        s.windowLossPercent = s.windowTx > 0
                ? ((s.windowTx - s.windowRx) * 100.0 / s.windowTx) : 0.0;
        int rttCount = p.getInt(key(targetKey, "win_rtt_count"), 0);
        double rttSum = p.getFloat(key(targetKey, "win_rtt_sum"), 0f);
        s.windowAvgMs = rttCount > 0 ? (rttSum / rttCount) : Double.NaN;
        float minVal = p.getFloat(key(targetKey, "win_rtt_min"), -1f);
        float maxVal = p.getFloat(key(targetKey, "win_rtt_max"), -1f);
        s.windowMinMs = minVal >= 0 ? minVal : Double.NaN;
        s.windowMaxMs = maxVal >= 0 ? maxVal : Double.NaN;
        s.windowFailedMinutes = p.getInt(key(targetKey, "win_fail_min"), 0);
        s.windowStartMs = p.getLong(key(targetKey, "win_start_ms"), 0L);
        s.lastSampleMs = p.getLong(key(targetKey, "last_sample_ms"), 0L);
        float lastAvg = p.getFloat(key(targetKey, "last_avg_ms"), -1f);
        s.lastAvgMs = lastAvg >= 0 ? lastAvg : Double.NaN;
        s.lastLossPercent = p.getFloat(key(targetKey, "last_loss"), 0f);
        s.lastPublishedSec = p.getLong(key(targetKey, "pub_sec"), 0L);
        s.publishedCheckmkLine = p.getString(key(targetKey, "pub_line"), "-");
        s.logFilePath = getPrimaryLogFile(context).getAbsolutePath();
        return s;
    }

    public static String readRecentLogTail(Context context, int maxLines) {
        pruneLogsOlderThan30Days(context, System.currentTimeMillis());
        File file = getPrimaryLogFile(context);
        if (!file.exists()) {
            File internal = new File(context.getFilesDir(), LOG_FILE_NAME);
            if (internal.exists()) file = internal;
        }
        if (!file.exists()) return "Belum ada log ping tersimpan.";

        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            java.util.LinkedList<String> lines = new java.util.LinkedList<>();
            String firstTimestamp = null;
            String lastTimestamp = null;
            int totalLines = 0;
            String line;
            while ((line = reader.readLine()) != null) {
                totalLines++;
                String ts = extractLineTimestamp(line);
                if (ts != null) {
                    if (firstTimestamp == null) firstTimestamp = ts;
                    lastTimestamp = ts;
                }
                lines.addLast(line);
                if (lines.size() > maxLines) {
                    lines.removeFirst();
                }
            }
            StringBuilder sb = new StringBuilder();
            sb.append("File Log : ").append(file.getAbsolutePath()).append("\n");
            sb.append("Retensi  : ").append(LOG_RETENTION_DAYS).append(" Hari (Auto-hapus hari ke-31+ seperti CCTV)\n");
            sb.append("Ukuran   : ").append(file.length() / 1024).append(" KB (").append(totalLines).append(" baris)\n");
            if (firstTimestamp != null && lastTimestamp != null) {
                sb.append("Rentang  : ").append(firstTimestamp).append(" s/d ").append(lastTimestamp).append("\n");
            }
            sb.append("\n");
            for (String l : lines) {
                sb.append(l).append('\n');
            }
            return sb.toString();
        } catch (Exception e) {
            return "Gagal membaca log ping: " + e.getMessage();
        }
    }

    private static void updateTargetAccumulator(
            Context context, String targetKey, String serviceName, String targetDisplay,
            PingSample sample, double warnRttMs, double critRttMs) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long winStartMs = p.getLong(key(targetKey, "win_start_ms"), 0L);
        if (winStartMs <= 0L || sample.timestampMs < winStartMs) {
            winStartMs = sample.timestampMs;
        }

        int winSamples = p.getInt(key(targetKey, "win_samples"), 0) + 1;
        int winTx = p.getInt(key(targetKey, "win_tx"), 0) + sample.tx;
        int winRx = p.getInt(key(targetKey, "win_rx"), 0) + sample.rx;
        int winFailMin = p.getInt(key(targetKey, "win_fail_min"), 0) + (sample.rx == 0 ? 1 : 0);

        int rttCount = p.getInt(key(targetKey, "win_rtt_count"), 0);
        float rttSum = p.getFloat(key(targetKey, "win_rtt_sum"), 0f);
        float rttMin = p.getFloat(key(targetKey, "win_rtt_min"), -1f);
        float rttMax = p.getFloat(key(targetKey, "win_rtt_max"), -1f);

        if (!Double.isNaN(sample.avgMs)) {
            rttCount++;
            rttSum += (float) sample.avgMs;
        }
        if (!Double.isNaN(sample.minMs)) {
            if (rttMin < 0f || sample.minMs < rttMin) rttMin = (float) sample.minMs;
        }
        if (!Double.isNaN(sample.maxMs)) {
            if (rttMax < 0f || sample.maxMs > rttMax) rttMax = (float) sample.maxMs;
        }

        SharedPreferences.Editor ed = p.edit();
        ed.putLong(key(targetKey, "last_sample_ms"), sample.timestampMs);
        ed.putFloat(key(targetKey, "last_avg_ms"), Double.isNaN(sample.avgMs) ? -1f : (float) sample.avgMs);
        ed.putFloat(key(targetKey, "last_loss"), (float) sample.lossPercent);

        long elapsedMs = sample.timestampMs - winStartMs;
        boolean hourCompleted = (elapsedMs >= REPORT_INTERVAL_MS) || (winSamples >= SAMPLES_PER_HOUR);

        if (hourCompleted) {
            double lossPct = winTx > 0 ? ((winTx - winRx) * 100.0 / winTx) : 100.0;
            double avgMs = rttCount > 0 ? (rttSum / (double) rttCount) : Double.NaN;
            double minMs = rttMin >= 0f ? rttMin : Double.NaN;
            double maxMs = rttMax >= 0f ? rttMax : Double.NaN;

            String hourlyLine = formatCheckmkPingLine(
                    serviceName, targetDisplay, winSamples, winTx, winRx, lossPct,
                    avgMs, minMs, maxMs, winFailMin, winStartMs, sample.timestampMs,
                    sample.avgMs, warnRttMs, critRttMs, true);

            long pubSec = sample.timestampMs / 1000L;
            ed.putString(key(targetKey, "pub_line"), hourlyLine);
            ed.putLong(key(targetKey, "pub_sec"), pubSec);

            appendHourlySummaryLog(context, targetDisplay, winSamples, winTx, winRx, lossPct, avgMs, minMs, maxMs, winStartMs, sample.timestampMs);

            // Reset 1-hour window for the next hour
            ed.putLong(key(targetKey, "win_start_ms"), sample.timestampMs);
            ed.putInt(key(targetKey, "win_samples"), 0);
            ed.putInt(key(targetKey, "win_tx"), 0);
            ed.putInt(key(targetKey, "win_rx"), 0);
            ed.putInt(key(targetKey, "win_fail_min"), 0);
            ed.putInt(key(targetKey, "win_rtt_count"), 0);
            ed.putFloat(key(targetKey, "win_rtt_sum"), 0f);
            ed.putFloat(key(targetKey, "win_rtt_min"), -1f);
            ed.putFloat(key(targetKey, "win_rtt_max"), -1f);
        } else {
            ed.putLong(key(targetKey, "win_start_ms"), winStartMs);
            ed.putInt(key(targetKey, "win_samples"), winSamples);
            ed.putInt(key(targetKey, "win_tx"), winTx);
            ed.putInt(key(targetKey, "win_rx"), winRx);
            ed.putInt(key(targetKey, "win_fail_min"), winFailMin);
            ed.putInt(key(targetKey, "win_rtt_count"), rttCount);
            ed.putFloat(key(targetKey, "win_rtt_sum"), rttSum);
            ed.putFloat(key(targetKey, "win_rtt_min"), rttMin);
            ed.putFloat(key(targetKey, "win_rtt_max"), rttMax);
        }

        ed.apply();
    }

    private static String buildCurrentBufferLine(
            SharedPreferences p, String targetKey, String targetDisplay, String serviceName,
            double warnRttMs, double critRttMs) {
        int winSamples = p.getInt(key(targetKey, "win_samples"), 0);
        int winTx = p.getInt(key(targetKey, "win_tx"), 0);
        int winRx = p.getInt(key(targetKey, "win_rx"), 0);
        int winFailMin = p.getInt(key(targetKey, "win_fail_min"), 0);
        int rttCount = p.getInt(key(targetKey, "win_rtt_count"), 0);
        float rttSum = p.getFloat(key(targetKey, "win_rtt_sum"), 0f);
        float rttMin = p.getFloat(key(targetKey, "win_rtt_min"), -1f);
        float rttMax = p.getFloat(key(targetKey, "win_rtt_max"), -1f);
        long winStartMs = p.getLong(key(targetKey, "win_start_ms"), System.currentTimeMillis());
        long lastSampleMs = p.getLong(key(targetKey, "last_sample_ms"), System.currentTimeMillis());
        float lastAvg = p.getFloat(key(targetKey, "last_avg_ms"), -1f);

        double lossPct = winTx > 0 ? ((winTx - winRx) * 100.0 / winTx) : 0.0;
        double avgMs = rttCount > 0 ? (rttSum / (double) rttCount) : Double.NaN;
        double minMs = rttMin >= 0f ? rttMin : Double.NaN;
        double maxMs = rttMax >= 0f ? rttMax : Double.NaN;
        double lastMs = lastAvg >= 0f ? lastAvg : Double.NaN;

        return formatCheckmkPingLine(
                serviceName, targetDisplay, winSamples, winTx, winRx, lossPct,
                avgMs, minMs, maxMs, winFailMin, winStartMs, lastSampleMs,
                lastMs, warnRttMs, critRttMs, false);
    }

    private static String formatCheckmkPingLine(
            String serviceName, String targetDisplay, int samples, int tx, int rx, double lossPct,
            double avgMs, double minMs, double maxMs, int failMinutes,
            long startMs, long endMs, double lastMs,
            double warnRttMs, double critRttMs, boolean completedHour) {

        int state = 0;
        if (tx > 0 && (lossPct >= 50.0 || (!Double.isNaN(avgMs) && avgMs >= critRttMs))) {
            state = 2;
        } else if (tx > 0 && (lossPct >= 20.0 || (!Double.isNaN(avgMs) && avgMs >= warnRttMs))) {
            state = 1;
        }

        String rtaMetric = !Double.isNaN(avgMs)
                ? String.format(Locale.US, "rta=%.2fms;%.0f;%.0f;0", avgMs, warnRttMs, critRttMs)
                : "rta=0.00ms;" + Math.round(warnRttMs) + ";" + Math.round(critRttMs) + ";0";
        String plMetric = String.format(Locale.US, "pl=%.1f%%;20;50;0;100", lossPct);
        String minMetric = !Double.isNaN(minMs) ? String.format(Locale.US, "|rtmin=%.2fms", minMs) : "";
        String maxMetric = !Double.isNaN(maxMs) ? String.format(Locale.US, "|rtmax=%.2fms", maxMs) : "";
        String metrics = rtaMetric + "|" + plMetric + minMetric + maxMetric;

        String avgStr = !Double.isNaN(avgMs) ? String.format(Locale.US, "%.1f ms", avgMs) : "TIMEOUT";
        String minMaxStr = (!Double.isNaN(minMs) && !Double.isNaN(maxMs))
                ? String.format(Locale.US, "%.1f/%.1f ms", minMs, maxMs) : "N/A";
        String lastStr = !Double.isNaN(lastMs) ? String.format(Locale.US, "%.1f ms", lastMs) : "TIMEOUT";
        String windowStr = formatTimeShort(startMs) + "-" + formatTimeShort(endMs);
        String modeLabel = completedHour
                ? "1h Summary (" + samples + "x4=" + tx + " pkt)"
                : "Buffering 1h on PDA (" + samples + "/60m, " + tx + " pkt)";

        String stateStr = state == 2 ? "CRITICAL" : state == 1 ? "WARNING" : "OK";

        return state + " \"" + serviceName + "\" " + metrics
                + " Status : " + stateStr
                + " | Target : " + targetDisplay
                + " | Mode : " + modeLabel
                + " | Loss : " + String.format(Locale.US, "%.1f%% (%d/%d rx)", lossPct, rx, tx)
                + " | Avg RTT : " + avgStr
                + " | Min/Max : " + minMaxStr
                + " | Last : " + lastStr
                + " | Timeout Min : " + failMinutes + "/" + Math.max(1, samples)
                + " | Window : " + windowStr
                + " | Log : 30d Rolling on PDA";
    }

    private static PingSample executePing(String target, int count, long timestampMs) {
        Process process = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(
                    "/system/bin/ping", "-c", String.valueOf(count), "-i", "0.4", "-W", "2", target);
            pb.redirectErrorStream(true);
            process = pb.start();

            StringBuilder out = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    out.append(line).append('\n');
                }
            }
            process.waitFor();

            String raw = out.toString();
            int tx = count;
            int rx = 0;

            Matcher lossMatcher = LOSS_PATTERN.matcher(raw);
            if (lossMatcher.find()) {
                tx = Integer.parseInt(lossMatcher.group(1));
                rx = Integer.parseInt(lossMatcher.group(2));
            } else {
                Matcher timeMatcher = TIME_LINE_PATTERN.matcher(raw);
                while (timeMatcher.find()) {
                    rx++;
                }
            }

            double minMs = Double.NaN;
            double avgMs = Double.NaN;
            double maxMs = Double.NaN;

            Matcher rttMatcher = RTT_SUMMARY_PATTERN.matcher(raw);
            if (rttMatcher.find()) {
                minMs = Double.parseDouble(rttMatcher.group(1));
                avgMs = Double.parseDouble(rttMatcher.group(2));
                maxMs = Double.parseDouble(rttMatcher.group(3));
            } else if (rx > 0) {
                Matcher timeMatcher = TIME_LINE_PATTERN.matcher(raw);
                double sum = 0.0;
                int n = 0;
                while (timeMatcher.find()) {
                    double v = Double.parseDouble(timeMatcher.group(1));
                    sum += v;
                    n++;
                    if (Double.isNaN(minMs) || v < minMs) minMs = v;
                    if (Double.isNaN(maxMs) || v > maxMs) maxMs = v;
                }
                if (n > 0) avgMs = sum / n;
            }

            double lossPct = tx > 0 ? ((tx - rx) * 100.0 / tx) : 100.0;
            return new PingSample(target, timestampMs, tx, rx, lossPct, minMs, avgMs, maxMs);
        } catch (Throwable ignored) {
            return fallbackReachabilityPing(target, count, timestampMs);
        } finally {
            if (process != null) {
                try { process.destroy(); } catch (Throwable ignored) {}
            }
        }
    }

    private static PingSample fallbackReachabilityPing(String target, int count, long timestampMs) {
        int rx = 0;
        double sum = 0.0;
        double min = Double.NaN;
        double max = Double.NaN;

        for (int i = 0; i < count; i++) {
            long t0 = System.nanoTime();
            try {
                if (InetAddress.getByName(target).isReachable(2000)) {
                    double rtt = (System.nanoTime() - t0) / 1_000_000.0;
                    rx++;
                    sum += rtt;
                    if (Double.isNaN(min) || rtt < min) min = rtt;
                    if (Double.isNaN(max) || rtt > max) max = rtt;
                }
            } catch (Throwable ignored) {}
        }

        double avg = rx > 0 ? (sum / rx) : Double.NaN;
        double loss = ((count - rx) * 100.0) / count;
        return new PingSample(target, timestampMs, count, rx, loss, min, avg, max);
    }

    private static void appendMinuteLog(Context context, PingSample s1, PingSample s2, PingSample sGw) {
        String ts = formatDateTime(s1.timestampMs);
        StringBuilder sb = new StringBuilder();
        sb.append(formatSampleLogLine(ts, s1)).append('\n');
        sb.append(formatSampleLogLine(ts, s2)).append('\n');
        if (sGw != null) {
            sb.append(formatSampleLogLine(ts, sGw)).append('\n');
        }
        writeLogString(context, sb.toString());
    }

    private static void appendHourlySummaryLog(
            Context context, String targetDisplay, int samples, int tx, int rx,
            double lossPct, double avgMs, double minMs, double maxMs, long startMs, long endMs) {
        String ts = formatDateTime(endMs);
        String avgStr = !Double.isNaN(avgMs) ? String.format(Locale.US, "%.1fms", avgMs) : "TIMEOUT";
        String minMax = (!Double.isNaN(minMs) && !Double.isNaN(maxMs))
                ? String.format(Locale.US, "%.1f/%.1fms", minMs, maxMs) : "N/A";
        String summary = String.format(Locale.US,
                "[%s] === 1H CHECKMK REPORT [%s] window=%s-%s samples=%d pkt=%d/%d loss=%.1f%% avg=%s min/max=%s ===\n",
                ts, targetDisplay, formatTimeShort(startMs), formatTimeShort(endMs),
                samples, rx, tx, lossPct, avgStr, minMax);
        writeLogString(context, summary);
    }

    private static String formatSampleLogLine(String ts, PingSample s) {
        String avgStr = !Double.isNaN(s.avgMs) ? String.format(Locale.US, "%.1fms", s.avgMs) : "TIMEOUT";
        String minStr = !Double.isNaN(s.minMs) ? String.format(Locale.US, "%.1fms", s.minMs) : "-";
        String maxStr = !Double.isNaN(s.maxMs) ? String.format(Locale.US, "%.1fms", s.maxMs) : "-";
        return String.format(Locale.US,
                "[%s] PING %-24s | tx=%d rx=%d loss=%.0f%% min=%s avg=%s max=%s",
                ts, s.target, s.tx, s.rx, s.lossPercent, minStr, avgStr, maxStr);
    }

    private static void writeLogString(Context context, String content) {
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        appendToFile(getPrimaryLogFile(context), bytes);
        try {
            File internalFile = new File(context.getFilesDir(), LOG_FILE_NAME);
            if (!internalFile.getAbsolutePath().equals(getPrimaryLogFile(context).getAbsolutePath())) {
                appendToFile(internalFile, bytes);
            }
        } catch (Throwable ignored) {}
    }

    private static void appendToFile(File file, byte[] bytes) {
        try {
            File parent = file.getParentFile();
            if (parent != null && !parent.exists()) parent.mkdirs();
            try (FileOutputStream fos = new FileOutputStream(file, true)) {
                fos.write(bytes);
                fos.flush();
            }
        } catch (Throwable ignored) {}
    }

    /**
     * Checks once every hour whether any log entries are older than 30 days (day 31+)
     * and purges them automatically like a CCTV loop recorder.
     */
    private static void pruneLogsIfDue(Context context, long nowMs) {
        try {
            SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            long lastPruneMs = p.getLong("last_prune_ms", 0L);
            if (lastPruneMs > 0L && (nowMs - lastPruneMs) < PRUNE_INTERVAL_MS) {
                return;
            }
            p.edit().putLong("last_prune_ms", nowMs).apply();
            pruneLogsOlderThan30Days(context, nowMs);
        } catch (Throwable ignored) {}
    }

    /**
     * CCTV-style 30-day rolling retention:
     * Keeps all log lines from the last 30 days (Day 1..30) and automatically deletes
     * any log lines from Day 31 and older.
     */
    public static synchronized void pruneLogsOlderThan30Days(Context context, long nowMs) {
        if (context == null || nowMs <= 0L) return;
        long cutoffMs = nowMs - LOG_RETENTION_MS;
        String cutoffTimestamp = formatDateTime(cutoffMs); // "yyyy-MM-dd HH:mm:ss"

        File primary = getPrimaryLogFile(context);
        pruneSingleLogFile(primary, cutoffTimestamp);

        try {
            File internal = new File(context.getFilesDir(), LOG_FILE_NAME);
            if (!internal.getAbsolutePath().equals(primary.getAbsolutePath())) {
                pruneSingleLogFile(internal, cutoffTimestamp);
            }
        } catch (Throwable ignored) {}

        // Clean up any legacy .old.log files so nothing older than 30 days remains
        try {
            File extDir = context.getExternalFilesDir(null);
            if (extDir != null) {
                File oldExt = new File(extDir, LOG_OLD_FILE_NAME);
                if (oldExt.exists()) oldExt.delete();
            }
            File oldInt = new File(context.getFilesDir(), LOG_OLD_FILE_NAME);
            if (oldInt.exists()) oldInt.delete();
        } catch (Throwable ignored) {}
    }

    private static void pruneSingleLogFile(File logFile, String cutoffTimestamp) {
        if (logFile == null || !logFile.exists()) return;
        try {
            boolean needsPrune = logFile.length() > EMERGENCY_MAX_LOG_BYTES;
            if (!needsPrune) {
                try (BufferedReader peek = new BufferedReader(new FileReader(logFile))) {
                    String line;
                    while ((line = peek.readLine()) != null) {
                        String ts = extractLineTimestamp(line);
                        if (ts != null) {
                            if (ts.compareTo(cutoffTimestamp) < 0) {
                                needsPrune = true;
                            }
                            break;
                        }
                    }
                }
            }
            if (!needsPrune) return;

            File parent = logFile.getParentFile();
            File tmpFile = new File(parent, LOG_TMP_FILE_NAME);

            try (BufferedReader reader = new BufferedReader(new FileReader(logFile));
                 BufferedWriter writer = new BufferedWriter(new FileWriter(tmpFile, false))) {
                String line;
                boolean keepRemaining = false;
                while ((line = reader.readLine()) != null) {
                    if (!keepRemaining) {
                        String ts = extractLineTimestamp(line);
                        if (ts != null && ts.compareTo(cutoffTimestamp) >= 0) {
                            keepRemaining = true;
                        }
                    }
                    if (keepRemaining) {
                        writer.write(line);
                        writer.newLine();
                    }
                }
                writer.flush();
            }

            if (logFile.delete()) {
                tmpFile.renameTo(logFile);
            } else {
                try (BufferedReader r = new BufferedReader(new FileReader(tmpFile));
                     BufferedWriter w = new BufferedWriter(new FileWriter(logFile, false))) {
                    String l;
                    while ((l = r.readLine()) != null) {
                        w.write(l);
                        w.newLine();
                    }
                    w.flush();
                }
                tmpFile.delete();
            }
        } catch (Throwable ignored) {}
    }

    private static String extractLineTimestamp(String line) {
        if (line == null || line.length() < 21) return null;
        if (line.charAt(0) == '[' && line.charAt(20) == ']') {
            return line.substring(1, 20);
        }
        return null;
    }

    public static File getPrimaryLogFile(Context context) {
        try {
            File extDir = context.getExternalFilesDir(null);
            if (extDir != null) {
                if (!extDir.exists()) extDir.mkdirs();
                return new File(extDir, LOG_FILE_NAME);
            }
        } catch (Throwable ignored) {}
        return new File(context.getFilesDir(), LOG_FILE_NAME);
    }

    private static String key(String target, String suffix) {
        return target.replace('.', '_').replace(':', '_') + "_" + suffix;
    }

    private static String formatDateTime(long ms) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date(ms));
    }

    private static String formatTimeShort(long ms) {
        return new SimpleDateFormat("HH:mm", Locale.US).format(new Date(ms));
    }
}
