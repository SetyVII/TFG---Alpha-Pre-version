<#PSScriptInfo
.VERSION 2.0
.GUID 1a2b3c4d-5678-90ef-ghij-klmnopqrstuv
.AUTHOR Elias Cole / SetyVII
.DESCRIPTION Script para ejecutar el servidor TFG con HTTPS, detectando automaticamente Java, usuario e IP
#>

param(
    [string]$JavaHome = $env:JAVA_HOME
)

# ============================================
# DETECCION AUTOMATICA DE ENTORNO
# ============================================

# Obtener nombre de usuario actual
$currentUser = $env:USERNAME
if (-not $currentUser) {
    $currentUser = [System.Environment]::UserName
}
Write-Host "Usuario detectado: $currentUser" -ForegroundColor Cyan

# Obtener ruta del script y proyecto
$scriptRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptRoot
$keystorePath = Join-Path $projectRoot "src\main\resources\local-dev.p12"

# ============================================
# DETECCION DE JAVA (Multi-plataforma)
# ============================================

function Find-JavaHome {
    param([string]$CustomPath = $null)
    
    # 1. Usar JAVA_HOME si está configurado y es válido
    if ($CustomPath -and (Test-Path (Join-Path $CustomPath "bin\java.exe"))) {
        return $CustomPath
    }
    
    # 2. Buscar en el PATH
    try {
        $javaPath = (Get-Command java -ErrorAction SilentlyContinue).Source
        if ($javaPath -and $javaPath -notlike "*java.exe") {
            $javaPath = "$javaPath.exe"
        }
        if ($javaPath -and (Test-Path $javaPath)) {
            $javaHome = Split-Path -Parent (Split-Path -Parent $javaPath)
            if (Test-Path (Join-Path $javaHome "bin\java.exe")) {
                return $javaHome
            }
        }
    } catch {
        # Ignorar error
    }
    
    # 3. Buscar en rutas comunes de JDK (Windows)
    $commonPaths = @(
        "${env:ProgramFiles}\Java\*",
        "${env:ProgramFiles(x86)}\Java\*",
        "$env:USERPROFILE\.jdks\*",
        "C:\Program Files\Eclipse Foundation\jdk-*",
        "C:\Program Files\Microsoft\jdk-*",
        "C:\Users\*\AppData\Local\Programs\Eclipse Adoptium\jdk-*",
        "C:\Users\*\AppData\Local\Programs\Microsoft\jdk-*"
    )
    
    foreach ($pattern in $commonPaths) {
        $matches = Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | 
                   Where-Object { $_.FullName -match "jdk|jre" } | 
                   Sort-Object FullName -Descending
        
        foreach ($dir in $matches) {
            if (Test-Path (Join-Path $dir.FullName "bin\java.exe")) {
                return $dir.FullName
            }
        }
    }
    
    # 4. Buscar en el registro de Windows
    try {
        $regPaths = @(
            "HKLM:\SOFTWARE\JavaSoft\Java Development Kit",
            "HKLM:\SOFTWARE\WOW6432Node\JavaSoft\Java Development Kit"
        )
        
        foreach ($regPath in $regPaths) {
            if (Test-Path $regPath) {
                $versions = Get-ChildItem -Path $regPath | Sort-Object Name -Descending
                foreach ($version in $versions) {
                    $javaHome = (Get-ItemProperty -Path $version.PSPath).JavaHome
                    if ($javaHome -and (Test-Path (Join-Path $javaHome "bin\java.exe"))) {
                        return $javaHome
                    }
                }
            }
        }
    } catch {
        # Ignorar error de registro
    }
    
    # 5. Intentar con java -XshowSettings
    try {
        $output = java -XshowSettings:properties -version 2>&1
        if ($output -match "java\.home\s*=\s*(.+)") {
            $javaHome = $matches[1].Trim()
            if (Test-Path (Join-Path $javaHome "bin\java.exe")) {
                return $javaHome
            }
        }
    } catch {
        # Ignorar error
    }
    
    return $null
}

