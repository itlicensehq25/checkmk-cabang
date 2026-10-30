package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

import java.util.Locale;

public final class AgentConfig {
    public static final String PREFS = "cmkagent_prefs";

    private static final String KEY_HOSTNAME = "hostname";
    private static final String KEY_PORT = "port";
    private static final String KEY_DESIGN_CAPACITY = "design_capacity_mah";
    private static final String KEY_INITIAL_CYCLES = "initial_cycle_count";
    private static final String KEY_AUTOSTART = "autostart";
    private static final String KEY_ALLOWED_SERVER = "allowed_server";
    private static final String KEY_GATEWAY_IP = "gateway_ip";
    private static final String KEY_PUSH_ENABLED = "push_enabled";
    private static final String KEY_PUSH_URL = "push_url";
    private static final String KEY_PUSH_TOKEN = "push_token";
    private static final String KEY_PUSH_INTERVAL_SEC = "push_interval_sec";

    private AgentConfig() {}

    public static String getHostname(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String fallback = sanitizeHostname("PDA-" + Build.MODEL);
        String value = p.getString(KEY_HOSTNAME, fallback);
        if (value == null || value.trim().isEmpty()) return fallback;
        return sanitizeHostname(value.trim());
    }

    public static int getPort(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        int port = p.getInt(KEY_PORT, 6556);
        return (port >= 1 && port <= 65535) ? port : 6556;
    }

    public static double getDesignCapacityMah(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long bits = p.getLong(KEY_DESIGN_CAPACITY, Double.doubleToRawLongBits(0.0));
        double value = Double.longBitsToDouble(bits);
        return value > 0 ? value : 0.0;
    }

    public static int getInitialCycleCount(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        int val = p.getInt(KEY_INITIAL_CYCLES, 0);
        return Math.max(0, val);
    }

