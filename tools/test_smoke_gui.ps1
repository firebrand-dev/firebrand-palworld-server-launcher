# ============================================================
# test_smoke_gui.ps1 - Smoke test REAL de la GUI en dos modos.
# Copia el launcher a sandboxes en %TEMP%, lo ejecuta de verdad unos
# segundos y verifica en el filesystem:
#   - portable:  datos junto al launcher (layout clasico)
#   - instalado: datos en LOCALAPPDATA (falso), server en ServerRoot,
#                y la carpeta de instalacion queda INTOCADA
# Abre 2 ventanas brevemente; se cierran solas.
#
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_smoke_gui.ps1
# ============================================================

param([int]$WaitSeconds = 14)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SmokeWin32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@

# True si el proceso tiene una ventana visible con EXACTAMENTE ese titulo.
function Test-ProcessHasWindowTitle([int]$ProcessId, [string]$Title) {
    $script:__winFound = $false
    $callback = {
        param($hWnd, $lParam)
        $windowPid = 0
        [SmokeWin32]::GetWindowThreadProcessId($hWnd, [ref]$windowPid) | Out-Null
        if ($windowPid -eq $ProcessId -and [SmokeWin32]::IsWindowVisible($hWnd)) {
            $sb = New-Object Text.StringBuilder 512
            [SmokeWin32]::GetWindowTextW($hWnd, $sb, 512) | Out-Null
            if ($sb.ToString() -eq $Title) { $script:__winFound = $true }
        }
        return $true
    }
    [SmokeWin32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $script:__winFound
}

$script:passed = 0
$script:failed = 0

# Titulo del wizard en espanol (el idioma que resuelve el sandbox en esta PC)
$wizardTitle = (Get-Content -LiteralPath (Join-Path $root "locales\es.json") -Raw -Encoding UTF8 | ConvertFrom-Json)."wizard.title"

# Copia el launcher COMPLETO (codigo + locales + version + config) a un sandbox
function Copy-LauncherTo([string]$TargetRoot) {
    New-Item -ItemType Directory -Path (Join-Path $TargetRoot "launcher") -Force | Out-Null
    Copy-Item (Join-Path $root "launcher\*") (Join-Path $TargetRoot "launcher") -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $TargetRoot "locales") -Force | Out-Null
    Copy-Item (Join-Path $root "locales\*.json") (Join-Path $TargetRoot "locales") -Force
    New-Item -ItemType Directory -Path (Join-Path $TargetRoot "config") -Force | Out-Null
    Copy-Item (Join-Path $root "config\app_links.json") (Join-Path $TargetRoot "config") -Force
    Copy-Item (Join-Path $root "version.json") $TargetRoot -Force
}

function Assert([string]$Name, $Condition) {
    if ($Condition) {
        $script:passed++
        Write-Host "[OK] $Name"
    }
    else {
        $script:failed++
        Write-Host "[X]  $Name" -ForegroundColor Red
    }
}

function Start-LauncherSandbox([string]$LauncherPs1) {
    return Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$LauncherPs1`"" `
        -PassThru
}

function Stop-LauncherSandbox($Process) {
    # taskkill via Start-Process: sin capturar stderr (con EAP=Stop, redirigir
    # stderr de un exe nativo en PS 5.1 lanza NativeCommandError terminante).
    if ($Process -and -not $Process.HasExited) {
        Start-Process -FilePath "taskkill.exe" `
            -ArgumentList "/PID", $Process.Id, "/T", "/F" `
            -WindowStyle Hidden -Wait
    }
    Start-Sleep -Seconds 1
}

