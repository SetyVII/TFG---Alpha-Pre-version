param(
    [string]$JavaHome = $env:JAVA_HOME
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$keystorePath = Join-Path $projectRoot "src\main\resources\local-dev.p12"

if (-not $JavaHome) {
    $fallbackJavaHome = "C:\Users\sebastian.vilavila\.jdks\ms-21.0.10"
    if (Test-Path $fallbackJavaHome) {
        $JavaHome = $fallbackJavaHome
    }
}

if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome "bin\java.exe"))) {
    throw "No se encontró JAVA_HOME válido. Configura JAVA_HOME y vuelve a ejecutar."
}

$env:JAVA_HOME = $JavaHome
$env:Path = "$JavaHome\bin;$env:Path"
$keytoolPath = Join-Path $JavaHome "bin\keytool.exe"

if (-not (Test-Path $keytoolPath)) {
    throw "No se encontró keytool.exe en $JavaHome\bin"
}

if (-not (Test-Path $keystorePath)) {
    $localIp = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual `
        | Where-Object {
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -ne "127.0.0.1"
        } | Select-Object -First 1 -ExpandProperty IPAddress)

    if (-not $localIp) {
        $localIp = "127.0.0.1"
    }

    & $keytoolPath -genkeypair `
        -alias tfg-local `
        -keyalg RSA `
        -keysize 2048 `
        -validity 3650 `
        -storetype PKCS12 `
        -keystore $keystorePath `
        -storepass changeit `
        -keypass changeit `
        -dname "CN=$localIp, OU=TFG, O=TFG, L=Local, ST=Local, C=ES" `
        -ext "SAN=dns:localhost,ip:127.0.0.1,ip:$localIp"

    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo generar el certificado local."
    }
}

Set-Location $projectRoot
& .\mvnw.cmd spring-boot:run "-Dspring-boot.run.profiles=https"
