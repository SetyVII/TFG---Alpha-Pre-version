#!/usr/bin/env bash
set -euo pipefail

# ============================================
# TFG Server Startup Script
# Autor: Elias Cole / SetyVII
# Descripcion: Script para ejecutar el servidor TFG con HTTPS
#              Detecta automaticamente Java, usuario e IP local
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KEYSTORE_PATH="$PROJECT_ROOT/src/main/resources/local-dev.p12"

# ============================================
# DETECCION AUTOMATICA DE ENTORNO
# ============================================

# Obtener nombre de usuario actual
CURRENT_USER="$(whoami 2>/dev/null || echo "$USER" || echo "unknown")"
echo -e "\e[36mUsuario detectado: $CURRENT_USER\e[0m"

# ============================================
# DETECCION DE JAVA (Multi-plataforma)
# ============================================

find_java_home() {
    local custom_path="${1:-}"
    
    # 1. Usar JAVA_HOME si está configurado y es válido
    if [[ -n "$custom_path" && -f "$custom_path/bin/java" ]]; then
        echo "$custom_path"
        return 0
    fi
    
    # 2. Usar JAVA_HOME del entorno
    if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/bin/java" ]]; then
        echo "$JAVA_HOME"
        return 0
    fi
    
    # 3. Buscar en el PATH
    local java_path
    java_path=$(which java 2>/dev/null || command -v java 2>/dev/null || echo "")
    
    if [[ -n "$java_path" ]]; then
        # Resolver symlinks
        while [[ -L "$java_path" ]]; do
            java_path=$(readlink -f "$java_path" 2>/dev/null || readlink "$java_path" 2>/dev/null || break)
        done
        
        # Obtener el directorio padre de bin/java
        local java_bin=$(dirname "$java_path")
        local java_home=$(dirname "$java_bin")
        
        if [[ -f "$java_home/bin/java" ]]; then
            echo "$java_home"
            return 0
        fi
    fi
    
    # 4. Buscar en rutas comunes (Linux/macOS)
    local common_paths=(
        "/usr/lib/jvm/*"
        "/usr/local/java/*"
        "/opt/java/*"
        "/Library/Java/JavaVirtualMachines/*"
        "$HOME/.jdks/*"
        "$HOME/.sdkman/candidates/java/*"
        "/usr/local/opt/*/libexec/openjdk*"
        "/usr/local/opt/*/libexec/*"
    )
    
    for pattern in "${common_paths[@]}"; do
        for java_dir in $(ls -d $pattern 2>/dev/null || true); do
            if [[ -f "$java_dir/bin/java" ]]; then
                echo "$java_dir"
                return 0
            fi
        done
    done
    
    # 5. Intentar con java -XshowSettings
    local output
    output=$(java -XshowSettings:properties -version 2>&1 || true)
    if [[ "$output" =~ java\.home[[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then
        local java_home="${BASH_REMATCH[1]}"
        if [[ -f "$java_home/bin/java" ]]; then
            echo "$java_home"
            return 0
        fi
    fi
    
    return 1
}

# Buscar Java
JAVA_HOME="${JAVA_HOME:-}"
if [[ -z "$JAVA_HOME" ]]; then
    JAVA_HOME=$(find_java_home "$JAVA_HOME") || true
fi

if [[ -z "$JAVA_HOME" || ! -f "$JAVA_HOME/bin/java" ]]; then
    echo "ERROR: No se encontró JAVA_HOME válido. Instala Java JDK y configura JAVA_HOME o asegúrate de que java esté en PATH." >&2
    exit 1
fi

echo -e "\e[32mJava detectado en: $JAVA_HOME\e[0m"

# Configurar entorno
export JAVA_HOME
PATH="$JAVA_HOME/bin:$PATH"

# Verificar keytool
if ! command -v keytool &>/dev/null; then
    echo "ERROR: No se encontró keytool en PATH" >&2
    exit 1
fi

# ============================================
# DETECCION DE IP LOCAL
# ============================================

get_local_ip() {
    local ip
    
    # Intentar con hostname
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$ip" && "$ip" != "127.0.0.1" && ! "$ip" =~ ^169\.254\. ]]; then
        echo "$ip"
        return 0
    fi
    
    # Intentar con ip (Linux)
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^169\.254\.' | head -1 || true)
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    
    # Intentar con ifconfig (macOS/BSD)
    ip=$(ifconfig 2>/dev/null | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^169\.254\.' | grep -v '^127\.' | head -1 || true)
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    
    # Intentar con ipconfig (Windows Git Bash)
    ip=$(ipconfig 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^169\.254\.' | grep -v '^127\.' | head -1 || true)
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    
    echo "127.0.0.1"
}

LOCAL_IP=$(get_local_ip)
echo -e "\e[36mIP local detectada: $LOCAL_IP\e[0m"

# ============================================
# GENERACION DE CERTIFICADO (si no existe)
# ============================================

if [[ ! -f "$KEYSTORE_PATH" ]]; then
    echo -e "\e[33mGenerando certificado autofirmado...\e[0m"
    
    local_dname="CN=$LOCAL_IP, OU=TFG, O=TFG, L=Local, ST=Local, C=ES"
    local_san="SAN=dns:localhost,ip:127.0.0.1,ip:$LOCAL_IP"
    
    keytool -genkeypair \
        -alias tfg-local \
        -keyalg RSA \
        -keysize 2048 \
        -validity 3650 \
        -storetype PKCS12 \
        -keystore "$KEYSTORE_PATH" \
        -storepass changeit \
        -keypass changeit \
        -dname "$local_dname" \
        -ext "$local_san"
    
    echo -e "\e[32mCertificado generado en $KEYSTORE_PATH\e[0m"
fi

# ============================================
# EJECUCION DEL SERVIDOR
# ============================================

echo -e "\e[32mIniciando servidor TFG...\e[0m"
echo -e "\e[36mUsuario: $CURRENT_USER\e[0m"
echo -e "\e[36mJava: $JAVA_HOME\e[0m"
echo -e "\e[36mIP: $LOCAL_IP\e[0m"
echo -e "\e[36mPerfil: https\e[0m"

cd "$PROJECT_ROOT"
exec ./mvnw spring-boot:run -Dspring-boot.run.profiles=https