# Buscar Java
if (-not $JavaHome) {
    $JavaHome = Find-JavaHome
}

if (-not $JavaHome) {
    throw "No se encontró JAVA_HOME válido. Instala Java JDK y configura JAVA_HOME o asegúrate de que java esté en PATH."
}

# Validar que java.exe existe
$javaExe = Join-Path $JavaHome "bin\java.exe"
if (-not (Test-Path $javaExe)) {
    throw "No se encontró java.exe en $JavaHome\bin. Verifica que JAVA_HOME apunte a un JDK válido."
}

Write-Host "Java detectado en: $JavaHome" -ForegroundColor Green

# Configurar entorno
$env:JAVA_HOME = $JavaHome
$env:Path = "$JavaHome\bin;$env:Path"
$keytoolPath = Join-Path $JavaHome "bin\keytool.exe"

if (-not (Test-Path $keytoolPath)) {
    throw "No se encontró keytool.exe en $JavaHome\bin"
}

# ============================================
# DETECCION DE IP LOCAL
# ============================================

function Get-LocalIP {
    try {
        # Intentar obtener IP de conexiones activas
        $ipConfig = Get-NetIPConfiguration -ErrorAction SilentlyContinue | 
                   Where-Object { $_.NetAdapter.Status -eq "Up" }
        
        foreach ($config in $ipConfig) {
            foreach ($ip in $config.IPv4Address) {
                $ipAddress = $ip.IPAddress
                if ($ipAddress -notlike "169.254.*" -and $ipAddress -ne "127.0.0.1") {
                    return $ipAddress
                }
            }
        }
        
        # Intentar con Get-NetIPAddress
        $localIp = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue | 
            Where-Object {
                $_.IPAddress -notlike "169.254.*" -and
                $_.IPAddress -ne "127.0.0.1"
            } | Select-Object -First 1 -ExpandProperty IPAddress)
        
        if ($localIp) {
            return $localIp
        }
        
        # Intentar con hostname
        $hostname = hostname
        try {
            $ipEntry = [System.Net.Dns]::GetHostEntry($hostname)
            foreach ($addr in $ipEntry.AddressList) {
                if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $ipStr = $addr.ToString()
                    if ($ipStr -notlike "169.254.*" -and $ipStr -ne "127.0.0.1") {
                        return $ipStr
                    }
                }
            }
        } catch {
            # Ignorar error
        }
        
        return "127.0.0.1"
        
    } catch {
        Write-Warning "No se pudo detectar IP local: $_"
        return "127.0.0.1"
    }
}

$localIp = Get-LocalIP
Write-Host "IP local detectada: $localIp" -ForegroundColor Cyan

# ============================================
# GENERACION DE CERTIFICADO (si no existe)
# ============================================

if (-not (Test-Path $keystorePath)) {
    Write-Host "Generando certificado autofirmado..." -ForegroundColor Yellow
    
    $dname = "CN=$localIp, OU=TFG, O=TFG, L=Local, ST=Local, C=ES"
    $san = "SAN=dns:localhost,ip:127.0.0.1,ip:$localIp"
    
    & $keytoolPath -genkeypair `
        -alias tfg-local `
        -keyalg RSA `
        -keysize 2048 `
        -validity 3650 `
        -storetype PKCS12 `
        -keystore $keystorePath `
        -storepass changeit `
        -keypass changeit `
        -dname $dname `
        -ext $san

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo generar el certificado local."
    }
    
    Write-Host "Certificado generado en $keystorePath" -ForegroundColor Green
}

# ============================================
# EJECUCION DEL SERVIDOR
# ============================================

Write-Host "Iniciando servidor TFG..." -ForegroundColor Green
Write-Host "Usuario: $currentUser" -ForegroundColor Cyan
Write-Host "Java: $JavaHome" -ForegroundColor Cyan
Write-Host "IP: $localIp" -ForegroundColor Cyan
Write-Host "Perfil: https" -ForegroundColor Cyan

Set-Location $projectRoot
& .\mvnw.cmd spring-boot:run "-Dspring-boot.run.profiles=https"
