package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.Locale;

public class BatteryHistory {
    private static final String PREFS_NAME = "cmk_battery_history_v2";
    private static final String KEY_FIRST_SEEN = "first_seen_ms";
    private static final String KEY_ACCUMULATED_CHARGE_PCT = "accumulated_charge_pct";
    private static final String KEY_LAST_LEVEL_SEEN = "last_level_seen";
    private static final String KEY_ESTIMATED_CYCLES = "estimated_cycles";
    private static final String KEY_FULL_DESIGN_MAH = "full_design_mah";
    private static final String KEY_LAST_VALID_CC_MAH = "last_valid_cc_mah";
    private static final String KEY_EST_FULL_CAP_MAH = "est_full_cap_mah";
    private static final String KEY_CAP_CALC_METHOD = "cap_calc_method";

    private static final int CYCLES_UNSET = -1;
    private final SharedPreferences prefs;

    public static class BatteryData {
        public double estFullCapMah;
        public String calcMethod;
        public int estimatedCycles;
        public int daysMonitored;
        public double designCapMah;
        public double healthPercent;
    }

    public BatteryHistory(Context ctx) {
        this.prefs = ctx.getApplicationContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (!prefs.contains(KEY_FIRST_SEEN)) {
            prefs.edit().putLong(KEY_FIRST_SEEN, System.currentTimeMillis()).apply();
        }
    }

    public synchronized void recordSample(Context ctx, int levelPct, boolean isCharging, int chargeCounterUah, double designCapMah, int sysCycles) {
        SharedPreferences.Editor ed = prefs.edit();
        if (designCapMah > 500) {
            ed.putFloat(KEY_FULL_DESIGN_MAH, (float) designCapMah);
        }

        int lastLevel = prefs.getInt(KEY_LAST_LEVEL_SEEN, -1);
        double accPct = prefs.getFloat(KEY_ACCUMULATED_CHARGE_PCT, 0f);
        if (lastLevel >= 0 && isCharging && levelPct > lastLevel) {
            int delta = levelPct - lastLevel;
            if (delta > 0 && delta <= 40) {
                accPct += delta;
                ed.putFloat(KEY_ACCUMULATED_CHARGE_PCT, (float) accPct);
            }
        }
        ed.putInt(KEY_LAST_LEVEL_SEEN, levelPct);

        double ccMah = chargeCounterUah > 0 ? (chargeCounterUah / 1000.0) : 0.0;
        if (ccMah > 100) {
            ed.putFloat(KEY_LAST_VALID_CC_MAH, (float) ccMah);
            if (levelPct >= 99 && ccMah <= designCapMah * 1.15) {
                ed.putFloat(KEY_EST_FULL_CAP_MAH, (float) ccMah);
                ed.putString(KEY_CAP_CALC_METHOD, String.format(Locale.US, "100%% Full Charge (%.0f / %.0f mAh)", ccMah, ccMah));
            } else if (levelPct >= 35 && !prefs.contains(KEY_EST_FULL_CAP_MAH)) {
                double est = (ccMah * 100.0) / levelPct;
                if (est > designCapMah * 0.4 && est <= designCapMah * 1.1) {
                    ed.putFloat(KEY_EST_FULL_CAP_MAH, (float) est);
                    ed.putString(KEY_CAP_CALC_METHOD, String.format(Locale.US, "Extrapolated @ %d%%", levelPct));
                }
            }
        }
        if (sysCycles >= 0) {
            ed.putInt(KEY_ESTIMATED_CYCLES, sysCycles);
        }
        ed.apply();
    }

    public BatteryData getStats(AgentConfig cfg, double currentDesignMah) {
        BatteryData d = new BatteryData();
        d.designCapMah = currentDesignMah > 500 ? currentDesignMah : prefs.getFloat(KEY_FULL_DESIGN_MAH, 4800f);

        float estFull = prefs.getFloat(KEY_EST_FULL_CAP_MAH, 0f);
        if (estFull > 500) {
            d.estFullCapMah = estFull;
            d.calcMethod = prefs.getString(KEY_CAP_CALC_METHOD, "Calibrated");
        } else {
            float lastCc = prefs.getFloat(KEY_LAST_VALID_CC_MAH, 0f);
            d.estFullCapMah = lastCc > 500 ? lastCc : d.designCapMah;
            d.calcMethod = "Estimasi awal";
        }

        int savedCycles = prefs.getInt(KEY_ESTIMATED_CYCLES, CYCLES_UNSET);
        int baseCycles = cfg.getInitialBatteryCycles();
        double accCycles = prefs.getFloat(KEY_ACCUMULATED_CHARGE_PCT, 0f) / 100.0;
        if (savedCycles >= 0) {
            d.estimatedCycles = savedCycles + baseCycles;
        } else {
            d.estimatedCycles = baseCycles + (int) Math.round(accCycles);
        }

        long firstSeen = prefs.getLong(KEY_FIRST_SEEN, System.currentTimeMillis());
        d.daysMonitored = (int) Math.max(0, (System.currentTimeMillis() - firstSeen) / 86400000L);
        d.healthPercent = d.designCapMah > 0 ? Math.min(100.0, (d.estFullCapMah / d.designCapMah) * 100.0) : 100.0;
        return d;
    }
}
