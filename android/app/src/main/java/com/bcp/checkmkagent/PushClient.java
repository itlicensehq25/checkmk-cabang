package com.bcp.checkmkagent;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public class PushClient {
    public static void pushNow(AgentConfig cfg, String payload) {
        String rawUrl = cfg.getPushUrl().trim();
        if (rawUrl.isEmpty()) {
            NativeBridge.recordPushResult(false, 0, "Push URL kosong");
            return;
        }

        HttpURLConnection conn = null;
        try {
            URL url = new URL(rawUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(10_000);
            conn.setReadTimeout(20_000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "text/plain; charset=utf-8");
            conn.setRequestProperty("User-Agent", "cmkagent-rust-android/2.0.0");
            conn.setRequestProperty("X-CMK-Hostname", cfg.getHostname());
            conn.setRequestProperty("X-CMK-Agent-Version", "2.0.0");
            conn.setRequestProperty("X-CMK-Transport", "hybrid-push");
            conn.setRequestProperty("X-CMK-Timestamp",
                    new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date()));

            String token = cfg.getPushToken().trim();
            if (!token.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + token);
            }

            byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(bytes);
                os.flush();
            }

            int code = conn.getResponseCode();
            StringBuilder resp = new StringBuilder();
            try (BufferedReader br = new BufferedReader(new InputStreamReader(
                    code >= 200 && code < 400 ? conn.getInputStream() : conn.getErrorStream(),
                    StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) {
                    resp.append(line);
                }
            } catch (Throwable ignored) {}

            if (code >= 200 && code < 300) {
                NativeBridge.recordPushResult(true, code, "HTTP " + code + " OK");
            } else {
                NativeBridge.recordPushResult(false, code, "HTTP " + code + ": " + resp);
            }
        } catch (Throwable t) {
            NativeBridge.recordPushResult(false, 0, t.getClass().getSimpleName() + ": " + t.getMessage());
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
