package com.testing.tfg.websocket;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

@Component
public class UnityTcpForwarder {

    private static final Logger log = LoggerFactory.getLogger(UnityTcpForwarder.class);
    private static final int HEARTBEAT_INTERVAL_MS = 5000;
    private static final int SOCKET_TIMEOUT_MS = 10000;

    private final String unityHost;
    private final int unityPort;

    private final Object lock = new Object();
    private Socket socket;
    private BufferedWriter writer;
    private BufferedReader reader;

    private volatile boolean unityValidated = false;
    private Thread heartbeatThread;

    public UnityTcpForwarder(
            @Value("${unity.bridge.host:127.0.0.1}") String unityHost,
            @Value("${unity.bridge.port:5000}") int unityPort
    ) {
        this.unityHost = unityHost;
        this.unityPort = unityPort;
    }

    public boolean isUnityValidated() {
        return unityValidated;
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
                if (!unityValidated) {
                    log.debug("java->unity skipped send: unity not validated after connection attempt");
                    return;
                }
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
        if (socket != null && socket.isConnected() && !socket.isClosed() && writer != null && reader != null) {
            return;
        }
        log.info("java->unity connecting to {}:{}", unityHost, unityPort);
        socket = new Socket(unityHost, unityPort);
        socket.setSoTimeout(SOCKET_TIMEOUT_MS);
        socket.setTcpNoDelay(true);
        socket.setKeepAlive(true);
        writer = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.US_ASCII));
        reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
        log.info("java->unity connected to {}:{}", unityHost, unityPort);

        performHandshake();
        startHeartbeat();
    }

    private void performHandshake() throws IOException {
        log.info("java->unity sending handshake");
        writer.write("JAVA_HANDSHAKE\n");
        writer.flush();

        String response = reader.readLine();
        if ("UNITY_OK".equals(response)) {
            unityValidated = true;
            log.info("java->unity handshake successful");
        } else {
            unityValidated = false;
            log.warn("java->unity handshake failed, response: {}", response);
            throw new IOException("Handshake failed: expected UNITY_OK, got: " + response);
        }
    }

    private void startHeartbeat() {
        if (heartbeatThread != null && heartbeatThread.isAlive()) {
            heartbeatThread.interrupt();
        }
        heartbeatThread = new Thread(this::heartbeatLoop);
        heartbeatThread.setDaemon(true);
        heartbeatThread.setName("UnityHeartbeat");
        heartbeatThread.start();
    }

    private void heartbeatLoop() {
        while (!Thread.currentThread().isInterrupted()) {
            try {
                Thread.sleep(HEARTBEAT_INTERVAL_MS);
                synchronized (lock) {
                    if (writer == null || socket == null || socket.isClosed()) {
                        unityValidated = false;
                        break;
                    }
                    writer.write("JAVA_PING\n");
                    writer.flush();
                    String response = reader.readLine();
                    if (!"UNITY_PONG".equals(response)) {
                        log.warn("java->unity heartbeat failed, response: {}", response);
                        unityValidated = false;
                        break;
                    }
                    log.debug("java->unity heartbeat ok");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (IOException e) {
                log.warn("java->unity heartbeat error: {}", e.getMessage());
                unityValidated = false;
                break;
            }
        }
        log.info("java->unity heartbeat thread stopped");
    }

    private void closeCurrentConnection() {
        unityValidated = false;

        if (heartbeatThread != null) {
            heartbeatThread.interrupt();
            heartbeatThread = null;
        }

        if (reader != null) {
            try {
                reader.close();
            } catch (IOException ignored) {
            }
            reader = null;
        }

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