$tmp = Join-Path $env:TEMP ("fbpl_gui_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$proc = $null
$proc2 = $null

try {
    # ================= MODO PORTABLE (con server ya instalado) =================
    $portableRoot = Join-Path $tmp "portable"
    Copy-LauncherTo $portableRoot
    Set-Content -Path (Join-Path $portableRoot "portable.flag") -Value "portable" -Encoding UTF8
    # Server "instalado" (fake): con server presente, el INI SI debe crearse al arrancar
    New-Item -ItemType Directory -Path (Join-Path $portableRoot "server") -Force | Out-Null
    Set-Content -Path (Join-Path $portableRoot "server\PalServer.exe") -Value "fake" -Encoding UTF8

    Write-Host "--- Ejecutando launcher en modo PORTABLE ($WaitSeconds s)..."
    $proc = Start-LauncherSandbox (Join-Path $portableRoot "launcher\FirebrandPalworldLauncher.ps1")
    Start-Sleep -Seconds $WaitSeconds
    $stillRunning = -not $proc.HasExited
    $wizardVisiblePortable = Test-ProcessHasWindowTitle -ProcessId $proc.Id -Title $wizardTitle
    Stop-LauncherSandbox $proc

    Assert "portable: el launcher quedo corriendo (no crasheo al inicio)" $stillRunning
    Assert "portable: logs\ creado junto al launcher" (Test-Path (Join-Path $portableRoot "logs"))
    Assert "portable: con server presente, INI creado/reparado al arrancar" (Test-Path (Join-Path $portableRoot "server\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"))
    Assert "portable: el wizard NO aparece (modo portable con server)" (-not $wizardVisiblePortable)

    # ================= MODO INSTALADO (sin server: debe aparecer el wizard) =================
    $installRoot = Join-Path $tmp "installed"
    $fakeLocal = Join-Path $tmp "fakelocal"
    $serverRoot = Join-Path $tmp "serverroot"
    Copy-LauncherTo $installRoot

    # Pre-sembrar ServerRoot para no tocar el C:\PalworldServer real durante el test
    $dataRoot = Join-Path $fakeLocal "FirebrandSoftware\PalworldLauncher"
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    @{ ServerRoot = $serverRoot } | ConvertTo-Json | Set-Content -Path (Join-Path $dataRoot "launcher-settings.json") -Encoding UTF8

    $installSnapshotBefore = @(Get-ChildItem -Path $installRoot -Recurse -Force | ForEach-Object { $_.FullName }) | Sort-Object

    Write-Host "--- Ejecutando launcher en modo INSTALADO ($WaitSeconds s)..."
    $savedLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $fakeLocal
        $proc2 = Start-LauncherSandbox (Join-Path $installRoot "launcher\FirebrandPalworldLauncher.ps1")
        Start-Sleep -Seconds $WaitSeconds
    }
    finally {
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    $stillRunning2 = -not $proc2.HasExited
    $wizardVisibleInstalled = Test-ProcessHasWindowTitle -ProcessId $proc2.Id -Title $wizardTitle
    Stop-LauncherSandbox $proc2

    $installSnapshotAfter = @(Get-ChildItem -Path $installRoot -Recurse -Force | ForEach-Object { $_.FullName }) | Sort-Object
    $installDiff = @(Compare-Object -ReferenceObject $installSnapshotBefore -DifferenceObject $installSnapshotAfter)

    Assert "instalado: el launcher quedo corriendo (no crasheo al inicio)" $stillRunning2
    Assert "instalado: logs\ creado en DataRoot (LOCALAPPDATA)" (Test-Path (Join-Path $dataRoot "logs"))
    # Sin server instalado, el primer arranque NO debe materializar el arbol
    # del server (hallazgo de la revision Fase 1): recien se crea con una
    # accion del usuario (instalar/actualizar/guardar configuracion).
    Assert "instalado: sin server, NO se crea el arbol del ServerRoot al arrancar" (-not (Test-Path (Join-Path $serverRoot "server")))
    Assert "instalado: sin server, el WIZARD aparece automaticamente" $wizardVisibleInstalled
    Assert "instalado: la carpeta de instalacion quedo INTOCADA (0 archivos nuevos)" ($installDiff.Count -eq 0)
    if ($installDiff.Count -gt 0) {
        $installDiff | ForEach-Object { Write-Host ("     diff: " + $_.SideIndicator + " " + $_.InputObject) }
    }
}
finally {
    # Limpieza SOLO por PID de los procesos que este test lanzo: jamas barrer
    # por nombre/titulo (podria matar un launcher real abierto por el usuario).
    foreach ($sandboxProc in @($proc, $proc2)) {
        Stop-LauncherSandbox $sandboxProc
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
