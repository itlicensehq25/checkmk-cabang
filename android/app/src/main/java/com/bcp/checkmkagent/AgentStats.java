package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

public final class AgentStats {
    private static final String PREFS = "cmkagent_stats";
    private static final String K_START = "start_ms";
    private static final String K_LAST_PULL = "last_pull_ms";
    private static final String K_LAST_CLIENT = "last_client";
    private static final String K_ACCEPTED = "accepted";
    private static final String K_REJECTED = "rejected";
    private static final String K_LAST_REJECTED = "last_rejected";
    private static final String K_RUNNING = "running";

    private static final String K_PUSH_ATTEMPTS = "push_attempts";
    private static final String K_PUSH_SUCCESSES = "push_successes";
    private static final String K_PUSH_FAILURES = "push_failures";
    private static final String K_LAST_PUSH = "last_push_ms";
    private static final String K_LAST_PUSH_OK = "last_push_ok";
    private static final String K_LAST_PUSH_CODE = "last_push_code";
    private static final String K_LAST_PUSH_MESSAGE = "last_push_message";

    private AgentStats() {}

    public static final class Snapshot {
        public long startMs;
        public long lastPullMs;
        public String lastClient = "-";
        public long accepted;
        public long rejected;
        public String lastRejected = "-";
        public boolean running;

        public long pushAttempts;
        public long pushSuccesses;
        public long pushFailures;
        public long lastPushMs;
        public boolean lastPushOk;
        public int lastPushCode;
        public String lastPushMessage = "-";
    }

    public static void recordStart(Context context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putLong(K_START, System.currentTimeMillis()).putBoolean(K_RUNNING, true).apply();
    }

    public static void recordStop(Context context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(K_RUNNING, false).apply();
    }

    public static void recordAccepted(Context context, String ip) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long count = p.getLong(K_ACCEPTED, 0L) + 1L;
        p.edit()
                .putLong(K_LAST_PULL, System.currentTimeMillis())
                .putString(K_LAST_CLIENT, ip == null ? "-" : ip)
                .putLong(K_ACCEPTED, count)
                .apply();
    }

    public static void recordRejected(Context context, String ip) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long count = p.getLong(K_REJECTED, 0L) + 1L;
        p.edit()
                .putLong(K_REJECTED, count)
                .putString(K_LAST_REJECTED, ip == null ? "-" : ip)
                .apply();
    }

    public static void recordPushResult(Context context, boolean ok, int code, String message) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long attempts = p.getLong(K_PUSH_ATTEMPTS, 0L) + 1L;
        long successes = p.getLong(K_PUSH_SUCCESSES, 0L) + (ok ? 1L : 0L);
        long failures = p.getLong(K_PUSH_FAILURES, 0L) + (ok ? 0L : 1L);
        p.edit()
                .putLong(K_PUSH_ATTEMPTS, attempts)
                .putLong(K_PUSH_SUCCESSES, successes)
                .putLong(K_PUSH_FAILURES, failures)
                .putLong(K_LAST_PUSH, System.currentTimeMillis())
                .putBoolean(K_LAST_PUSH_OK, ok)
                .putInt(K_LAST_PUSH_CODE, code)
                .putString(K_LAST_PUSH_MESSAGE, trimMessage(message))
                .apply();
    }

    public static Snapshot read(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Snapshot s = new Snapshot();
        s.startMs = p.getLong(K_START, 0L);
        s.lastPullMs = p.getLong(K_LAST_PULL, 0L);
        s.lastClient = p.getString(K_LAST_CLIENT, "-");
        s.accepted = p.getLong(K_ACCEPTED, 0L);
        s.rejected = p.getLong(K_REJECTED, 0L);
        s.lastRejected = p.getString(K_LAST_REJECTED, "-");
        s.running = p.getBoolean(K_RUNNING, false);

        s.pushAttempts = p.getLong(K_PUSH_ATTEMPTS, 0L);
        s.pushSuccesses = p.getLong(K_PUSH_SUCCESSES, 0L);
        s.pushFailures = p.getLong(K_PUSH_FAILURES, 0L);
        s.lastPushMs = p.getLong(K_LAST_PUSH, 0L);
        s.lastPushOk = p.getBoolean(K_LAST_PUSH_OK, false);
        s.lastPushCode = p.getInt(K_LAST_PUSH_CODE, 0);
        s.lastPushMessage = p.getString(K_LAST_PUSH_MESSAGE, "-");
        return s;
    }

    private static String trimMessage(String value) {
        if (value == null || value.trim().isEmpty()) return "-";
        String cleaned = value.trim().replace('\n', ' ').replace('\r', ' ');
        return cleaned.length() > 240 ? cleaned.substring(0, 240) : cleaned;
    }
}
