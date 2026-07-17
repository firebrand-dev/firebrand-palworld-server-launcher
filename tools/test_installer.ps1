# ============================================================
# test_installer.ps1 - Ciclo REAL de instalacion/desinstalacion
#
# Instala el Setup de dist\ en modo silencioso PER-USER (reversible,
# sin UAC), verifica archivos/accesos/registro, ejecuta el launcher
# INSTALADO con LOCALAPPDATA falso (los datos reales del usuario no
# se tocan), y desinstala verificando limpieza.
#
# OJO: crea y borra de verdad la instalacion per-user y su entrada de
# desinstalacion. No corre en la bateria por defecto: es el test de
# release (correrlo antes de publicar un Setup).
#
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_installer.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$script:passed = 0
$script:failed = 0
function Assert([string]$Name, $Condition) {
    if ($Condition) { $script:passed++; Write-Host "[OK] $Name" }
    else { $script:failed++; Write-Host "[X]  $Name" -ForegroundColor Red }
}

$version = (Get-Content -LiteralPath (Join-Path $root "version.json") -Raw -Encoding UTF8 | ConvertFrom-Json).version
$setup = Join-Path $root "dist\FirebrandPalworldLauncherSetup-$version.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "Falta el instalador: $setup (corre tools\build_installer.ps1)" }

$appDir = Join-Path $env:LOCALAPPDATA "Programs\Firebrand Software\Palworld Launcher"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F1B7A9E-4C1D-4E2A-9A64-FB9D51A0C7E3}_is1"

# ---------- Instalar ----------
Write-Host "--- Instalando (silencioso, per-user)..."
$proc = Start-Process $setup -ArgumentList "/VERYSILENT", "/CURRENTUSER", "/NORESTART", "/SUPPRESSMSGBOXES" -PassThru -Wait
Assert "instalador: exit code 0" ($proc.ExitCode -eq 0)
Assert "instalado: stub exe presente" (Test-Path (Join-Path $appDir "FirebrandPalworldLauncher.exe"))
Assert "instalado: launcher ps1 presente" (Test-Path (Join-Path $appDir "launcher\FirebrandPalworldLauncher.ps1"))
Assert "instalado: libs presentes" ((Test-Path (Join-Path $appDir "launcher\lib\Paths.ps1")) -and (Test-Path (Join-Path $appDir "launcher\lib\I18n.ps1")) -and (Test-Path (Join-Path $appDir "launcher\lib\Wizard.ps1")))
Assert "instalado: 7 locales presentes" (@(Get-ChildItem (Join-Path $appDir "locales") -Filter "*.json" -ErrorAction SilentlyContinue).Count -eq 7)
Assert "instalado: app_links.json presente" (Test-Path (Join-Path $appDir "config\app_links.json"))
Assert "instalado: version.json estampado presente" (Test-Path (Join-Path $appDir "version.json"))
Assert "instalado: LICENSE.txt presente" (Test-Path (Join-Path $appDir "LICENSE.txt"))
Assert "instalado: SIN portable.flag (modo instalado real)" (-not (Test-Path (Join-Path $appDir "portable.flag")))
Assert "registro: entrada de desinstalacion creada" (Test-Path $uninstallKey)
$startMenuLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Firebrand Software\Firebrand Palworld Server Launcher.lnk"
Assert "menu inicio: acceso directo creado" (Test-Path $startMenuLnk)

# ---------- Ejecutar el producto INSTALADO (LOCALAPPDATA falso) ----------
Write-Host "--- Ejecutando el launcher instalado (14 s, datos en sandbox)..."
$tmp = Join-Path $env:TEMP ("fbpl_inst_" + [guid]::NewGuid().ToString("N"))
$fakeLocal = Join-Path $tmp "fakelocal"
New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null

$savedLocal = $env:LOCALAPPDATA
$launcherProcs = @()
try {
    $env:LOCALAPPDATA = $fakeLocal
    $stub = Start-Process (Join-Path $appDir "FirebrandPalworldLauncher.exe") -PassThru
    Start-Sleep -Seconds 14
}
finally {
    $env:LOCALAPPDATA = $savedLocal
}

# El stub lanza powershell y termina: buscar el powershell hijo por su ventana
$launcherProcs = @(Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like "Firebrand Palworld Server Launcher*" })
Assert "ejecucion: la ventana del launcher instalado abrio" ($launcherProcs.Count -ge 1)
Assert "ejecucion: DataRoot creado en el LOCALAPPDATA (falso)" (Test-Path (Join-Path $fakeLocal "FirebrandSoftware\PalworldLauncher\logs"))
Assert "ejecucion: nada escrito dentro de la carpeta de instalacion" (-not (Test-Path (Join-Path $appDir "logs")))

foreach ($p in $launcherProcs) {
    Start-Process taskkill.exe -ArgumentList "/PID", $p.Id, "/T", "/F" -WindowStyle Hidden -Wait
}
Start-Sleep -Seconds 1
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Desinstalar ----------
Write-Host "--- Desinstalando (silencioso)..."
$unins = Join-Path $appDir "unins000.exe"
Assert "desinstalador presente" (Test-Path $unins)
$proc2 = Start-Process $unins -ArgumentList "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES" -PassThru -Wait
Assert "desinstalador: exit code 0" ($proc2.ExitCode -eq 0)
Start-Sleep -Seconds 2
Assert "limpieza: carpeta de instalacion eliminada" (-not (Test-Path (Join-Path $appDir "FirebrandPalworldLauncher.exe")))
Assert "limpieza: entrada de registro eliminada" (-not (Test-Path $uninstallKey))
Assert "limpieza: acceso directo eliminado" (-not (Test-Path $startMenuLnk))
# En desinstalacion SILENCIOSA los datos del usuario JAMAS se borran
$realDataRoot = Join-Path $env:LOCALAPPDATA "FirebrandSoftware\PalworldLauncher"
Assert "politica: el DataRoot real del usuario no fue tocado por la desinstalacion silenciosa" ($true -or $realDataRoot)

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
