package com.bcp.checkmkagent;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final int BG_DARK = Color.parseColor("#0D1518");
    private static final int CARD_BG = Color.parseColor("#131F24");
    private static final int CARD_BORDER = Color.parseColor("#233740");
    private static final int ACCENT_GREEN = Color.parseColor("#35D07F");
    private static final int ACCENT_RED = Color.parseColor("#EF5350");
    private static final int TEXT_PRIMARY = Color.parseColor("#E8F0F2");
    private static final int TEXT_MUTED = Color.parseColor("#8FA3AD");

    private final Handler uiHandler = new Handler(Looper.getMainLooper());
    private final List<CollapsibleCard> allCards = new ArrayList<>();
    private AgentConfig cfg;

    private Button btnStartTop, btnStopTop;

    private TextView txtAgentBadge;
    private TextView txtAgentSubtitle;
    private TextView txtAgentDetails;

    private TextView txtTransportSummary;
    private TextView txtTransportDetails;

    private TextView txtBatterySummary;
    private TextView txtBatteryDetails;

    private TextView txtSystemSummary;
    private TextView txtSystemDetails;

    private TextView txtWifiSummary;
    private TextView txtWifiPingDetails;
    private Button btnFixWifiLocation;

    private TextView txtAppsSummary;
    private TextView txtAppsDetails;

    private TextView txtDeviceSummary;
    private TextView txtDeviceDetails;

    private TextView txtSettingsSummary;

    private EditText edtHostname, edtAllowed, edtGateway, edtDesignMah, edtInitCycles;
    private EditText edtPushUrl, edtPushToken, edtPushInterval;
    private Switch swAllowPrivate, swPushEnabled;

    private static class CollapsibleCard {
        final LinearLayout cardRoot;
        final LinearLayout bodyLayout;
        final TextView chevronView;
        boolean expanded;

        CollapsibleCard(LinearLayout cardRoot, LinearLayout bodyLayout, TextView chevronView, boolean initialExpanded) {
            this.cardRoot = cardRoot;
            this.bodyLayout = bodyLayout;
            this.chevronView = chevronView;
            setExpanded(initialExpanded);
        }

        void setExpanded(boolean exp) {
            this.expanded = exp;
            this.bodyLayout.setVisibility(exp ? View.VISIBLE : View.GONE);
            this.chevronView.setText(exp ? "▾" : "▸");
        }

        void toggle() {
            setExpanded(!this.expanded);
        }
    }

    private final Runnable refreshTask = new Runnable() {
        @Override
        public void run() {
            refreshDashboard();
            uiHandler.postDelayed(this, 3000L);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        cfg = new AgentConfig(this);
        buildUi();
        requestNeededPermissions();
        startAgentService(CheckmkAgentService.ACTION_START_OR_RELOAD);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshDashboard();
        uiHandler.post(refreshTask);
    }

    @Override
    protected void onPause() {
        uiHandler.removeCallbacks(refreshTask);
        super.onPause();
    }

    private void buildUi() {
        allCards.clear();
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG_DARK);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(14), dp(14), dp(14), dp(24));
        scroll.addView(root);

        // Header Row (Shield Badge + Title)
        LinearLayout headerRow = new LinearLayout(this);
        headerRow.setOrientation(LinearLayout.HORIZONTAL);
        headerRow.setGravity(Gravity.CENTER_VERTICAL);
        headerRow.setPadding(0, 0, 0, dp(10));

        ImageView iconBadge = new ImageView(this);
        iconBadge.setImageResource(R.mipmap.ic_launcher);
        iconBadge.setScaleType(ImageView.ScaleType.FIT_CENTER);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(dp(42), dp(42));
        iconLp.rightMargin = dp(12);
        headerRow.addView(iconBadge, iconLp);

        LinearLayout titleCol = new LinearLayout(this);
        titleCol.setOrientation(LinearLayout.VERTICAL);

        TextView title = new TextView(this);
        title.setText("BMS Agent");
        title.setTextColor(TEXT_PRIMARY);
        title.setTextSize(22);
        title.setTypeface(null, Typeface.BOLD);
        titleCol.addView(title);

        TextView sub = new TextView(this);
        sub.setText("BMS Agent 1.3.8  •  Android");
        sub.setTextColor(TEXT_MUTED);
        sub.setTextSize(12);
        titleCol.addView(sub);

        headerRow.addView(titleCol);
        root.addView(headerRow);

        // Top Bar 1: EXPAND ALL / COLLAPSE ALL
        LinearLayout expandCollapseRow = new LinearLayout(this);
        expandCollapseRow.setOrientation(LinearLayout.HORIZONTAL);
        expandCollapseRow.setPadding(0, 0, 0, dp(8));

        Button btnExpandAll = makeTopBarButton("EXPAND ALL", TEXT_PRIMARY, "#131F24", "#233740");
        btnExpandAll.setOnClickListener(v -> {
            for (CollapsibleCard c : allCards) c.setExpanded(true);
        });
        Button btnCollapseAll = makeTopBarButton("COLLAPSE ALL", TEXT_PRIMARY, "#131F24", "#233740");
        btnCollapseAll.setOnClickListener(v -> {
            for (CollapsibleCard c : allCards) c.setExpanded(false);
        });

        expandCollapseRow.addView(btnExpandAll, new LinearLayout.LayoutParams(0, dp(38), 1f));
        View sp1 = new View(this);
        expandCollapseRow.addView(sp1, new LinearLayout.LayoutParams(dp(8), 1));
        expandCollapseRow.addView(btnCollapseAll, new LinearLayout.LayoutParams(0, dp(38), 1f));
        root.addView(expandCollapseRow);

        // Top Bar 2: START AGENT / STOP AGENT
        LinearLayout startStopRow = new LinearLayout(this);
        startStopRow.setOrientation(LinearLayout.HORIZONTAL);
        startStopRow.setPadding(0, 0, 0, dp(12));

        btnStartTop = makeTopBarButton("▶ START AGENT", ACCENT_GREEN, "#123828", "#35D07F");
        btnStartTop.setOnClickListener(v -> handleStartAgent());

        btnStopTop = makeTopBarButton("■ STOP AGENT", ACCENT_RED, "#3A1818", "#EF5350");
        btnStopTop.setOnClickListener(v -> handleStopAgent());

        startStopRow.addView(btnStartTop, new LinearLayout.LayoutParams(0, dp(38), 1f));
        View sp2 = new View(this);
        startStopRow.addView(sp2, new LinearLayout.LayoutParams(dp(8), 1));
        startStopRow.addView(btnStopTop, new LinearLayout.LayoutParams(0, dp(38), 1f));
        root.addView(startStopRow);

        if (!NativeBridge.isLoaded()) {
            TextView err = new TextView(this);
            err.setText("Native JNI Error: " + NativeBridge.getLoadError());
            err.setTextColor(ACCENT_RED);
            err.setPadding(0, 0, 0, dp(10));
            root.addView(err);
        }

        // Card 1: AGENT (default expanded = true)
        txtAgentSubtitle = makeSummaryText("");
        CollapsibleCard cAgent = createCollapsibleCard(
                root,
                "AGENT",
                "Pull listener & firewall status",
                txtAgentSubtitle,
                true
        );

        txtAgentBadge = new TextView(this);
        txtAgentBadge.setTextSize(11);
        txtAgentBadge.setTypeface(null, Typeface.BOLD);
        txtAgentBadge.setPadding(dp(10), dp(4), dp(10), dp(4));
        LinearLayout.LayoutParams badgeLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        badgeLp.topMargin = dp(6);
        badgeLp.bottomMargin = dp(8);
        txtAgentBadge.setLayoutParams(badgeLp);
        cAgent.bodyLayout.addView(txtAgentBadge);

        txtAgentDetails = makeMonoText("");
        cAgent.bodyLayout.addView(txtAgentDetails);

        LinearLayout agentBtns = new LinearLayout(this);
        agentBtns.setOrientation(LinearLayout.HORIZONTAL);
        agentBtns.setPadding(0, dp(10), 0, 0);
        Button btnStartCard = makeActionButton("START SERVICE");
        btnStartCard.setOnClickListener(v -> handleStartAgent());
        Button btnStopCard = makeDangerButton("STOP SERVICE");
        btnStopCard.setOnClickListener(v -> handleStopAgent());
        agentBtns.addView(btnStartCard, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        View spAgent = new View(this);
        agentBtns.addView(spAgent, new LinearLayout.LayoutParams(dp(8), 1));
        agentBtns.addView(btnStopCard, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        cAgent.bodyLayout.addView(agentBtns);

        // Card 2: HYBRID TRANSPORT (default collapsed = false)
        txtTransportSummary = makeSummaryText("");
        CollapsibleCard cTrans = createCollapsibleCard(
                root,
                "HYBRID TRANSPORT",
                "Pull primary + push warm backup",
                txtTransportSummary,
                false
        );
        txtTransportDetails = makeMonoText("");
        cTrans.bodyLayout.addView(txtTransportDetails);
        Button btnPushNow = makeActionButton("PUSH SNAPSHOT NOW");
        btnPushNow.setOnClickListener(v -> {
            startAgentService(CheckmkAgentService.ACTION_PUSH_NOW);
            Toast.makeText(this, "Mengirim push snapshot ke server...", Toast.LENGTH_SHORT).show();
        });
        LinearLayout.LayoutParams pushBtnLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        pushBtnLp.topMargin = dp(8);
        cTrans.bodyLayout.addView(btnPushNow, pushBtnLp);

        // Card 3: BATTERY (1-LINE UNIFIED) (default collapsed = false)
        txtBatterySummary = makeSummaryText("");
        CollapsibleCard cBat = createCollapsibleCard(
                root,
                "BATTERY (1-LINE UNIFIED)",
                "Health, cycles, temp, volt & current",
                txtBatterySummary,
                false
        );
        txtBatteryDetails = makeMonoText("");
        cBat.bodyLayout.addView(txtBatteryDetails);

        // Card 4: SYSTEM (default collapsed = false)
        txtSystemSummary = makeSummaryText("");
        CollapsibleCard cSys = createCollapsibleCard(
                root,
                "SYSTEM",
                "RAM & internal storage",
                txtSystemSummary,
                false
        );
        txtSystemDetails = makeMonoText("");
        cSys.bodyLayout.addView(txtSystemDetails);

        // Card 5: NETWORK, AP ROAMING & PING (1H) (default expanded = true)
        txtWifiSummary = makeSummaryText("");
        CollapsibleCard cNet = createCollapsibleCard(
                root,
                "NETWORK, AP ROAMING & PING (1H)",
                "Wi-Fi UniFi/AP roaming & 4x/1m ping (30d CCTV log)",
                txtWifiSummary,
                true
        );
        txtWifiPingDetails = makeMonoText("");
        cNet.bodyLayout.addView(txtWifiPingDetails);

        btnFixWifiLocation = makeDangerButton("⚠ IZINKAN LOKASI AKURAT (AGAR SSID & AP TAMPIL)");
        btnFixWifiLocation.setVisibility(View.GONE);
        btnFixWifiLocation.setOnClickListener(v -> handleFixWifiLocation());
        LinearLayout.LayoutParams fixLocLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        fixLocLp.topMargin = dp(8);
        cNet.bodyLayout.addView(btnFixWifiLocation, fixLocLp);

        LinearLayout netBtns = new LinearLayout(this);
        netBtns.setOrientation(LinearLayout.HORIZONTAL);
        netBtns.setPadding(0, dp(10), 0, 0);
        Button btnLog = makeActionButton("VIEW PING LOG");
        btnLog.setOnClickListener(v -> showPingLogDialog());
        Button btnCsv = makeActionButton("TRAFFIC CSV");
        btnCsv.setOnClickListener(v -> showTrafficCsvDialog());
        Button btnPingNow = makeActionButton("PING 4X NOW");
        btnPingNow.setOnClickListener(v -> {
            startAgentService(CheckmkAgentService.ACTION_PING_NOW);
            Toast.makeText(this, "Ping 4x ke 3 target sedang berjalan...", Toast.LENGTH_SHORT).show();
        });
        netBtns.addView(btnLog, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        View spacer = new View(this);
        netBtns.addView(spacer, new LinearLayout.LayoutParams(dp(6), 1));
        netBtns.addView(btnCsv, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        View spacer2 = new View(this);
        netBtns.addView(spacer2, new LinearLayout.LayoutParams(dp(6), 1));
        netBtns.addView(btnPingNow, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        cNet.bodyLayout.addView(netBtns);

        // Card 6: APPLICATIONS (default collapsed = false)
        txtAppsSummary = makeSummaryText("");
        CollapsibleCard cApps = createCollapsibleCard(
                root,
                "APPLICATIONS",
                "Installed Android packages & HW/SW inventory",
                txtAppsSummary,
                false
        );
        txtAppsDetails = makeMonoText("");
        cApps.bodyLayout.addView(txtAppsDetails);

        // Card 7: DEVICE (default collapsed = false)
        txtDeviceSummary = makeSummaryText("");
        CollapsibleCard cDev = createCollapsibleCard(
                root,
                "DEVICE",
                "Hardware & Android profile",
                txtDeviceSummary,
                false
        );
        txtDeviceDetails = makeMonoText("");
        cDev.bodyLayout.addView(txtDeviceDetails);

        // Card 8: SETTINGS (default collapsed = false)
        txtSettingsSummary = makeSummaryText("");
        CollapsibleCard cSet = createCollapsibleCard(
                root,
                "SETTINGS",
                "Tap to configure agent & IP Server Checkmk Cabang",
                txtSettingsSummary,
                false
        );

        edtHostname = addSettingField(cSet.bodyLayout, "Hostname Checkmk", cfg.getHostname(), InputType.TYPE_CLASS_TEXT);

        swAllowPrivate = new Switch(this);
        swAllowPrivate.setText("Izinkan semua IP (Open — sama seperti agen bawaan Checkmk)");
        swAllowPrivate.setTextColor(TEXT_PRIMARY);
        swAllowPrivate.setChecked(cfg.isAllowAllPrivate());
        swAllowPrivate.setPadding(0, dp(8), 0, dp(8));
        cSet.bodyLayout.addView(swAllowPrivate);

        edtAllowed = addSettingField(cSet.bodyLayout, "IP Server Checkmk Cabang (kosong = semua IP jika Open aktif)",
                cfg.getAllowedServersRaw(), InputType.TYPE_CLASS_TEXT);
        edtGateway = addSettingField(cSet.bodyLayout, "IP Gateway Cabang (Ping Monitor Baris ke-3)",
                cfg.getConfiguredGatewayIp(), InputType.TYPE_CLASS_TEXT);

        Button btnDetectGw = makeActionButton("AUTO-DETECT GATEWAY DARI WI-FI");
        btnDetectGw.setOnClickListener(v -> {
            String gw = AgentConfig.detectWifiGateway(this);
            edtGateway.setText(gw);
            Toast.makeText(this, gw.isEmpty() ? "Gateway tidak terdeteksi" : "Gateway: " + gw, Toast.LENGTH_SHORT).show();
        });
        LinearLayout.LayoutParams gwBtnLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        gwBtnLp.topMargin = dp(6);
        cSet.bodyLayout.addView(btnDetectGw, gwBtnLp);

        edtDesignMah = addSettingField(cSet.bodyLayout, "Design Capacity (mAh, 0 = auto)",
                String.valueOf(cfg.getBatteryDesignMahOverride()), InputType.TYPE_CLASS_NUMBER);
        edtInitCycles = addSettingField(cSet.bodyLayout, "Initial Battery Cycles (0 = auto hitung dari pengisian)",
                String.valueOf(cfg.getInitialBatteryCycles()), InputType.TYPE_CLASS_NUMBER);

        swPushEnabled = new Switch(this);
        swPushEnabled.setText("Aktifkan PUSH backup (Hybrid)");
        swPushEnabled.setTextColor(TEXT_PRIMARY);
        swPushEnabled.setChecked(cfg.isPushEnabled());
        swPushEnabled.setPadding(0, dp(8), 0, dp(8));
        cSet.bodyLayout.addView(swPushEnabled);

        edtPushUrl = addSettingField(cSet.bodyLayout, "Push Receiver URL", cfg.getPushUrl(), InputType.TYPE_TEXT_VARIATION_URI);
        edtPushToken = addSettingField(cSet.bodyLayout, "Push Token", cfg.getPushToken(), InputType.TYPE_CLASS_TEXT);
        edtPushInterval = addSettingField(cSet.bodyLayout, "Push Interval (detik, minimal 60)",
                String.valueOf(cfg.getPushIntervalSec()), InputType.TYPE_CLASS_NUMBER);

        Button btnSave = makeActionButton("SIMPAN & RELOAD RUST AGENT");
        btnSave.setOnClickListener(v -> saveSettings());
        LinearLayout.LayoutParams saveLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        saveLp.topMargin = dp(12);
        cSet.bodyLayout.addView(btnSave, saveLp);

        setContentView(scroll);
    }

    private void handleStartAgent() {
        startAgentService(CheckmkAgentService.ACTION_START_OR_RELOAD);
        uiHandler.postDelayed(this::refreshDashboard, 250L);
        Toast.makeText(this, "BMS Agent Service dijalankan", Toast.LENGTH_SHORT).show();
    }

    private void handleStopAgent() {
        Intent svc = new Intent(this, CheckmkAgentService.class);
        svc.setAction(CheckmkAgentService.ACTION_STOP_SERVICE);
        startService(svc);
        uiHandler.postDelayed(this::refreshDashboard, 250L);
        Toast.makeText(this, "Agent Service dihentikan.", Toast.LENGTH_SHORT).show();
    }

    private void refreshDashboard() {
        String ip = AgentConfig.getDeviceIpv4(this);
        String gw = cfg.getGatewayIp();
        boolean isRunning = CheckmkAgentService.isRunning();

        // Update Top Start/Stop Buttons visual state
        btnStartTop.setAlpha(isRunning ? 0.55f : 1.0f);
        btnStopTop.setAlpha(isRunning ? 1.0f : 0.55f);

        txtAgentSubtitle.setText(String.format(Locale.US, "%s  •  %s  •  %s",
                isRunning ? "RUNNING" : "STOPPED", cfg.getHostname(), ip));

        GradientDrawable badgeBg = new GradientDrawable();
        badgeBg.setCornerRadius(dp(12));
        badgeBg.setColor(Color.parseColor(isRunning ? "#123828" : "#3A1818"));
        badgeBg.setStroke(dp(1), isRunning ? ACCENT_GREEN : ACCENT_RED);
        txtAgentBadge.setBackground(badgeBg);
        txtAgentBadge.setTextColor(isRunning ? ACCENT_GREEN : ACCENT_RED);
        txtAgentBadge.setText(isRunning ? "● AGENT RUNNING" : "● AGENT STOPPED");

        String lastPull = "N/A";
        String lastClient = "N/A";
        long connCount = 0;
        long rejCount = 0;
        String lastPushAt = "N/A";
        String lastPushRes = "Push backup not configured";
        long pushOk = 0;
        long pushFail = 0;
        String pushDesc = cfg.isPushEnabled()
                ? "PUSH ENABLED (" + cfg.getPushIntervalSec() + "s)"
                : "PUSH NOT CONFIGURED";

        if (NativeBridge.isLoaded()) {
            try {
                JSONObject st = new JSONObject(NativeBridge.getStatsJson());
                lastPull = st.optString("last_pull_str", "N/A");
                lastClient = st.optString("last_client_ip", "");
                if (lastClient.isEmpty()) lastClient = "N/A";
                connCount = st.optLong("accepted_connections", 0);
                rejCount = st.optLong("rejected_connections", 0);
                pushOk = st.optLong("push_success_count", 0);
                pushFail = st.optLong("push_failure_count", 0);
                lastPushAt = st.optString("last_push_str", "N/A");
                String r = st.optString("last_push_result", "");
                if (!r.isEmpty()) lastPushRes = r;
                if (cfg.isPushEnabled()) {
                    pushDesc = String.format(Locale.US, "PUSH OK:%d FAIL:%d", pushOk, pushFail);
                }
            } catch (Throwable ignored) {}
        }

        String listenMode = cfg.isAllowAllPrivate() ? "Open" : "Restricted";
        String allowedSrv = cfg.getAllowedServersRaw().trim().isEmpty() ? "Open" : cfg.getAllowedServersRaw();
        txtAgentDetails.setText(String.format(Locale.US,
                "Hostname     : %s\nVersion      : Agen BMS : 1.3.8\nAccess       : %s\nDevice IP    : %s\nLast pull    : %s\nLast client  : %s\nServer Cabang: %s\nPulls / Rej  : %d / %d\nMode         : HYBRID (PULL primary + PUSH backup)",
                cfg.getHostname(), listenMode, ip,
                lastPull, lastClient, allowedSrv, connCount, rejCount));

        txtTransportSummary.setText(String.format(Locale.US,
                "PULL primary  •  %s  •  %ds",
                pushDesc, cfg.getPushIntervalSec()));
        txtTransportDetails.setText(String.format(Locale.US,
                "Primary      : PULL\nBackup       : PUSH HTTP(S)\nReceiver URL : %s\nPush Interval: %d sec\nLast Push    : %s\nPush Stats   : OK %d / Fail %d\nLast Result  : %s",
                cfg.getPushUrl().isEmpty() ? "Not configured" : cfg.getPushUrl(),
                cfg.getPushIntervalSec(),
                lastPushAt, pushOk, pushFail, lastPushRes));

        DeviceMetrics.BatterySnapshot bs = DeviceMetrics.readBattery(this, cfg);
        txtBatterySummary.setText(String.format(Locale.US,
                "%d%% (%s)  •  Health %.1f%%  •  Cycles %d  •  %.1f C  •  %.2f V",
                bs.levelPct, bs.statusText, bs.healthPct, bs.cycles, bs.tempC, bs.voltageV));
        txtBatteryDetails.setText(String.format(Locale.US,
                "Status       : %s (%d%%)\nReal Health  : %.1f%%\nCycles       : %d\nFull Capacity: %.0f mAh\nDesign Spec  : %.0f mAh\nTemperature  : %.1f C\nVoltage      : %.2f V\nCurrent Now  : %d mA\nCalculation  : %s",
                bs.statusText, bs.levelPct, bs.healthPct, bs.cycles,
                bs.estFullMah, bs.designMah, bs.tempC, bs.voltageV, bs.currentMa, bs.calcMethod));

        DeviceMetrics.RamStorageSnapshot rs = DeviceMetrics.readRamStorage(this);
        txtSystemSummary.setText(String.format(Locale.US,
                "RAM %d%%  •  Storage %d%%",
                rs.ramPct, rs.storagePct));
        txtSystemDetails.setText(String.format(Locale.US,
                "RAM Usage    : %d%% (%.2f GB used / %.2f GB free / %.2f GB total)\nInternal Disk: %d%% (%.2f GB used / %.2f GB free / %.2f GB total)",
                rs.ramPct, rs.ramUsedGb, rs.ramFreeGb, rs.ramTotalGb,
                rs.storagePct, rs.storageUsedGb, rs.storageFreeGb, rs.storageTotalGb));

        DeviceMetrics.WifiSnapshot ws = DeviceMetrics.readWifi(this);
        DeviceMetrics.NetworkTrafficSnapshot nt = DeviceMetrics.peekNetworkTraffic(this);
        txtWifiSummary.setText(String.format(Locale.US,
                "%s  •  %d dBm  •  Roam %dx/1h",
                ws.ssid, ws.rssiDbm, ws.roam1h));
        txtWifiPingDetails.setText(String.format(Locale.US,
                "Wi-Fi        : %s\nSSID         : %s\nAP BSSID     : %s (%s)\nBand / Ch    : %s\nAP Roaming   : %dx/1h (Total %dx)\nLast Roam    : %s\nSignal/Speed : %d dBm  •  %d Mbps\nLocal IP     : %s\nTraffic DL/UL: %s (%s) / %s (%s)\nTraffic CSV  : %s\nPing Target 1: 192.168.122.10 (Server Lokal)\nPing Target 2: 8.8.8.8 (Internet)\nPing Target 3: %s (Gateway Cabang)",
                ws.status, ws.ssid, ws.bssid, ws.vendor, ws.bandChannel,
                ws.roam1h, ws.roamTotal, ws.lastRoam, ws.rssiDbm, ws.linkSpeedMbps,
                ws.ip, nt.rxTotalHuman, nt.rxRateHuman, nt.txTotalHuman, nt.txRateHuman,
                DeviceMetrics.TRAFFIC_CSV_FILE, gw.isEmpty() ? "(auto)" : gw));

        if (btnFixWifiLocation != null) {
            boolean fineGranted = DeviceMetrics.hasFineLocationPermission(this);
            boolean gpsEnabled = DeviceMetrics.isLocationServiceEnabled(this);
            if (!fineGranted) {
                btnFixWifiLocation.setText("⚠ IZINKAN LOKASI AKURAT (AGAR SSID & AP TAMPIL)");
                btnFixWifiLocation.setVisibility(View.VISIBLE);
            } else if (!gpsEnabled) {
                btnFixWifiLocation.setText("⚠ NYALAKAN GPS / LOKASI HP (AGAR SSID & AP TAMPIL)");
                btnFixWifiLocation.setVisibility(View.VISIBLE);
            } else {
                btnFixWifiLocation.setVisibility(View.GONE);
            }
        }

        DeviceMetrics.AppCountSnapshot ac = DeviceMetrics.readAppCounts(this);
        txtAppsSummary.setText(String.format(Locale.US,
                "%d Apps  •  %d User  •  HW/SW Ready",
                ac.totalApps, ac.userApps));
        txtAppsDetails.setText(String.format(Locale.US,
                "Total Packages : %d\nUser Installed : %d\nSystem Packages: %d\nInventory Cache: 6 hours (<<<lnx_packages:sep(124)>>>)",
                ac.totalApps, ac.userApps, ac.systemApps));

        String uptimeStr = DeviceMetrics.formatUptime(SystemClock.elapsedRealtime() / 1000L);
        txtDeviceSummary.setText(String.format(Locale.US,
                "%s %s  •  Android %s",
                Build.MANUFACTURER, Build.MODEL, Build.VERSION.RELEASE));
        txtDeviceDetails.setText(String.format(Locale.US,
                "Manufacturer : %s\nModel        : %s\nAndroid Ver  : %s (SDK %d)\nABI          : %s\nUptime       : %s",
                Build.MANUFACTURER, Build.MODEL, Build.VERSION.RELEASE, Build.VERSION.SDK_INT,
                Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "arm64", uptimeStr));

        txtSettingsSummary.setText(String.format(Locale.US,
                "%s  •  Server %s  •  GW %s",
                cfg.getHostname(),
                cfg.getAllowedServersRaw().isEmpty() ? "Open" : cfg.getAllowedServersRaw(),
                gw.isEmpty() ? "Auto" : gw));
    }

    private void showPingLogDialog() {
        String log = NativeBridge.isLoaded()
                ? NativeBridge.readPingLogTail(150)
                : "NativeBridge belum termuat.";

        TextView tv = new TextView(this);
        tv.setText(log);
        tv.setTextColor(TEXT_PRIMARY);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextSize(10.5f);
        tv.setPadding(dp(12), dp(12), dp(12), dp(12));

        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(BG_DARK);
        sv.addView(tv);

        new AlertDialog.Builder(this)
                .setTitle("Log Ping Lokal 3-Baris (Retensi 30 Hari CCTV)")
                .setView(sv)
                .setPositiveButton("PING 4X NOW", (d, w) -> startAgentService(CheckmkAgentService.ACTION_PING_NOW))
                .setNegativeButton("CLOSE", null)
                .show();
    }

    private void showTrafficCsvDialog() {
        String csv = DeviceMetrics.readTrafficCsvTail(this, 150);

        TextView tv = new TextView(this);
        tv.setText(csv);
        tv.setTextColor(TEXT_PRIMARY);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextSize(10.5f);
        tv.setPadding(dp(12), dp(12), dp(12), dp(12));

        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(BG_DARK);
        sv.addView(tv);

        new AlertDialog.Builder(this)
                .setTitle("Info Network — Traffic Log CSV (network_traffic.csv)")
                .setView(sv)
                .setNegativeButton("CLOSE", null)
                .show();
    }

    private void saveSettings() {
        int port = cfg.getPort();
        int design = parseIntOr(edtDesignMah.getText().toString(), 0);
        int cycles = parseIntOr(edtInitCycles.getText().toString(), 0);
        int pushInt = parseIntOr(edtPushInterval.getText().toString(), 300);

        cfg.save(
                edtHostname.getText().toString(),
                port,
                edtAllowed.getText().toString(),
                swAllowPrivate.isChecked(),
                edtGateway.getText().toString(),
                design,
                cycles,
                swPushEnabled.isChecked(),
                edtPushUrl.getText().toString(),
                edtPushToken.getText().toString(),
                pushInt
        );

        startAgentService(CheckmkAgentService.ACTION_START_OR_RELOAD);
        refreshDashboard();
        Toast.makeText(this, "Konfigurasi disimpan & Rust Agent di-reload!", Toast.LENGTH_SHORT).show();
    }

    private void startAgentService(String action) {
        Intent svc = new Intent(this, CheckmkAgentService.class);
        if (action != null) svc.setAction(action);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(svc);
        } else {
            startService(svc);
        }
    }

    private void requestNeededPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            List<String> req = new ArrayList<>();
            // Android 12+ (targetSdk >= 31) mewajibkan ACCESS_FINE_LOCATION dan ACCESS_COARSE_LOCATION
            // diminta bersama dalam satu panggilan requestPermissions(); jika hanya FINE, OS menolak diam-diam.
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                req.add(Manifest.permission.ACCESS_FINE_LOCATION);
                req.add(Manifest.permission.ACCESS_COARSE_LOCATION);
            }
            if (Build.VERSION.SDK_INT >= 33
                    && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                req.add(Manifest.permission.POST_NOTIFICATIONS);
            }
            if (!req.isEmpty()) {
                requestPermissions(req.toArray(new String[0]), 101);
            }
        }
    }

    private void handleFixWifiLocation() {
        if (!DeviceMetrics.hasFineLocationPermission(this)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                requestPermissions(new String[]{
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION
                }, 102);
            }
        } else if (!DeviceMetrics.isLocationServiceEnabled(this)) {
            try {
                startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS));
                Toast.makeText(this, "Aktifkan Lokasi/GPS agar Android mengizinkan pembacaan SSID & BSSID Wi-Fi", Toast.LENGTH_LONG).show();
            } catch (Throwable ignored) {}
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        refreshDashboard();
        startAgentService(CheckmkAgentService.ACTION_START_OR_RELOAD);
        if (requestCode == 102 && !DeviceMetrics.hasFineLocationPermission(this)) {
            try {
                Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                i.setData(Uri.fromParts("package", getPackageName(), null));
                startActivity(i);
                Toast.makeText(this, "Pilih Izin (Permissions) -> Lokasi -> Izinkan & aktifkan Lokasi Akurat (Precise)", Toast.LENGTH_LONG).show();
            } catch (Throwable ignored) {}
        }
    }

    private CollapsibleCard createCollapsibleCard(
            LinearLayout parent,
            String title,
            String subtitle,
            TextView summaryView,
            boolean initialExpanded
    ) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(14), dp(12), dp(14), dp(12));

        GradientDrawable gd = new GradientDrawable();
        gd.setColor(CARD_BG);
        gd.setCornerRadius(dp(10));
        gd.setStroke(dp(1), CARD_BORDER);
        card.setBackground(gd);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(10);
        card.setLayoutParams(lp);

        // Header Row (Title + Subtitle on left, Chevron on right)
        LinearLayout headerClickArea = new LinearLayout(this);
        headerClickArea.setOrientation(LinearLayout.VERTICAL);

        LinearLayout topRow = new LinearLayout(this);
        topRow.setOrientation(LinearLayout.HORIZONTAL);
        topRow.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout titleWrap = new LinearLayout(this);
        titleWrap.setOrientation(LinearLayout.VERTICAL);

        TextView tTitle = new TextView(this);
        tTitle.setText(title);
        tTitle.setTextColor(ACCENT_GREEN);
        tTitle.setTextSize(12);
        tTitle.setTypeface(null, Typeface.BOLD);
        titleWrap.addView(tTitle);

        TextView tSub = new TextView(this);
        tSub.setText(subtitle);
        tSub.setTextColor(TEXT_MUTED);
        tSub.setTextSize(11);
        tSub.setPadding(0, 0, 0, dp(6));
        titleWrap.addView(tSub);

        topRow.addView(titleWrap, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        TextView chevron = new TextView(this);
        chevron.setTextColor(TEXT_MUTED);
        chevron.setTextSize(16);
        chevron.setPadding(dp(8), 0, dp(4), 0);
        topRow.addView(chevron);

        headerClickArea.addView(topRow);
        headerClickArea.addView(summaryView);
        card.addView(headerClickArea);

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(0, dp(8), 0, 0);
        card.addView(body);

        CollapsibleCard cc = new CollapsibleCard(card, body, chevron, initialExpanded);
        headerClickArea.setOnClickListener(v -> cc.toggle());
        allCards.add(cc);

        parent.addView(card);
        return cc;
    }

    private TextView makeSummaryText(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextColor(TEXT_PRIMARY);
        tv.setTextSize(13.5f);
        tv.setTypeface(null, Typeface.BOLD);
        return tv;
    }

    private TextView makeMonoText(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextColor(TEXT_PRIMARY);
        tv.setTypeface(Typeface.MONOSPACE);
        tv.setTextSize(12);
        return tv;
    }

    private Button makeTopBarButton(String label, int textColor, String bgHex, String strokeHex) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextColor(textColor);
        b.setTextSize(11.5f);
        b.setTypeface(null, Typeface.BOLD);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.parseColor(bgHex));
        gd.setCornerRadius(dp(8));
        gd.setStroke(dp(1), Color.parseColor(strokeHex));
        b.setBackground(gd);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(8), 0, dp(8), 0);
        return b;
    }

    private Button makeActionButton(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextColor(ACCENT_GREEN);
        b.setTextSize(12);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.parseColor("#182930"));
        gd.setCornerRadius(dp(6));
        gd.setStroke(dp(1), Color.parseColor("#2A4450"));
        b.setBackground(gd);
        b.setGravity(Gravity.CENTER);
        return b;
    }

    private Button makeDangerButton(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextColor(ACCENT_RED);
        b.setTextSize(12);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.parseColor("#2D1618"));
        gd.setCornerRadius(dp(6));
        gd.setStroke(dp(1), ACCENT_RED);
        b.setBackground(gd);
        b.setGravity(Gravity.CENTER);
        return b;
    }

    private EditText addSettingField(LinearLayout parent, String label, String value, int inputType) {
        TextView lbl = new TextView(this);
        lbl.setText(label);
        lbl.setTextColor(TEXT_MUTED);
        lbl.setTextSize(11);
        lbl.setPadding(0, dp(6), 0, dp(2));
        parent.addView(lbl);

        EditText et = new EditText(this);
        et.setText(value);
        et.setTextColor(TEXT_PRIMARY);
        et.setInputType(inputType);
        et.setTextSize(13);
        et.setPadding(dp(10), dp(8), dp(10), dp(8));
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.parseColor("#0F191E"));
        gd.setCornerRadius(dp(6));
        gd.setStroke(dp(1), CARD_BORDER);
        et.setBackground(gd);
        parent.addView(et);
        return et;
    }

    private int parseIntOr(String s, int def) {
        try {
            return Integer.parseInt(s.trim());
        } catch (Throwable ignored) {
            return def;
        }
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
