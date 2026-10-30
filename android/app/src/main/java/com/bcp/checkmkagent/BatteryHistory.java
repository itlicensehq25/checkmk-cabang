package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Tracks real battery charging cycles and full-charge capacity (2946 mAh @ 100% on Newland MT93).
 * Captures charge deltas continuously via BroadcastReceiver and periodic background checks,
 * even when the device transitions to Full or charges while idle.
 */
public final class BatteryHistory {
    private static final String PREFS = "cmkagent_accumeter_v2";

    private static final String K_SAMPLES = "accumeter_capacity_samples";
    private static final String K_CALIBRATED_FULL_MAH = "calibrated_full_mah";
    private static final String K_CALIBRATED_FULL_VOLT = "calibrated_full_volt";
    private static final String K_CALIBRATED_TIMESTAMP = "calibrated_timestamp";

    private static final String K_IS_CHARGING = "active_is_charging";
    private static final String K_SESSION_START_LEVEL = "active_start_level";
    private static final String K_SESSION_START_MAH = "active_start_mah";
    private static final String K_SESSION_LAST_LEVEL = "active_last_level";
    private static final String K_SESSION_LAST_MAH = "active_last_mah";
    private static final String K_SESSION_COUNTED = "active_session_counted";

    // Continuous observation keys (catches charging even if plugged/unplugged between polls)
    private static final String K_LAST_OBSERVED_LEVEL = "last_observed_level";
    private static final String K_LAST_OBSERVED_MAH = "last_observed_mah";

    // Accumulated charged mAh and discrete charge session counter for Android 11 / MT93
    private static final String K_ACCUMULATED_CHARGED_MAH = "accumulated_charged_mah";
    private static final String K_CHARGE_SESSION_COUNT = "charge_session_count";

    private static final int MAX_SESSIONS = 15;
    private static final int MIN_CHARGE_DELTA_PERCENT = 15;

    private BatteryHistory() {}

