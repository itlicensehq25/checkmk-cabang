package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.DhcpInfo;
import android.net.LinkProperties;
import android.net.Network;
import android.net.RouteInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.provider.Settings;

import org.json.JSONObject;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.Locale;

public class AgentConfig {
    private static final String PREF_NAME = "cmkagent_rust_prefs";

    private static final String KEY_HOSTNAME = "hostname";
    private static final String KEY_PORT = "port";
    private static final String KEY_ALLOWED = "allowed_servers";
    private static final String KEY_ALLOW_PRIVATE = "allow_all_private";
    private static final String KEY_GATEWAY = "gateway_ip";
    private static final String KEY_LAST_DETECTED_GATEWAY = "last_detected_gateway_ip";
    private static final String KEY_DESIGN_MAH = "battery_design_mah";
    private static final String KEY_INITIAL_CYCLES = "initial_battery_cycles";
    private static final String KEY_PUSH_ENABLED = "push_enabled";
    private static final String KEY_PUSH_URL = "push_url";
    private static final String KEY_PUSH_TOKEN = "push_token";
    private static final String KEY_PUSH_INTERVAL = "push_interval_sec";

    private final Context appCtx;
    private final SharedPreferences prefs;

    public AgentConfig(Context ctx) {
        this.appCtx = ctx.getApplicationContext();
        this.prefs = appCtx.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE);
    }

    public static String sanitizeHostname(String raw) {
        if (raw == null) return "ANDROID-PDA";
        String clean = raw.trim().replaceAll("[^a-zA-Z0-9._-]", "");
        return clean.isEmpty() ? "ANDROID-PDA" : clean;
    }

    public String getDefaultHostname() {
        try {
            String btName = Settings.Global.getString(appCtx.getContentResolver(), "device_name");
            if (btName != null && !btName.trim().isEmpty()) {
                return sanitizeHostname(btName).toUpperCase(Locale.US);
            }
        } catch (Throwable ignored) {}
        String model = (Build.MODEL == null ? "ANDROID" : Build.MODEL).replaceAll("\\s+", "-");
        return sanitizeHostname(model).toUpperCase(Locale.US);
    }

    public String getHostname() {
        String stored = prefs.getString(KEY_HOSTNAME, "");
        if (stored == null || stored.trim().isEmpty()) {
            return getDefaultHostname();
        }
        return sanitizeHostname(stored);
    }

    public int getPort() {
        return prefs.getInt(KEY_PORT, 6556);
    }

    public String getAllowedServersRaw() {
        return prefs.getString(KEY_ALLOWED, "");
    }

    public boolean isAllowAllPrivate() {
        return prefs.getBoolean(KEY_ALLOW_PRIVATE, true);
    }

    public String getConfiguredGatewayIp() {
        return prefs.getString(KEY_GATEWAY, "");
    }

    public String getGatewayIp() {
        String cfg = getConfiguredGatewayIp().trim();
        if (!cfg.isEmpty()) return cfg;
        String detected = detectWifiGateway(appCtx);
        if (!detected.isEmpty()) {
            if (!detected.equals(prefs.getString(KEY_LAST_DETECTED_GATEWAY, ""))) {
                prefs.edit().putString(KEY_LAST_DETECTED_GATEWAY, detected).apply();
            }
            return detected;
        }
        return prefs.getString(KEY_LAST_DETECTED_GATEWAY, "");
    }

    public static String detectWifiGateway(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network net = cm.getActiveNetwork();
                LinkProperties lp = net != null ? cm.getLinkProperties(net) : null;
                if (lp != null) {
                    for (RouteInfo ri : lp.getRoutes()) {
                        if (ri.isDefaultRoute() && ri.getGateway() instanceof Inet4Address) {
                            String gw = ri.getGateway().getHostAddress();
                            if (gw != null && !"0.0.0.0".equals(gw)) return gw;
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}

        try {
            WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                DhcpInfo dhcp = wm.getDhcpInfo();
                if (dhcp != null && dhcp.gateway != 0) {
                    int ip = dhcp.gateway;
                    return String.format(Locale.US, "%d.%d.%d.%d",
                            (ip & 0xff), (ip >> 8 & 0xff), (ip >> 16 & 0xff), (ip >> 24 & 0xff));
                }
            }
        } catch (Throwable ignored) {}
        return "";
    }

    public static String getDeviceIpv4(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network net = cm.getActiveNetwork();
                LinkProperties lp = net != null ? cm.getLinkProperties(net) : null;
                if (lp != null) {
                    for (android.net.LinkAddress la : lp.getLinkAddresses()) {
                        InetAddress addr = la.getAddress();
                        if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                            return addr.getHostAddress();
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}
        return "0.0.0.0";
    }

    public int getBatteryDesignMahOverride() {
        return prefs.getInt(KEY_DESIGN_MAH, 0);
    }

    public int getInitialBatteryCycles() {
        return prefs.getInt(KEY_INITIAL_CYCLES, 0);
    }

    public boolean isPushEnabled() {
        return prefs.getBoolean(KEY_PUSH_ENABLED, false);
    }

    public String getPushUrl() {
        return prefs.getString(KEY_PUSH_URL, "");
    }

    public String getPushToken() {
        return prefs.getString(KEY_PUSH_TOKEN, "");
    }

    public int getPushIntervalSec() {
        return Math.max(60, prefs.getInt(KEY_PUSH_INTERVAL, 300));
    }

    public void save(
            String hostname,
            int port,
            String allowedServers,
            boolean allowAllPrivate,
            String gatewayIp,
            int designMah,
            int initialCycles,
            boolean pushEnabled,
            String pushUrl,
            String pushToken,
            int pushIntervalSec
    ) {
        prefs.edit()
                .putString(KEY_HOSTNAME, sanitizeHostname(hostname))
                .putInt(KEY_PORT, port > 0 && port <= 65535 ? port : 6556)
                .putString(KEY_ALLOWED, allowedServers == null ? "" : allowedServers.trim())
                .putBoolean(KEY_ALLOW_PRIVATE, allowAllPrivate)
                .putString(KEY_GATEWAY, gatewayIp == null ? "" : gatewayIp.trim())
                .putInt(KEY_DESIGN_MAH, Math.max(0, designMah))
                .putInt(KEY_INITIAL_CYCLES, Math.max(0, initialCycles))
                .putBoolean(KEY_PUSH_ENABLED, pushEnabled)
                .putString(KEY_PUSH_URL, pushUrl == null ? "" : pushUrl.trim())
                .putString(KEY_PUSH_TOKEN, pushToken == null ? "" : pushToken.trim())
                .putInt(KEY_PUSH_INTERVAL, Math.max(60, pushIntervalSec))
                .apply();
    }

    public String toNativeConfigJson() {
        JSONObject o = new JSONObject();
        try {
            o.put("hostname", getHostname());
            o.put("port", getPort());
            o.put("reported_version", "Agen BMS : 1.3.8");
            o.put("allowed_servers", getAllowedServersRaw());
            o.put("allow_all_private", isAllowAllPrivate());
            o.put("gateway_ip", getGatewayIp());
            o.put("push_enabled", isPushEnabled());
            o.put("push_url", getPushUrl());
            o.put("push_token", getPushToken());
            o.put("push_interval_sec", getPushIntervalSec());
            o.put("ping_enabled", true);
            o.put("local_ping_target", "192.168.122.10");
            o.put("internet_ping_target", "8.8.8.8");
            o.put("hw_sw_inventory", true);
        } catch (Throwable ignored) {}
        return o.toString();
    }
}
