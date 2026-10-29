package com.bcp.checkmkagent;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final int C_BG = Color.rgb(15, 23, 32);
    private static final int C_CARD = Color.rgb(24, 35, 46);
    private static final int C_CARD_ALT = Color.rgb(20, 30, 40);
    private static final int C_TEXT = Color.rgb(244, 247, 249);
    private static final int C_MUTED = Color.rgb(170, 183, 195);
    private static final int C_GREEN = Color.rgb(91, 207, 126);
    private static final int C_WARN = Color.rgb(246, 200, 95);
    private static final int C_CRIT = Color.rgb(230, 106, 106);
    private static final int C_LINE = Color.rgb(45, 61, 75);

    private EditText hostnameInput;
    private EditText portInput;
    private EditText designCapacityInput;
    private EditText initialCyclesInput;
    private EditText allowedServerInput;
    private EditText gatewayIpInput;
    private CheckBox autoStartInput;
    private CheckBox pushEnabledInput;
    private EditText pushUrlInput;
    private EditText pushTokenInput;
    private EditText pushIntervalInput;

    private Section agentSection;
    private Section transportSection;
    private Section batterySection;
    private Section systemSection;
    private Section networkSection;
    private Section appsSection;
    private Section deviceSection;
    private Section settingsSection;
    private Section diagnosticsSection;

    private TextView agentBadge;
    private TextView agentText;
    private TextView batteryHeadline;
    private TextView batteryText;
    private TextView systemText;
    private TextView networkText;
    private TextView appsText;
    private TextView deviceText;
    private TextView diagnosticsText;
    private ProgressBar batteryProgress;

    private final List<Section> allSections = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(C_BG);
        getWindow().setNavigationBarColor(C_BG);
        setContentView(buildUi());
        loadConfig();
        requestRuntimePermissionsIfNeeded();
        updateDashboard();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (agentText != null) updateDashboard();
    }

    private ScrollView buildUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(C_BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(18), dp(16), dp(28));
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        root.addView(buildHeader());
        root.addView(space(12));
        root.addView(buildSectionControls(), matchWrapMargin(0, 0, 0, 12));

        agentSection = section("AGENT", "Pull listener & firewall status", false);
        agentBadge = badge("STARTING", C_WARN);
        agentSection.content.addView(agentBadge, wrap());
        agentText = bodyText();
        agentText.setPadding(0, dp(12), 0, 0);
        agentSection.content.addView(agentText, wrap());
        root.addView(agentSection.card, matchWrapMargin(0, 0, 0, 12));

        transportSection = section("HYBRID TRANSPORT", "Pull primary + push warm backup", false);
        TextView transportHelp = bodyText();
        transportHelp.setText("Pull TCP/6556 tetap menjadi jalur utama (dibatasi ke IP Server Checkmk Cabang). Push menjaga salinan data terbaru di receiver sebagai jalur cadangan.");
        transportHelp.setTextColor(C_MUTED);
        transportSection.content.addView(transportHelp, wrap());
        root.addView(transportSection.card, matchWrapMargin(0, 0, 0, 12));

        batterySection = section("BATTERY (1-LINE UNIFIED)", "Health (2946 mAh @ 100%), cycles, temp, volt & current", false);
        batteryHeadline = new TextView(this);
        batteryHeadline.setTextColor(C_TEXT);
        batteryHeadline.setTextSize(25);
        batteryHeadline.setTypeface(Typeface.DEFAULT_BOLD);
        batterySection.content.addView(batteryHeadline, wrap());

        batteryProgress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        batteryProgress.setMax(100);
        batteryProgress.setProgressTintList(ColorStateList.valueOf(C_GREEN));
        batteryProgress.setProgressBackgroundTintList(ColorStateList.valueOf(C_LINE));
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(8));
        bp.setMargins(0, dp(10), 0, dp(10));
        batterySection.content.addView(batteryProgress, bp);

        batteryText = bodyText();
        batterySection.content.addView(batteryText, wrap());
        root.addView(batterySection.card, matchWrapMargin(0, 0, 0, 12));

        systemSection = section("SYSTEM", "RAM & internal storage", false);
        systemText = bodyText();
        systemSection.content.addView(systemText, wrap());
        root.addView(systemSection.card, matchWrapMargin(0, 0, 0, 12));

        networkSection = section("NETWORK, AP ROAMING & PING (1H)", "Wi-Fi UniFi/AP roaming & 4x/1m ping (30d CCTV log)", false);
        networkText = bodyText();
        networkSection.content.addView(networkText, wrap());

        LinearLayout logActions = new LinearLayout(this);
        logActions.setOrientation(LinearLayout.HORIZONTAL);
        Button pingLogBtn = actionButton("VIEW PING LOG", C_CARD_ALT, C_GREEN);
        pingLogBtn.setOnClickListener(v -> showPingLogDialog());
        Button roamLogBtn = actionButton("VIEW ROAMING LOG", C_CARD_ALT, C_GREEN);
        roamLogBtn.setOnClickListener(v -> showRoamingLogDialog());
        logActions.addView(pingLogBtn, weightButton());
        LinearLayout.LayoutParams secondLog = weightButton();
        secondLog.setMargins(dp(8), 0, 0, 0);
        logActions.addView(roamLogBtn, secondLog);
        networkSection.content.addView(logActions, matchWrapMargin(0, 12, 0, 0));

        LinearLayout netActions = new LinearLayout(this);
        netActions.setOrientation(LinearLayout.HORIZONTAL);
        Button permissionButton = actionButton("APP PERMISSIONS", C_CARD_ALT, C_TEXT);
        permissionButton.setOnClickListener(v -> openAppSettings());
        Button batteryOptButton = actionButton("BATTERY UNRESTRICTED", C_CARD_ALT, C_TEXT);
        batteryOptButton.setOnClickListener(v -> requestIgnoreBatteryOptimizations());
        netActions.addView(permissionButton, weightButton());
        LinearLayout.LayoutParams secondP = weightButton();
        secondP.setMargins(dp(8), 0, 0, 0);
        netActions.addView(batteryOptButton, secondP);
        networkSection.content.addView(netActions, matchWrapMargin(0, 8, 0, 0));
        root.addView(networkSection.card, matchWrapMargin(0, 0, 0, 12));

        appsSection = section("APPLICATIONS INVENTORY", "Installed APK packages & Checkmk HW/SW", false);
        appsText = bodyText();
        appsSection.content.addView(appsText, wrap());
        Button rescanApps = actionButton("SCAN PACKAGES NOW", C_CARD_ALT, C_TEXT);
        rescanApps.setOnClickListener(v -> {
            updateDashboard();
            Toast.makeText(this, "Inventaris aplikasi diperbarui", Toast.LENGTH_SHORT).show();
        });
        appsSection.content.addView(rescanApps, matchWrapMargin(0, 10, 0, 0));
        root.addView(appsSection.card, matchWrapMargin(0, 0, 0, 12));

        deviceSection = section("DEVICE", "Hardware & Android profile", false);
        deviceText = bodyText();
        deviceSection.content.addView(deviceText, wrap());
        root.addView(deviceSection.card, matchWrapMargin(0, 0, 0, 12));

        settingsSection = section("SETTINGS", "Tap to configure agent & IP Server Checkmk Cabang", false);
        hostnameInput = input(settingsSection.content, "Hostname Checkmk", InputType.TYPE_CLASS_TEXT,
                "Contoh: PDA-10-FAUZI");
        portInput = input(settingsSection.content, "TCP Port", InputType.TYPE_CLASS_NUMBER, "6556");

        allowedServerInput = input(settingsSection.content,
                "IP Server Checkmk Cabang",
                InputType.TYPE_CLASS_TEXT,
                "Masukkan IP atau IP:Port Cabang (misal :80, :8080, :8081)");

        gatewayIpInput = input(settingsSection.content,
                "IP Gateway Cabang (Ping Monitor Baris ke-3)",
                InputType.TYPE_CLASS_TEXT,
                "Contoh: 192.168.55.1 atau 192.168.122.1");

        Button detectGatewayBtn = actionButton("AUTO-DETECT GATEWAY DARI WI-FI", C_CARD_ALT, C_MUTED);
        detectGatewayBtn.setOnClickListener(v -> {
            String detected = DeviceMetrics.getDetectedGatewayIp(this);
            if (!detected.isEmpty()) {
                gatewayIpInput.setText(detected);
                Toast.makeText(this, "Gateway terdeteksi: " + detected, Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "Tidak dapat mendeteksi gateway (Pastikan Wi-Fi terhubung)", Toast.LENGTH_SHORT).show();
            }
        });
        settingsSection.content.addView(detectGatewayBtn, matchWrapMargin(0, 0, 0, 8));

        designCapacityInput = input(settingsSection.content,
                "Design Capacity (mAh, 0 = auto)",
                InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL,
                "0 = Otomatis (MT93 Spec = 4800 mAh, 100% Full = 2946 mAh)");
        initialCyclesInput = input(settingsSection.content,
                "Initial Battery Cycles (0 = auto hitung dari pengisian)",
                InputType.TYPE_CLASS_NUMBER,
                "0");

        pushEnabledInput = new CheckBox(this);
        pushEnabledInput.setText("Aktifkan PUSH backup (Hybrid)");
        pushEnabledInput.setTextColor(C_TEXT);
        pushEnabledInput.setButtonTintList(ColorStateList.valueOf(C_GREEN));
        pushEnabledInput.setPadding(0, dp(6), 0, dp(6));
        settingsSection.content.addView(pushEnabledInput, matchWrap());

        pushUrlInput = input(settingsSection.content,
                "Push Receiver URL",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI,
                "Contoh: http://<IP-Server-Cabang>:18080/api/v1/agent");
        pushTokenInput = input(settingsSection.content,
                "Push Token",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD,
                "Bearer token receiver (opsional untuk test)");
        pushIntervalInput = input(settingsSection.content,
                "Push Interval (detik, minimal 60)",
                InputType.TYPE_CLASS_NUMBER,
                "300");

        Button testPush = actionButton("TEST PUSH NOW", C_CARD_ALT, C_TEXT);
        testPush.setOnClickListener(v -> testPushNow());
        settingsSection.content.addView(testPush, matchWrapMargin(0, 2, 0, 8));

        autoStartInput = new CheckBox(this);
        autoStartInput.setText("Start agent otomatis setelah boot");
        autoStartInput.setTextColor(C_TEXT);
        autoStartInput.setButtonTintList(ColorStateList.valueOf(C_GREEN));
        autoStartInput.setPadding(0, dp(6), 0, dp(8));
        settingsSection.content.addView(autoStartInput, matchWrap());

        Button start = actionButton("SAVE & START AGENT", C_GREEN, Color.rgb(10, 32, 18));
        start.setOnClickListener(v -> saveAndStart());
        settingsSection.content.addView(start, matchWrapMargin(0, 4, 0, 8));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        Button refresh = actionButton("REFRESH", C_CARD_ALT, C_TEXT);
        refresh.setOnClickListener(v -> updateDashboard());
        Button preview = actionButton("AGENT OUTPUT", C_CARD_ALT, C_TEXT);
        preview.setOnClickListener(v -> showAgentOutput());
        actions.addView(refresh, weightButton());
        LinearLayout.LayoutParams second = weightButton();
        second.setMargins(dp(8), 0, 0, 0);
        actions.addView(preview, second);
        settingsSection.content.addView(actions, matchWrapMargin(0, 0, 0, 8));

        Button stop = actionButton("STOP AGENT", Color.rgb(82, 42, 47), Color.rgb(255, 205, 210));
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, CheckmkAgentService.class));
            AgentStats.recordStop(this);
            Toast.makeText(this, "Agent dihentikan", Toast.LENGTH_SHORT).show();
            agentText.postDelayed(this::updateDashboard, 250);
        });
        settingsSection.content.addView(stop, matchWrap());
        root.addView(settingsSection.card, matchWrapMargin(0, 0, 0, 12));

        diagnosticsSection = section("DIAGNOSTICS", "Status & counter", false);
        diagnosticsText = bodyText();
        diagnosticsText.setTextIsSelectable(true);
        diagnosticsSection.content.addView(diagnosticsText, wrap());
        root.addView(diagnosticsSection.card, matchWrapMargin(0, 0, 0, 12));

        TextView footer = new TextView(this);
        footer.setText("Universal Android Agent • Checkmk Hybrid\nDibuat oleh IT OPS HQEJBNT");
        footer.setTextColor(C_MUTED);
        footer.setTextSize(12);
        footer.setGravity(Gravity.CENTER);
        footer.setPadding(dp(12), dp(4), dp(12), 0);
        root.addView(footer, matchWrap());

        return scroll;
    }

    private View buildHeader() {
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.ic_cmkagent);
        LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(dp(58), dp(58));
        ip.setMargins(0, 0, dp(14), 0);
        header.addView(icon, ip);

        LinearLayout text = new LinearLayout(this);
        text.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText("cmkagent");
        title.setTextColor(C_TEXT);
        title.setTextSize(29);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        TextView subtitle = new TextView(this);
        subtitle.setText("Checkmk Universal Android Agent  •  v" + CheckmkOutput.VERSION);
        subtitle.setTextColor(C_MUTED);
        subtitle.setTextSize(13);
        text.addView(title);
        text.addView(subtitle);
        header.addView(text, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return header;
    }

    private View buildSectionControls() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button expand = actionButton("EXPAND ALL", C_CARD_ALT, C_TEXT);
        Button collapse = actionButton("COLLAPSE ALL", C_CARD_ALT, C_TEXT);
        expand.setOnClickListener(v -> setAllSections(true));
        collapse.setOnClickListener(v -> setAllSections(false));
        row.addView(expand, weightButton());
        LinearLayout.LayoutParams cp = weightButton();
        cp.setMargins(dp(8), 0, 0, 0);
        row.addView(collapse, cp);
        return row;
    }

    private Section section(String titleText, String subtitleText, boolean expanded) {
        Section s = new Section();
        s.card = new LinearLayout(this);
        s.card.setOrientation(LinearLayout.VERTICAL);
        s.card.setPadding(dp(16), dp(13), dp(16), dp(14));
        s.card.setBackground(rounded(C_CARD, 16, C_LINE, 1));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(0, dp(2), 0, dp(2));

        LinearLayout labels = new LinearLayout(this);
        labels.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText(titleText);
        title.setTextColor(C_GREEN);
        title.setTextSize(13);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        TextView subtitle = new TextView(this);
        subtitle.setText(subtitleText);
        subtitle.setTextColor(C_MUTED);
        subtitle.setTextSize(12);
        subtitle.setPadding(0, dp(2), 0, 0);
        labels.addView(title, wrap());
        labels.addView(subtitle, wrap());
        header.addView(labels, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        s.arrow = new TextView(this);
        s.arrow.setTextColor(C_MUTED);
        s.arrow.setTextSize(20);
        s.arrow.setGravity(Gravity.CENTER);
        s.arrow.setPadding(dp(12), 0, dp(4), 0);
        header.addView(s.arrow, new LinearLayout.LayoutParams(dp(44), dp(44)));
        s.card.addView(header, matchWrap());

        s.summary = new TextView(this);
        s.summary.setTextColor(C_TEXT);
        s.summary.setTextSize(14);
        s.summary.setTypeface(Typeface.DEFAULT_BOLD);
        s.summary.setPadding(0, dp(8), 0, dp(2));
        s.card.addView(s.summary, matchWrap());

        s.content = new LinearLayout(this);
        s.content.setOrientation(LinearLayout.VERTICAL);
        s.content.setPadding(0, dp(12), 0, 0);
        s.card.addView(s.content, matchWrap());

        View.OnClickListener toggle = v -> setSectionExpanded(s, !s.expanded);
        header.setOnClickListener(toggle);
        s.summary.setOnClickListener(toggle);
        s.card.setClickable(true);
        s.card.setFocusable(true);

        allSections.add(s);
        setSectionExpanded(s, expanded);
        return s;
    }

    private void setSectionExpanded(Section s, boolean expanded) {
        s.expanded = expanded;
        s.content.setVisibility(expanded ? View.VISIBLE : View.GONE);
        s.arrow.setText(expanded ? "▾" : "▸");
    }

    private void setAllSections(boolean expanded) {
        for (Section s : allSections) setSectionExpanded(s, expanded);
    }

    private void loadConfig() {
        hostnameInput.setText(AgentConfig.getHostname(this));
        portInput.setText(String.valueOf(AgentConfig.getPort(this)));
        double design = AgentConfig.getDesignCapacityMah(this);
        designCapacityInput.setText(design > 0
                ? String.format(Locale.US, "%.0f", design) : "0");
        initialCyclesInput.setText(String.valueOf(AgentConfig.getInitialCycleCount(this)));
        allowedServerInput.setText(AgentConfig.getAllowedServer(this));
        gatewayIpInput.setText(AgentConfig.getGatewayIp(this));
        pushEnabledInput.setChecked(AgentConfig.isPushEnabled(this));
        pushUrlInput.setText(AgentConfig.getPushUrl(this));
        pushTokenInput.setText(AgentConfig.getPushToken(this));
        pushIntervalInput.setText(String.valueOf(AgentConfig.getPushIntervalSec(this)));
        autoStartInput.setChecked(AgentConfig.isAutoStart(this));
    }

    private boolean saveConfigOnly() {
        try {
            String hostname = hostnameInput.getText().toString().trim();
            int port = Integer.parseInt(portInput.getText().toString().trim());
            String designRaw = designCapacityInput.getText().toString().trim();
            double design = designRaw.isEmpty() ? 0.0 : Double.parseDouble(designRaw);
            String initCyclesRaw = initialCyclesInput.getText().toString().trim();
            int initCycles = initCyclesRaw.isEmpty() ? 0 : Integer.parseInt(initCyclesRaw);
            String allowed = allowedServerInput.getText().toString().trim();
            String gatewayIp = gatewayIpInput.getText().toString().trim();
            boolean pushEnabled = pushEnabledInput.isChecked();
            String pushUrl = pushUrlInput.getText().toString().trim();
            String pushToken = pushTokenInput.getText().toString().trim();
            String pushIntervalRaw = pushIntervalInput.getText().toString().trim();
            int pushInterval = pushIntervalRaw.isEmpty() ? 300 : Integer.parseInt(pushIntervalRaw);
            if (port < 1 || port > 65535) throw new IllegalArgumentException("Port tidak valid");
            if (design < 0 || design > 50000) throw new IllegalArgumentException("Design capacity tidak valid");
            if (initCycles < 0 || initCycles > 10000) throw new IllegalArgumentException("Initial cycles tidak valid");
            if (!AgentConfig.isValidAllowedServerList(allowed)) {
                throw new IllegalArgumentException("Masukkan IP Server Checkmk Cabang terlebih dahulu (bisa IP saja atau IP:Port seperti :80, :8080, :8081)");
            }
            if (!gatewayIp.isEmpty() && !AgentConfig.isValidIpv4(gatewayIp)) {
                throw new IllegalArgumentException("Format IP Gateway Cabang tidak valid (contoh: 192.168.55.1)");
            }
            if (pushInterval < 60 || pushInterval > 86400) throw new IllegalArgumentException("Push interval harus 60-86400 detik");
            if (pushEnabled && !pushUrl.isEmpty()
                    && !(pushUrl.startsWith("http://") || pushUrl.startsWith("https://"))) {
                throw new IllegalArgumentException("Push URL harus dimulai http:// atau https://");
            }
            AgentConfig.save(this, hostname, port, design, initCycles, autoStartInput.isChecked(), allowed, gatewayIp,
                    pushEnabled, pushUrl, pushToken, pushInterval);
            return true;
        } catch (Exception e) {
            Toast.makeText(this, "Konfigurasi tidak valid: " + e.getMessage(), Toast.LENGTH_LONG).show();
            return false;
        }
    }

    private void saveAndStart() {
        if (!saveConfigOnly()) return;
        stopService(new Intent(this, CheckmkAgentService.class));
        Intent service = new Intent(this, CheckmkAgentService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service);
        else startService(service);
        Toast.makeText(this, "cmkagent berjalan", Toast.LENGTH_SHORT).show();
        agentText.postDelayed(this::updateDashboard, 500);
    }

    private void updateDashboard() {
        DeviceMetrics.BatteryInfo b = DeviceMetrics.readBattery(this);
        DeviceMetrics.UsageInfo ram = DeviceMetrics.readRam(this);
        DeviceMetrics.UsageInfo storage = DeviceMetrics.readStorage();
        DeviceMetrics.WifiStatus wifi = DeviceMetrics.readWifi(this);
        DeviceMetrics.DeviceInfo device = DeviceMetrics.readDeviceInfo();
        DeviceMetrics.AppInventoryInfo apps = DeviceMetrics.readAppInventory(this);
        AgentStats.Snapshot stats = AgentStats.read(this);
        PingMonitor.TargetStatus pingLocal = PingMonitor.readStatus(this, PingMonitor.TARGET_LOCAL);
        PingMonitor.TargetStatus pingNet = PingMonitor.readStatus(this, PingMonitor.TARGET_INTERNET);
        PingMonitor.TargetStatus pingGw = PingMonitor.readStatus(this, PingMonitor.TARGET_GATEWAY_KEY);

        String localIp = DeviceMetrics.getLocalIpv4();
        String lastPull = stats.lastPullMs > 0 ? formatDate(stats.lastPullMs) : "Belum ada";
        String allowDisplay = AgentConfig.getAllowedServerDisplay(this);

        agentSection.summary.setText((stats.running ? "RUNNING" : "STOPPED")
                + "  •  " + AgentConfig.getHostname(this) + "  •  " + localIp);
        agentBadge.setText(stats.running ? "● AGENT RUNNING" : "● AGENT STOPPED");
        styleBadge(agentBadge, stats.running ? C_GREEN : C_CRIT);
        agentText.setText(
                "Hostname     : " + AgentConfig.getHostname(this) + "\n"
                        + "Listen       : 0.0.0.0:" + AgentConfig.getPort(this) + " (Restricted)\n"
                        + "Device IP    : " + localIp + "\n"
                        + "Last pull    : " + lastPull + "\n"
                        + "Last client  : " + stats.lastClient + "\n"
                        + "Server Cabang: " + allowDisplay + "\n"
                        + "Mode         : HYBRID (PULL primary + PUSH backup)"
        );

        String pushUrl = AgentConfig.getPushUrl(this);
        boolean pushConfigured = AgentConfig.isPushConfigured(this);
        String lastPush = stats.lastPushMs > 0 ? formatDate(stats.lastPushMs) : "Belum ada";
        String pushState = !pushConfigured ? "NOT CONFIGURED"
                : stats.lastPushMs <= 0 ? "WAITING"
                : stats.lastPushOk ? "OK" : "FAILED";
        transportSection.summary.setText("PULL primary  •  PUSH " + pushState
                + "  •  " + AgentConfig.getPushIntervalSec(this) + "s");
        TextView transportBody = ensureTransportBody();
        transportBody.setText(
                "Primary        : PULL TCP/" + AgentConfig.getPort(this) + "\n"
                        + "Backup         : PUSH HTTP(S)\n"
                        + "Receiver       : " + (pushUrl.isEmpty() ? "Not configured" : pushUrl) + "\n"
                        + "Interval       : " + AgentConfig.getPushIntervalSec(this) + " sec\n"
                        + "Last push      : " + lastPush + "\n"
                        + "Last result    : " + pushState + "\n"
                        + "HTTP code      : " + (stats.lastPushCode > 0 ? stats.lastPushCode : "N/A") + "\n"
                        + "Detail         : " + stats.lastPushMessage + "\n"
                        + "Push success   : " + stats.pushSuccesses + "\n"
                        + "Push failures  : " + stats.pushFailures
        );

        int level = Math.max(0, b.level);
        int batteryColor = level < 15 ? C_CRIT : level < 30 ? C_WARN : C_GREEN;
        batteryProgress.setProgress(level);
        batteryProgress.setProgressTintList(ColorStateList.valueOf(batteryColor));
        batteryHeadline.setText((b.level >= 0 ? b.level + "%" : "N/A") + "  •  " + b.status);
        batteryHeadline.setTextColor(batteryColor);

        String health = Double.isNaN(b.healthPercent) ? "N/A"
                : String.format(Locale.US, "%.1f%%", b.healthPercent);
        String full = Double.isNaN(b.fullCapacityMah) ? "2946 mAh"
                : Math.round(b.fullCapacityMah) + " mAh";
        String design = Double.isNaN(b.designCapacityMah) ? "4800 mAh"
                : Math.round(b.designCapacityMah) + " mAh";
        String temp = Double.isNaN(b.temperatureC) ? "N/A"
                : String.format(Locale.US, "%.1f C", b.temperatureC);
        String voltage = Double.isNaN(b.voltageV) ? "N/A"
                : String.format(Locale.US, "%.2f V", b.voltageV);
        String chargeNow = Double.isNaN(b.chargeCounterMah) ? "N/A"
                : String.format(Locale.US, "%.0f mAh", b.chargeCounterMah);
        double activeCur = !Double.isNaN(b.currentNowMa) ? b.currentNowMa : b.currentAverageMa;
        String currentFlow = Double.isNaN(activeCur) ? "N/A"
                : String.format(Locale.US, "%.0f mA", activeCur);

        batterySection.summary.setText((b.level >= 0 ? b.level + "%" : "N/A")
                + " (" + b.status + ") • Health " + health
                + " • Cycles " + b.cycleCount + " • " + temp + " • " + voltage);
        batteryText.setText(
                "Checkmk Row      : 1 Baris Terpadu (Health_Battery)\n"
                        + "Level / Status   : " + (b.level >= 0 ? b.level + "%" : "N/A") + " (" + b.status + ")\n"
                        + "Real Health      : " + health + "\n"
                        + "Charging Cycles  : " + b.cycleCount + " (" + b.chargeSessions + "x sesi, "
                        + Math.round(b.totalChargedMah) + " mAh terakumulasi)\n"
                        + "Full Capacity    : " + full + " (Acuan 100% Charge = 2946 mAh)\n"
                        + "Design Spec      : " + design + " (" + b.designCapacitySource + ")\n"
                        + "Current Charge   : " + chargeNow + "\n"
                        + "Temperature      : " + temp + "\n"
                        + "Voltage          : " + voltage + "\n"
                        + "Electric Current : " + currentFlow + "\n"
                        + "Calculation      : " + b.fullCapacitySource
        );

        systemSection.summary.setText("RAM " + Math.round(ram.usedPercent) + "%  •  Storage "
                + Math.round(storage.usedPercent) + "%");
        systemText.setText(
                "RAM      : " + Math.round(ram.usedPercent) + "% used (Cache 30m)\n"
                        + "Storage  : " + Math.round(storage.usedPercent) + "% used (Cache 1d)\n"
                        + "Free RAM : " + DeviceMetrics.fmt2(ram.freeGb) + " GB / " + DeviceMetrics.fmt2(ram.totalGb) + " GB\n"
                        + "Free ROM : " + DeviceMetrics.fmt2(storage.freeGb) + " GB / " + DeviceMetrics.fmt2(storage.totalGb) + " GB"
        );

        String rssi = wifi.rssi == Integer.MIN_VALUE ? "N/A" : wifi.rssi + " dBm";
        String speed = wifi.linkSpeedMbps < 0 ? "N/A" : wifi.linkSpeedMbps + " Mbps";
        String freq = wifi.frequencyMhz < 0 ? "N/A" : wifi.frequencyMhz + " MHz";
        String nearbyPermission = permissionState(Manifest.permission.NEARBY_WIFI_DEVICES, 33);
        String locationPermission = permissionState(Manifest.permission.ACCESS_FINE_LOCATION, 23);
        String locationService = isLocationEnabled() ? "ON" : "OFF";
        boolean ignoringBatteryOpt = isIgnoringBatteryOptimizations();

        String pingLocalSummary = String.format(Locale.US, "%d/60m (%d pkt) • Loss %.1f%% • Avg %s",
                pingLocal.windowSamples, pingLocal.windowTx, pingLocal.windowLossPercent,
                Double.isNaN(pingLocal.windowAvgMs) ? "N/A" : String.format(Locale.US, "%.1f ms", pingLocal.windowAvgMs));
        String pingNetSummary = String.format(Locale.US, "%d/60m (%d pkt) • Loss %.1f%% • Avg %s",
                pingNet.windowSamples, pingNet.windowTx, pingNet.windowLossPercent,
                Double.isNaN(pingNet.windowAvgMs) ? "N/A" : String.format(Locale.US, "%.1f ms", pingNet.windowAvgMs));
        String gwIp = AgentConfig.getGatewayIp(this);
        String pingGwSummary = !AgentConfig.isValidIpv4(gwIp)
                ? "Belum dikonfigurasi (Isi di Settings)"
                : String.format(Locale.US, "%d/60m (%d pkt) • Loss %.1f%% • Avg %s",
                        pingGw.windowSamples, pingGw.windowTx, pingGw.windowLossPercent,
                        Double.isNaN(pingGw.windowAvgMs) ? "N/A" : String.format(Locale.US, "%.1f ms", pingGw.windowAvgMs));

        networkSection.summary.setText((wifi.connected ? wifi.ssid : "Not Connected")
                + " • " + rssi + " • Roam " + wifi.roamsLastHour + "x/1h");
        networkText.setText(
                "Wi-Fi          : " + (wifi.connected ? "Connected" : "Not Connected") + "\n"
                        + "SSID           : " + wifi.ssid + "\n"
                        + "AP BSSID       : " + wifi.bssid + " (" + wifi.apVendor + ")\n"
                        + "Band / Channel : " + wifi.bandChannel + " (" + freq + ")\n"
                        + "AP Roaming     : " + wifi.roamSummary + "\n"
                        + "Last Roam Move : " + wifi.lastRoamReason + "\n"
                        + "Signal / Speed : " + rssi + "  •  " + speed + "\n"
                        + "Local IP       : " + wifi.ip + "\n"
                        + "Ping 192.168.122.10 : " + pingLocalSummary + "\n"
                        + "Ping 8.8.8.8        : " + pingNetSummary + "\n"
                        + "Ping Gateway (" + AgentConfig.getGatewayIpDisplay(this) + ") : " + pingGwSummary + "\n"
                        + "Ping Schedule  : 4x tiap 1 menit -> kirim Checkmk tiap 1 jam\n"
                        + "Ping Retention : 30 Hari (Auto-hapus hari ke-31+ seperti CCTV)\n"
                        + "Ping Log Path  : " + pingLocal.logFilePath + "\n"
                        + "Fine Location  : " + locationPermission + " (Loc Service: " + locationService + ")\n"
                        + "Nearby Wi-Fi   : " + nearbyPermission + "\n"
                        + "Battery Opt    : " + (ignoringBatteryOpt ? "Unrestricted (Safe)" : "Optimized (Risk of sleep)")
        );

        appsSection.summary.setText(apps.totalApps + " Apps  •  " + apps.userApps + " User  •  HW/SW Ready");
        appsText.setText(
                "Total Packages : " + apps.totalApps + "\n"
                        + "User Installed : " + apps.userApps + "\n"
                        + "System Apps    : " + apps.systemApps + "\n"
                        + "Checkmk Format : lnx_packages / inv_packages\n"
                        + "Payload Status : Ready for HW/SW Inventory pull\n"
                        + "Schedule       : Weekly on Sundays (Instant on 1st pull)"
        );

        deviceSection.summary.setText(device.manufacturer + " " + device.model
                + "  •  Android " + device.androidVersion);
        deviceText.setText(
                "Manufacturer : " + device.manufacturer + "\n"
                        + "Model        : " + device.model + "\n"
                        + "Profile      : " + device.profile + "\n"
                        + "Hardware     : " + device.hardwareSoc + " (" + device.board + ")\n"
                        + "Architecture : " + device.arch + "\n"
                        + "Kernel       : " + device.kernelVersion + "\n"
                        + "Android      : " + device.androidVersion + " (SDK " + device.sdk + ")\n"
                        + "Device uptime: " + CheckmkOutput.formatDuration(device.uptimeMs)
        );

        settingsSection.summary.setText(AgentConfig.getHostname(this) + "  •  Server "
                + allowDisplay + "  •  GW " + AgentConfig.getGatewayIpDisplay(this) + "  •  TCP " + AgentConfig.getPort(this));

        diagnosticsSection.summary.setText("Pulls " + stats.accepted + "  •  Rejected "
                + stats.rejected + "  •  Push OK " + stats.pushSuccesses);
        diagnosticsText.setText(
                "Accepted pulls : " + stats.accepted + "\n"
                        + "Rejected pulls : " + stats.rejected + "\n"
                        + "Last rejected  : " + stats.lastRejected + "\n"
                        + "Server Cabang  : " + allowDisplay + "\n"
                        + "Push attempts  : " + stats.pushAttempts + "\n"
                        + "Push successes : " + stats.pushSuccesses + "\n"
                        + "Push failures  : " + stats.pushFailures + "\n"
                        + "Last push code : " + stats.lastPushCode + "\n"
                        + "Last push msg  : " + stats.lastPushMessage + "\n"
                        + "Foreground svc : " + (stats.running ? "running" : "stopped") + "\n"
                        + "AccuMeter smpl : " + b.estimateSamples + "\n"
                        + "Package        : com.bcp.checkmkagent"
        );
    }

    private TextView ensureTransportBody() {
        if (transportSection.content.getChildCount() >= 2
                && transportSection.content.getChildAt(1) instanceof TextView) {
            return (TextView) transportSection.content.getChildAt(1);
        }
        TextView body = bodyText();
        body.setPadding(0, dp(10), 0, 0);
        transportSection.content.addView(body, wrap());
        return body;
    }

    private void showPingLogDialog() {
        showTextDialog("Log Ping Lokal 3-Baris (Retensi 30 Hari CCTV)",
                PingMonitor.readRecentLogTail(this, 120),
                "PING 4X NOW",
                () -> {
                    Toast.makeText(this, "Menjalankan ping 4x ke 192.168.122.10, 8.8.8.8, & Gateway Cabang...", Toast.LENGTH_SHORT).show();
                    new Thread(() -> {
                        PingMonitor.collectMinuteSample(getApplicationContext());
                        runOnUiThread(() -> {
                            updateDashboard();
                            Toast.makeText(this, "Sampel ping 4x berhasil disimpan ke log HP", Toast.LENGTH_SHORT).show();
                        });
                    }, "cmkagent-manual-ping").start();
                });
    }

    private void showRoamingLogDialog() {
        showTextDialog("Log Roaming Wi-Fi AP (UniFi / Multi-AP)",
                WifiRoamingTracker.readRecentRoamLog(this, 100),
                null,
                null);
    }

    private void showTextDialog(String title, String content, String neutralLabel, Runnable neutralAction) {
        TextView text = new TextView(this);
        text.setText(content);
        text.setTextIsSelectable(true);
        text.setTypeface(Typeface.MONOSPACE);
        text.setTextColor(C_TEXT);
        text.setTextSize(11);
        text.setPadding(dp(16), dp(16), dp(16), dp(16));
        text.setBackgroundColor(C_BG);

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(C_BG);
        scroller.addView(text);

        AlertDialog.Builder builder = new AlertDialog.Builder(this)
                .setTitle(title)
                .setView(scroller)
                .setPositiveButton("CLOSE", null);
        if (neutralLabel != null && neutralAction != null) {
            builder.setNeutralButton(neutralLabel, (d, w) -> neutralAction.run());
        }
        AlertDialog dialog = builder.create();
        dialog.setOnShowListener(d -> {
            if (dialog.getButton(AlertDialog.BUTTON_POSITIVE) != null) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(C_GREEN);
            }
            if (dialog.getButton(AlertDialog.BUTTON_NEUTRAL) != null) {
                dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setTextColor(C_WARN);
            }
        });
        dialog.show();
    }

    private void testPushNow() {
        if (!saveConfigOnly()) return;
        if (!AgentConfig.isPushConfigured(this)) {
            Toast.makeText(this, "Isi Push Receiver URL dan aktifkan PUSH backup terlebih dahulu", Toast.LENGTH_LONG).show();
            return;
        }
        Toast.makeText(this, "Mengirim test push...", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            PushClient.Result result = PushClient.pushNow(getApplicationContext());
            runOnUiThread(() -> {
                Toast.makeText(this, result.ok
                        ? "Push OK (HTTP " + result.code + ")"
                        : "Push gagal: " + result.message, Toast.LENGTH_LONG).show();
                updateDashboard();
            });
        }, "cmkagent-test-push").start();
    }

    private void showAgentOutput() {
        if (!saveConfigOnly()) return;
        showTextDialog("Checkmk agent output", CheckmkOutput.build(this), null, null);
        updateDashboard();
    }

    private void requestRuntimePermissionsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        List<String> needed = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.NEARBY_WIFI_DEVICES);
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (!needed.isEmpty()) requestPermissions(needed.toArray(new String[0]), 1001);
    }

    private String permissionState(String permission, int minSdk) {
        if (Build.VERSION.SDK_INT < minSdk) return "N/A";
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
                ? "Granted" : "Denied";
    }

    private boolean isLocationEnabled() {
        try {
            LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
            if (lm == null) return false;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return lm.isLocationEnabled();
            return lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
                    || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
        } catch (Exception ignored) {
            return false;
        }
    }

    private boolean isIgnoringBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
        }
        return true;
    }

    private void requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } catch (Exception e) {
                openAppSettings();
            }
        }
    }

    private void openAppSettings() {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName()));
        startActivity(intent);
    }

    private EditText input(LinearLayout parent, String label, int type, String hint) {
        TextView l = new TextView(this);
        l.setText(label);
        l.setTextColor(C_MUTED);
        l.setTextSize(12);
        l.setTypeface(Typeface.DEFAULT_BOLD);
        l.setPadding(0, dp(6), 0, dp(3));
        parent.addView(l, wrap());

        EditText e = new EditText(this);
        e.setSingleLine(true);
        e.setInputType(type);
        e.setTextColor(C_TEXT);
        e.setHintTextColor(Color.rgb(102, 119, 133));
        e.setHint(hint);
        e.setTextSize(15);
        e.setPadding(dp(12), 0, dp(12), 0);
        e.setBackground(rounded(C_CARD_ALT, 10, C_LINE, 1));
        parent.addView(e, matchHeightMargin(48, 0, 0, 0, 8));
        return e;
    }

    private TextView bodyText() {
        TextView v = new TextView(this);
        v.setTextColor(C_TEXT);
        v.setTextSize(14);
        v.setLineSpacing(0, 1.15f);
        return v;
    }

    private TextView badge(String text, int color) {
        TextView v = new TextView(this);
        v.setText(text);
        v.setTextSize(12);
        v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setPadding(dp(10), dp(5), dp(10), dp(5));
        styleBadge(v, color);
        return v;
    }

    private void styleBadge(TextView v, int color) {
        v.setTextColor(color);
        v.setBackground(rounded(withAlpha(color, 35), 20, withAlpha(color, 110), 1));
    }

    private Button actionButton(String text, int bg, int fg) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(fg);
        b.setTextSize(12);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setBackground(rounded(bg, 11, C_LINE, 1));
        return b;
    }

    private GradientDrawable rounded(int color, int radiusDp, int strokeColor, int strokeDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        if (strokeDp > 0) d.setStroke(dp(strokeDp), strokeColor);
        return d;
    }

    private int withAlpha(int color, int alpha) {
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color));
    }

    private View space(int heightDp) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(heightDp)));
        return v;
    }

    private LinearLayout.LayoutParams wrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchWrapMargin(int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams p = matchWrap();
        p.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return p;
    }

    private LinearLayout.LayoutParams matchHeightMargin(
            int height, int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(height));
        p.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return p;
    }

    private LinearLayout.LayoutParams weightButton() {
        return new LinearLayout.LayoutParams(0, dp(48), 1f);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String formatDate(long millis) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
                .format(new Date(millis));
    }

    private static final class Section {
        LinearLayout card;
        LinearLayout content;
        TextView arrow;
        TextView summary;
        boolean expanded;
    }
}
