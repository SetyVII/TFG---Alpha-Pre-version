package com.testing.tfg.websocket;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

@Component
public class UnityTcpForwarder {

    private static final Logger log = LoggerFactory.getLogger(UnityTcpForwarder.class);

    private final String unityHost;
    private final int unityPort;

    private final Object lock = new Object();
    private Socket socket;
    private BufferedWriter writer;

    public UnityTcpForwarder(
            @Value("${unity.bridge.host:127.0.0.1}") String unityHost,
            @Value("${unity.bridge.port:5000}") int unityPort
    ) {
        this.unityHost = unityHost;
        this.unityPort = unityPort;
    }

    public void send(float alpha, float beta, float gamma, String action) {
        synchronized (lock) {
            String resolvedAction = (action == null || action.isBlank()) ? "none" : action.trim().toLowerCase(Locale.ROOT);
            String payload = String.format(
                    Locale.US,
                    "%.4f,%.4f,%.4f,%s%n",
                    alpha,
                    beta,
                    gamma,
                    resolvedAction
            );

            try {
                ensureConnected();
                writer.write(payload);
                writer.flush();
                log.debug("java->unity sent payload: {}", payload.trim());
            } catch (IOException firstError) {
                log.warn("java->unity send failed, retrying once: {}", firstError.getMessage());
                closeCurrentConnection();
                try {
                    ensureConnected();
                    writer.write(payload);
                    writer.flush();
                    log.info("java->unity send recovered after reconnect");
                } catch (IOException retryError) {
                    log.error("java->unity send failed after retry: {}", retryError.getMessage());
                    closeCurrentConnection();
                }
            }
        }
    }

    private void ensureConnected() throws IOException {
        if (socket != null && socket.isConnected() && !socket.isClosed() && writer != null) {
            return;
        }
        log.info("java->unity connecting to {}:{}", unityHost, unityPort);
        socket = new Socket(unityHost, unityPort);
        writer = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.US_ASCII));
        log.info("java->unity connected to {}:{}", unityHost, unityPort);
    }

    private void closeCurrentConnection() {
        if (writer != null) {
            try {
                writer.close();
            } catch (IOException ignored) {
            }
            writer = null;
        }

        if (socket != null) {
            String remote = socket.getRemoteSocketAddress() != null ? socket.getRemoteSocketAddress().toString() : unityHost + ":" + unityPort;
            try {
                socket.close();
            } catch (IOException ignored) {
            }
            log.info("java->unity connection closed: {}", remote);
            socket = null;
        }
    }
}