    public static synchronized void updateChargeSession(
            Context context, int level, String status, boolean isPlugged,
            double chargeCounterMah, double voltageV, double fullScaleMah) {
        if (context == null || level < 0) return;

        double refScale = fullScaleMah > 500.0 ? fullScaleMah : 2946.0;
        double effectiveMah = (!Double.isNaN(chargeCounterMah) && chargeCounterMah > 0)
                ? chargeCounterMah
                : (refScale * (level / 100.0));

        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        SharedPreferences.Editor ed = prefs.edit();

        boolean isChargingState = isPlugged
                || "Charging".equalsIgnoreCase(status)
                || "Full".equalsIgnoreCase(status);
        boolean wasCharging = prefs.getBoolean(K_IS_CHARGING, false);

        // 1. Calibrate full capacity when at 100% or Full
        if ((level == 100 || "Full".equalsIgnoreCase(status)) && effectiveMah > 1500.0) {
            ed.putFloat(K_CALIBRATED_FULL_MAH, (float) effectiveMah);
            if (!Double.isNaN(voltageV) && voltageV > 0) {
                ed.putFloat(K_CALIBRATED_FULL_VOLT, (float) voltageV);
            }
            ed.putLong(K_CALIBRATED_TIMESTAMP, System.currentTimeMillis());
        }

        // 2. Catch any upward jump in mAh or battery level (even if charged while asleep/rebooted)
        int prevObsLevel = prefs.getInt(K_LAST_OBSERVED_LEVEL, -1);
        float prevObsMah = prefs.getFloat(K_LAST_OBSERVED_MAH, -1f);
        float totalAccumulatedMah = prefs.getFloat(K_ACCUMULATED_CHARGED_MAH, 0f);
        int chargeSessionCount = prefs.getInt(K_CHARGE_SESSION_COUNT, 0);

        if (prevObsMah > 0f && effectiveMah > prevObsMah) {
            double deltaMah = effectiveMah - prevObsMah;
            int deltaLvl = prevObsLevel >= 0 ? (level - prevObsLevel) : 0;
            // Filter out tiny coulomb counter jitter (< 8 mAh when not charging and level didn't rise)
            if (deltaMah >= 8.0 || (isChargingState && deltaMah > 0.0) || deltaLvl >= 1) {
                if (deltaMah <= refScale * 1.5) {
                    totalAccumulatedMah += (float) deltaMah;
                    ed.putFloat(K_ACCUMULATED_CHARGED_MAH, totalAccumulatedMah);
                }
            }
            // If battery jumped up by >= 5% while not tracked in an active session (e.g. charged while off)
            if (!wasCharging && !isChargingState && deltaLvl >= 5) {
                chargeSessionCount++;
                ed.putInt(K_CHARGE_SESSION_COUNT, chargeSessionCount);
            }
        }

        ed.putInt(K_LAST_OBSERVED_LEVEL, level);
        ed.putFloat(K_LAST_OBSERVED_MAH, (float) effectiveMah);

        // 3. Active charging session state machine
        if (isChargingState && !wasCharging) {
            int startLevel = (prevObsLevel >= 0 && prevObsLevel < level) ? prevObsLevel : level;
            double startMah = (prevObsMah > 0f && prevObsMah < effectiveMah) ? prevObsMah : effectiveMah;
            boolean counted = false;

            if ((level - startLevel) >= 5 || ((level == 100 || "Full".equalsIgnoreCase(status)) && startLevel < 98)) {
                chargeSessionCount++;
                ed.putInt(K_CHARGE_SESSION_COUNT, chargeSessionCount);
                counted = true;
            }

            ed.putBoolean(K_IS_CHARGING, true);
            ed.putInt(K_SESSION_START_LEVEL, startLevel);
            ed.putFloat(K_SESSION_START_MAH, (float) startMah);
            ed.putInt(K_SESSION_LAST_LEVEL, level);
            ed.putFloat(K_SESSION_LAST_MAH, (float) effectiveMah);
            ed.putBoolean(K_SESSION_COUNTED, counted);
            ed.apply();
            return;
        }

        if (isChargingState && wasCharging) {
            int startLevel = prefs.getInt(K_SESSION_START_LEVEL, level);
            boolean counted = prefs.getBoolean(K_SESSION_COUNTED, false);

            // If battery discharged slightly while still plugged in, update minimum start level
            if (level < startLevel) {
                startLevel = level;
                ed.putInt(K_SESSION_START_LEVEL, startLevel);
                ed.putFloat(K_SESSION_START_MAH, (float) effectiveMah);
            }

            int gainedLevel = level - startLevel;
            if (!counted && (gainedLevel >= 5 || ((level == 100 || "Full".equalsIgnoreCase(status)) && startLevel < 98))) {
                chargeSessionCount++;
                ed.putInt(K_CHARGE_SESSION_COUNT, chargeSessionCount);
                ed.putBoolean(K_SESSION_COUNTED, true);
            }

            ed.putInt(K_SESSION_LAST_LEVEL, level);
            ed.putFloat(K_SESSION_LAST_MAH, (float) effectiveMah);
            ed.apply();
            return;
        }

        if (!isChargingState && wasCharging) {
            int startLevel = prefs.getInt(K_SESSION_START_LEVEL, -1);
            int lastLevel = Math.max(level, prefs.getInt(K_SESSION_LAST_LEVEL, level));
            double startMah = prefs.getFloat(K_SESSION_START_MAH, -1f);
            double lastMah = Math.max(effectiveMah, prefs.getFloat(K_SESSION_LAST_MAH, (float) effectiveMah));
            boolean counted = prefs.getBoolean(K_SESSION_COUNTED, false);

            int deltaLevel = lastLevel - startLevel;
            double deltaMah = lastMah - startMah;

            if (!counted && (deltaLevel >= 3 || deltaMah >= (refScale * 0.03))) {
                chargeSessionCount++;
                ed.putInt(K_CHARGE_SESSION_COUNT, chargeSessionCount);
            }

            if (deltaLevel >= MIN_CHARGE_DELTA_PERCENT && deltaMah > 0) {
                double estimatedSessionFull = (deltaMah / (deltaLevel / 100.0));
                if (estimatedSessionFull >= 800.0 && estimatedSessionFull <= 25000.0) {
                    addSessionSample(prefs, estimatedSessionFull);
                }
            }

            ed.putBoolean(K_IS_CHARGING, false);
            ed.putBoolean(K_SESSION_COUNTED, false);
            ed.remove(K_SESSION_START_LEVEL);
            ed.remove(K_SESSION_START_MAH);
            ed.apply();
            return;
        }

        ed.apply();
    }