    public static boolean isAutoStart(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTOSTART, true);
    }

    /**
     * Returns the configured Checkmk Branch Server IP (or IP:Port) entered manually during initial setup.
     * Empty string ("") if not configured yet (no hardcoded default IPs shown).
     */
    public static String getAllowedServer(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_ALLOWED_SERVER, "");
        if (value == null || value.trim().isEmpty()) {
            return "";
        }
        return value.trim();
    }

    public static String getAllowedServerDisplay(Context context) {
        String allow = getAllowedServer(context);
        return allow.isEmpty() ? "Belum diisi (Wajib setting IP Server Cabang)" : allow;
    }

    /**
     * Returns the configured Branch Gateway IP entered manually during setup on the PDA.
     */
    public static String getGatewayIp(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_GATEWAY_IP, "");
        return value == null ? "" : value.trim();
    }

    public static String getGatewayIpDisplay(Context context) {
        String gw = getGatewayIp(context);
        return gw.isEmpty() ? "Belum diisi" : gw;
    }

    /**
     * Checks whether an incoming TCP/6556 connection from remoteIp is allowed.
     * Supports entries configured as pure IP (192.168.x.x), IP:Port (192.168.x.x:8081, :8080, :80),
     * HTTP URL (http://192.168.x.x:8081), or CIDR (192.168.x.0/24).
     */
    public static boolean isClientAllowed(Context context, String remoteIp) {
        if (remoteIp == null || remoteIp.trim().isEmpty()) return false;
        String cleanRemote = remoteIp.trim();
        if ("127.0.0.1".equals(cleanRemote) || "::1".equals(cleanRemote) || "0:0:0:0:0:0:0:1".equals(cleanRemote)) {
            return true;
        }
        String allow = getAllowedServer(context);
        if (allow.isEmpty()) {
            // Block external connections until branch server IP is configured on initial PDA setup
            return false;
        }
        if ("*".equals(allow)) return true;

        for (String item : allow.split("[,;\\s]+")) {
            String rule = normalizeServerToken(item);
            if (rule.isEmpty()) continue;
            if (cleanRemote.equals(rule)) return true;
            if (rule.contains("/") && matchesCidr(cleanRemote, rule)) return true;
        }
        return false;
    }

    /**
     * Validates the branch Checkmk Server input.
     * Accepts IPv4 (e.g. 192.168.x.x), IPv4:Port (e.g. 192.168.x.x:8081, :80, :8080), or CIDR.
     */
    public static boolean isValidAllowedServerList(String raw) {
        if (raw == null || raw.trim().isEmpty()) return false;
        String trimmed = raw.trim();
        if ("*".equals(trimmed)) return true;
        String[] parts = trimmed.split("[,;\\s]+");
        int validCount = 0;
        for (String part : parts) {
            String item = part.trim();
            if (item.isEmpty()) continue;
            if (!isValidServerToken(item)) return false;
            validCount++;
        }
        return validCount > 0;
    }

    /**
     * Strips optional http(s):// prefix, path suffix, and optional :port (e.g. :8081, :8080, :80)
     * so that TCP/6556 source IP matching works whether the user entered IP or IP:Port.
     */
    public static String normalizeServerToken(String rawToken) {
        if (rawToken == null) return "";
        String t = rawToken.trim();
        if (t.startsWith("http://")) t = t.substring(7);
        else if (t.startsWith("https://")) t = t.substring(8);

        // Keep CIDR if present, otherwise strip path
        if (!t.contains("/")) {
            int slash = t.indexOf('/');
            if (slash >= 0) t = t.substring(0, slash);
        } else {
            // Check if slash is CIDR (/0..32) or URL path
            int slash = t.indexOf('/');
            String afterSlash = t.substring(slash + 1);
            if (!afterSlash.matches("\\d{1,2}")) {
                t = t.substring(0, slash);
            }
        }

        // Strip :port (e.g. 192.168.55.112:8081 -> 192.168.55.112)
        int colon = t.indexOf(':');
        if (colon > 0) {
            t = t.substring(0, colon);
        }
        return t.trim();
    }

    private static boolean isValidServerToken(String rawToken) {
        String t = rawToken.trim();
        if (t.startsWith("http://")) t = t.substring(7);
        else if (t.startsWith("https://")) t = t.substring(8);

        // Optional :port validation (e.g. :80, :8080, :8081)
        if (t.contains(":") && !t.contains("/")) {
            String[] hostPort = t.split(":");
            if (hostPort.length != 2) return false;
            try {
                int port = Integer.parseInt(hostPort[1]);
                if (port < 1 || port > 65535) return false;
            } catch (NumberFormatException e) {
                return false;
            }
            t = hostPort[0];
        }

        return isValidIpv4OrCidr(t);
    }

    public static boolean isValidIpv4(String token) {
        if (token == null || token.trim().isEmpty()) return false;
        String[] octets = token.trim().split("\\.");
        if (octets.length != 4) return false;
        for (String o : octets) {
            try {
                int v = Integer.parseInt(o);
                if (v < 0 || v > 255) return false;
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return true;
    }

    private static boolean isValidIpv4OrCidr(String token) {
        String ipPart = token;
        if (token.contains("/")) {
            String[] split = token.split("/");
            if (split.length != 2) return false;
            ipPart = split[0];
            try {
                int prefix = Integer.parseInt(split[1]);
                if (prefix < 0 || prefix > 32) return false;
            } catch (NumberFormatException e) {
                return false;
            }
        }
        String[] octets = ipPart.split("\\.");
        if (octets.length != 4) return false;
        for (String o : octets) {
            try {
                int v = Integer.parseInt(o);
                if (v < 0 || v > 255) return false;
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return true;
    }

    private static boolean matchesCidr(String ip, String cidr) {
        try {
            String[] parts = cidr.split("/");
            int prefix = Integer.parseInt(parts[1]);
            int ipInt = ipv4ToInt(ip);
            int netInt = ipv4ToInt(parts[0]);
            int mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix));
            return (ipInt & mask) == (netInt & mask);
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static int ipv4ToInt(String ip) {
        String[] octets = ip.split("\\.");
        return ((Integer.parseInt(octets[0]) & 0xFF) << 24)
                | ((Integer.parseInt(octets[1]) & 0xFF) << 16)
                | ((Integer.parseInt(octets[2]) & 0xFF) << 8)
                | (Integer.parseInt(octets[3]) & 0xFF);
    }

    public static boolean isPushEnabled(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_PUSH_ENABLED, true);
    }

    public static String getPushUrl(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PUSH_URL, "");
        return value == null ? "" : value.trim();
    }

    public static String getPushToken(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PUSH_TOKEN, "");
        return value == null ? "" : value.trim();
    }

    public static int getPushIntervalSec(Context context) {
        int value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getInt(KEY_PUSH_INTERVAL_SEC, 300);
        if (value < 60) return 60;
        if (value > 86400) return 86400;
        return value;
    }

    public static boolean isPushConfigured(Context context) {
        return isPushEnabled(context) && !getPushUrl(context).isEmpty();
    }

    public static void save(Context context, String hostname, int port,
                            double designCapacityMah, int initialCycles, boolean autoStart,
                            String allowedServer, String gatewayIp, boolean pushEnabled,
                            String pushUrl, String pushToken, int pushIntervalSec) {
        String cleanAllowed = allowedServer == null ? "" : allowedServer.trim();
        String cleanGateway = gatewayIp == null ? "" : gatewayIp.trim();
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_HOSTNAME, sanitizeHostname(hostname))
                .putInt(KEY_PORT, port)
                .putLong(KEY_DESIGN_CAPACITY,
                        Double.doubleToRawLongBits(Math.max(0.0, designCapacityMah)))
                .putInt(KEY_INITIAL_CYCLES, Math.max(0, initialCycles))
                .putBoolean(KEY_AUTOSTART, autoStart)
                .putString(KEY_ALLOWED_SERVER, cleanAllowed)
                .putString(KEY_GATEWAY_IP, cleanGateway)
                .putBoolean(KEY_PUSH_ENABLED, pushEnabled)
                .putString(KEY_PUSH_URL, pushUrl == null ? "" : pushUrl.trim())
                .putString(KEY_PUSH_TOKEN, pushToken == null ? "" : pushToken.trim())
                .putInt(KEY_PUSH_INTERVAL_SEC, Math.max(60, Math.min(86400, pushIntervalSec)))
                .apply();
    }

    public static String sanitizeHostname(String value) {
        if (value == null) return "ANDROID-PDA";
        String cleaned = value.trim().toUpperCase(Locale.US)
                .replaceAll("[^A-Z0-9._-]", "-")
                .replaceAll("-+", "-");
        if (cleaned.isEmpty()) return "ANDROID-PDA";
        return cleaned.length() > 63 ? cleaned.substring(0, 63) : cleaned;
    }
}
