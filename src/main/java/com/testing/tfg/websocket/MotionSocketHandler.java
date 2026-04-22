package com.testing.tfg.websocket;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Component
public class MotionSocketHandler extends TextWebSocketHandler {

    private static final Logger log = LoggerFactory.getLogger(MotionSocketHandler.class);

    private final UnityTcpForwarder unityTcpForwarder;
    private final Set<WebSocketSession> sessions = new CopyOnWriteArraySet<>();
    private volatile float lastAlpha = 0f;
    private volatile float lastBeta = 0f;
    private volatile float lastGamma = 0f;

    public MotionSocketHandler(UnityTcpForwarder unityTcpForwarder) {
        this.unityTcpForwarder = unityTcpForwarder;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) throws Exception {
        sessions.add(session);
        log.info("mobile/web->java websocket connected: sessionId={} remote={} activeSessions={}",
                session.getId(),
                session.getRemoteAddress(),
                sessions.size());
        session.sendMessage(new TextMessage("Hola mundo desde el socket"));
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws Exception {
        String payload = message.getPayload();
        String role = getStringField(payload, "role", "unknown");
        String type = getStringField(payload, "type", "unknown");
        if ("motion".equalsIgnoreCase(type)) {
            log.debug("mobile/web->java message: sessionId={} role={} type={}", session.getId(), role, type);
        } else {
            log.info("mobile/web->java message: sessionId={} role={} type={}", session.getId(), role, type);
        }
        broadcast(payload);
        forwardToUnityIfApplicable(payload);
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) throws Exception {
        sessions.remove(session);
        log.info("mobile/web->java websocket disconnected: sessionId={} status={} activeSessions={}",
                session.getId(),
                status,
                sessions.size());
    }

    private void broadcast(String message) throws IOException {
        TextMessage textMessage = new TextMessage(message);
        int delivered = 0;
        for (WebSocketSession session : sessions) {
            if (session.isOpen()) {
                session.sendMessage(textMessage);
                delivered++;
            }
        }
        String type = getStringField(message, "type", "unknown");
        if (!"motion".equalsIgnoreCase(type)) {
            log.info("java->web broadcast delivered: type={} targets={}", type, delivered);
        }
    }

    private void forwardToUnityIfApplicable(String payload) {
        try {
            String role = getStringField(payload, "role", "");
            if (!"mobile".equalsIgnoreCase(role)) {
                log.debug("java->unity skip forward: role={}", role);
                return;
            }

            String type = getStringField(payload, "type", "");
            if ("register".equalsIgnoreCase(type)) {
                unityTcpForwarder.send(lastAlpha, lastBeta, lastGamma, "none");
                log.info("java->unity forwarded register handshake from mobile");
                return;
            }

            if ("motion".equalsIgnoreCase(type)) {
                float alpha = getFloatField(payload, "alpha", lastAlpha);
                float beta = getFloatField(payload, "beta", lastBeta);
                float gamma = getFloatField(payload, "gamma", lastGamma);
                float tiltX = getFloatField(payload, "tiltX", gamma);
                float tiltY = getFloatField(payload, "tiltY", beta);

                // Preferimos tilt normalizado [-1..1] cuando existe para mapear igual que teclado.
                lastAlpha = alpha;
                lastBeta = tiltY;
                lastGamma = tiltX;

                String action = getStringField(payload, "action", "none");
                unityTcpForwarder.send(alpha, lastBeta, lastGamma, action);
                log.debug("java->unity forwarded motion alpha={} beta={} gamma={} action={}", alpha, lastBeta, lastGamma, action);
                return;
            }

            if ("action".equalsIgnoreCase(type)) {
                String action = getStringField(payload, "action", "none");
                unityTcpForwarder.send(lastAlpha, lastBeta, lastGamma, action);
                log.info("java->unity forwarded action={}", action);
                return;
            }
            log.debug("java->unity ignored message type={}", type);
        } catch (Exception ignored) {
            // Non-JSON payloads are still valid for ws broadcast; only Unity forwarding requires JSON.
            log.warn("java->unity could not parse payload for forwarding");
        }
    }

    private static String getStringField(String json, String field, String fallback) {
        Pattern pattern = Pattern.compile("\"" + Pattern.quote(field) + "\"\\s*:\\s*\"([^\"]*)\"");
        Matcher matcher = pattern.matcher(json);
        if (matcher.find()) {
            return matcher.group(1);
        }
        return fallback;
    }

    private static float getFloatField(String json, String field, float fallback) {
        Pattern pattern = Pattern.compile("\"" + Pattern.quote(field) + "\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)");
        Matcher matcher = pattern.matcher(json);
        if (matcher.find()) {
            try {
                return Float.parseFloat(matcher.group(1));
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }
}
