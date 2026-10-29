package com.bcp.checkmkagent;

import android.content.Context;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class PushClient {
    private static final int CONNECT_TIMEOUT_MS = 8000;
    private static final int READ_TIMEOUT_MS = 8000;

    private PushClient() {}

    public static final class Result {
        public final boolean ok;
        public final int code;
        public final String message;

        Result(boolean ok, int code, String message) {
            this.ok = ok;
            this.code = code;
            this.message = message == null ? "" : message;
        }
    }

    public static Result pushNow(Context context) {
        if (!AgentConfig.isPushEnabled(context)) {
            return new Result(false, 0, "Push backup disabled");
        }

        String endpoint = AgentConfig.getPushUrl(context);
        if (endpoint.isEmpty()) {
            return new Result(false, 0, "Push receiver URL not configured");
        }

        HttpURLConnection connection = null;
        try {
            URL url = new URL(endpoint);
            String protocol = url.getProtocol();
            if (!"http".equalsIgnoreCase(protocol) && !"https".equalsIgnoreCase(protocol)) {
                Result result = new Result(false, 0, "Only HTTP/HTTPS receiver URLs are supported");
                AgentStats.recordPushResult(context, result.ok, result.code, result.message);
                return result;
            }

            byte[] payload = CheckmkOutput.build(context).getBytes(StandardCharsets.UTF_8);
            connection = (HttpURLConnection) url.openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setDoOutput(true);
            connection.setUseCaches(false);
            connection.setRequestProperty("Content-Type", "text/plain; charset=utf-8");
            connection.setRequestProperty("Accept", "application/json, text/plain, */*");
            connection.setRequestProperty("User-Agent", "cmkagent/" + CheckmkOutput.VERSION);
            connection.setRequestProperty("X-CMK-Hostname", AgentConfig.getHostname(context));
            connection.setRequestProperty("X-CMK-Agent-Version", CheckmkOutput.VERSION);
            connection.setRequestProperty("X-CMK-Transport", "hybrid-push");
            connection.setRequestProperty("X-CMK-Timestamp", String.valueOf(System.currentTimeMillis()));
            connection.setFixedLengthStreamingMode(payload.length);

            String token = AgentConfig.getPushToken(context);
            if (!token.isEmpty()) {
                connection.setRequestProperty("Authorization", "Bearer " + token);
            }

            try (OutputStream out = connection.getOutputStream()) {
                out.write(payload);
                out.flush();
            }

            int code = connection.getResponseCode();
            boolean ok = code >= 200 && code < 300;
            String body = readResponseBody(connection, ok);
            String message = body.isEmpty() ? (ok ? "Push accepted" : "HTTP " + code) : body;
            Result result = new Result(ok, code, message);
            AgentStats.recordPushResult(context, result.ok, result.code, result.message);
            return result;
        } catch (Exception e) {
            String message = e.getMessage();
            if (message == null || message.trim().isEmpty()) message = e.getClass().getSimpleName();
            Result result = new Result(false, 0, message);
            AgentStats.recordPushResult(context, result.ok, result.code, result.message);
            return result;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static String readResponseBody(HttpURLConnection connection, boolean success) {
        InputStream stream = null;
        try {
            stream = success ? connection.getInputStream() : connection.getErrorStream();
            if (stream == null) return "";
            StringBuilder sb = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(stream, StandardCharsets.UTF_8))) {
                char[] buffer = new char[512];
                int read;
                while ((read = reader.read(buffer)) >= 0 && sb.length() < 2048) {
                    int room = 2048 - sb.length();
                    sb.append(buffer, 0, Math.min(read, room));
                    if (sb.length() >= 2048) break;
                }
            }
            return sb.toString().trim();
        } catch (Exception ignored) {
            return "";
        }
    }
}
