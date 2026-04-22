package com.testing.tfg.config;

import com.testing.tfg.websocket.MotionSocketHandler;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

@Configuration
@EnableWebSocket
public class WebSocketConfig implements WebSocketConfigurer {

    private final MotionSocketHandler motionSocketHandler;

    public WebSocketConfig(MotionSocketHandler motionSocketHandler) {
        this.motionSocketHandler = motionSocketHandler;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(motionSocketHandler, "/ws/motion")
                .setAllowedOriginPatterns("*");
    }
}