    public static int getEstimatedCycles(Context context, double referenceCapacityMah) {
        if (context == null) return 0;
        double ref = referenceCapacityMah > 500.0 ? referenceCapacityMah : 2946.0;
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        double totalCharged = prefs.getFloat(K_ACCUMULATED_CHARGED_MAH, 0f);
        int sessions = prefs.getInt(K_CHARGE_SESSION_COUNT, 0);

        int eqCycles = totalCharged > 0 ? (int) Math.ceil(totalCharged / ref) : 0;
        int cycles = Math.max(eqCycles, sessions);
        int manualBase = AgentConfig.getInitialCycleCount(context);
        return manualBase + cycles;
    }

    public static double getAccumulatedChargedMah(Context context) {
        if (context == null) return 0.0;
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getFloat(K_ACCUMULATED_CHARGED_MAH, 0f);
    }

    public static int getChargeSessionCount(Context context) {
        if (context == null) return 0;
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getInt(K_CHARGE_SESSION_COUNT, 0);
    }

    private static void addSessionSample(SharedPreferences prefs, double capacity) {
        List<Double> samples = parseSamples(prefs.getString(K_SAMPLES, ""));
        samples.add(capacity);
        while (samples.size() > MAX_SESSIONS) {
            samples.remove(0);
        }

        StringBuilder sb = new StringBuilder();
        for (double s : samples) {
            if (sb.length() > 0) sb.append(',');
            sb.append(String.format(Locale.US, "%.1f", s));
        }
        prefs.edit().putString(K_SAMPLES, sb.toString()).apply();
    }

    public static double getMedianCapacity(Context context) {
        if (context == null) return Double.NaN;
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        List<Double> samples = parseSamples(prefs.getString(K_SAMPLES, ""));
        if (samples.isEmpty()) return Double.NaN;

        List<Double> sorted = new ArrayList<>(samples);
        Collections.sort(sorted);
        int n = sorted.size();
        if (n % 2 == 1) return sorted.get(n / 2);
        return (sorted.get(n / 2 - 1) + sorted.get(n / 2)) / 2.0;
    }

    public static int getSampleCount(Context context) {
        if (context == null) return 0;
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return parseSamples(prefs.getString(K_SAMPLES, "")).size();
    }

    public static double getCalibratedFullChargeMah(Context context) {
        if (context == null) return Double.NaN;
        float val = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getFloat(K_CALIBRATED_FULL_MAH, -1f);
        return val > 1500.0f ? val : Double.NaN;
    }

    public static double getCalibratedFullVoltage(Context context) {
        if (context == null) return Double.NaN;
        float val = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getFloat(K_CALIBRATED_FULL_VOLT, -1f);
        return val > 0 ? val : Double.NaN;
    }

    private static List<Double> parseSamples(String raw) {
        List<Double> result = new ArrayList<>();
        if (raw == null || raw.trim().isEmpty()) return result;
        for (String token : raw.split(",")) {
            try {
                double val = Double.parseDouble(token.trim());
                if (val > 0) result.add(val);
            } catch (Exception ignored) {}
        }
        return result;
    }

    public static void clear(Context context) {
        if (context != null) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply();
        }
    }
}
