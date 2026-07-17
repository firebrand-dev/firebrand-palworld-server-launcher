# ============================================================
# test_paths.ps1 - Tests headless de resolucion de rutas y migracion
# No abre UI ni toca la instalacion real: todo ocurre en %TEMP%.
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_paths.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "launcher\lib\Paths.ps1")

$tmp = Join-Path $env:TEMP ("fbpl_test_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$script:passed = 0
$script:failed = 0

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

# ---------- Caso 1: modo portable ----------
$portableRoot = Join-Path $tmp "portable\CarpetaElegida"
New-Item -ItemType Directory -Path (Join-Path $portableRoot "launcher") -Force | Out-Null
Set-Content -Path (Join-Path $portableRoot "portable.flag") -Value "portable" -Encoding UTF8

$p = Get-LauncherPaths -ScriptDir (Join-Path $portableRoot "launcher")
Assert "portable: IsPortable activo" $p.IsPortable
Assert "portable: DataRoot = InstallRoot" ($p.DataRoot -eq $portableRoot)
Assert "portable: ServerRoot = InstallRoot" ($p.ServerRoot -eq $portableRoot)
Assert "portable: server/ hermano del launcher" ($p.ServerDir -eq (Join-Path $portableRoot "server"))
Assert "portable: backups/ hermano del launcher" ($p.BackupDir -eq (Join-Path $portableRoot "backups"))
Assert "portable: logs/ hermano del launcher" ($p.LogsDir -eq (Join-Path $portableRoot "logs"))
Assert "portable: steamcmd/ hermano del launcher" ($p.SteamCmdDir -eq (Join-Path $portableRoot "steamcmd"))

# ---------- Caso 2: instalado fresco (sin settings, sin layout viejo) ----------
$installRoot = Join-Path $tmp "installed\App"
New-Item -ItemType Directory -Path (Join-Path $installRoot "launcher") -Force | Out-Null
$fakeLocal = Join-Path $tmp "localappdata"

$p2 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal
Assert "instalado: NO portable" (-not $p2.IsPortable)
Assert "instalado: DataRoot bajo LOCALAPPDATA\FirebrandSoftware" ($p2.DataRoot -eq (Join-Path $fakeLocal "FirebrandSoftware\PalworldLauncher"))
Assert "instalado: ServerRoot default C:\PalworldServer" ($p2.ServerRoot -eq "C:\PalworldServer")
Assert "instalado: LogsDir bajo DataRoot" ($p2.LogsDir -eq (Join-Path $p2.DataRoot "logs"))
$tocaInstall = (
    $p2.DataRoot.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $p2.LogsDir.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $p2.BackupDir.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $p2.ServerDir.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $p2.SteamCmdDir.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)
)
Assert "instalado: NINGUNA ruta de escritura apunta a InstallRoot" (-not $tocaInstall)

# ---------- Caso 3: instalado con ServerRoot persistido ----------
New-Item -ItemType Directory -Path $p2.DataRoot -Force | Out-Null
@{ ServerRoot = "D:\MisJuegos\Palworld" } | ConvertTo-Json |
    Set-Content -Path $p2.SettingsFile -Encoding UTF8

$p3 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal
Assert "settings: respeta ServerRoot persistido (aunque el path no exista)" ($p3.ServerRoot -eq "D:\MisJuegos\Palworld")
Assert "settings: ServerDir cuelga del ServerRoot" ($p3.ServerDir -eq "D:\MisJuegos\Palworld\server")
Assert "settings: BackupDir cuelga del ServerRoot" ($p3.BackupDir -eq "D:\MisJuegos\Palworld\backups")
Assert "settings: SteamCmdDir cuelga del ServerRoot" ($p3.SteamCmdDir -eq "D:\MisJuegos\Palworld\steamcmd")
Remove-Item $p3.SettingsFile -Force

# ---------- Caso 4: layout viejo pre-Firebrand + migracion ----------
$oldRoot = Join-Path $tmp "old\PalWorld_S"
New-Item -ItemType Directory -Path (Join-Path $oldRoot "launcher") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $oldRoot "server") -Force | Out-Null
Set-Content -Path (Join-Path $oldRoot "server\PalServer.exe") -Value "fake" -Encoding UTF8
Set-Content -Path (Join-Path $oldRoot "launcher-settings.json") -Value '{"AutoBackup":true,"RestartMode":"Hora fija diaria"}' -Encoding UTF8
Set-Content -Path (Join-Path $oldRoot "custom_messages.txt") -Value "hola" -Encoding UTF8
$fakeLocal2 = Join-Path $tmp "localappdata2"

$p4 = Get-LauncherPaths -ScriptDir (Join-Path $oldRoot "launcher") -LocalAppData $fakeLocal2
Assert "layout viejo: ServerRoot = carpeta vieja (mundos quedan donde estan)" ($p4.ServerRoot -eq $oldRoot)

$pending = @(Get-OldLayoutMigrationFiles -InstallRoot $p4.InstallRoot -DataRoot $p4.DataRoot)
Assert "layout viejo: detecta 2 archivos migrables" ($pending.Count -eq 2)

Invoke-LauncherDataMigration -InstallRoot $p4.InstallRoot -DataRoot $p4.DataRoot | Out-Null
Assert "migracion: settings copiado a DataRoot" (Test-Path (Join-Path $p4.DataRoot "launcher-settings.json"))
Assert "migracion: mensajes copiados a DataRoot" (Test-Path (Join-Path $p4.DataRoot "custom_messages.txt"))
Assert "migracion: original de settings intacto" (Test-Path (Join-Path $oldRoot "launcher-settings.json"))
Assert "migracion: original de mensajes intacto" (Test-Path (Join-Path $oldRoot "custom_messages.txt"))

$migrated = Get-Content (Join-Path $p4.DataRoot "launcher-settings.json") -Raw | ConvertFrom-Json
Assert "migracion: ServerRoot inyectado apuntando al layout viejo" ($migrated.ServerRoot -eq $oldRoot)
Assert "migracion: settings previos preservados (AutoBackup)" ([bool]$migrated.AutoBackup)

$pending2 = @(Get-OldLayoutMigrationFiles -InstallRoot $p4.InstallRoot -DataRoot $p4.DataRoot)
Assert "migracion: idempotente (no queda nada pendiente)" ($pending2.Count -eq 0)

$p5 = Get-LauncherPaths -ScriptDir (Join-Path $oldRoot "launcher") -LocalAppData $fakeLocal2
Assert "post-migracion: ServerRoot resuelto desde settings" ($p5.ServerRoot -eq $oldRoot)

# ---------- Caso 5: claves neutras de RestartMode ----------
Assert "modo: 'Desactivado' legacy -> disabled" ((ConvertTo-RestartModeKey "Desactivado") -eq "disabled")
Assert "modo: 'Cada ciertas horas' legacy -> interval" ((ConvertTo-RestartModeKey "Cada ciertas horas") -eq "interval")
Assert "modo: 'Hora fija diaria' legacy -> daily" ((ConvertTo-RestartModeKey "Hora fija diaria") -eq "daily")
Assert "modo: clave nueva 'daily' pasa igual" ((ConvertTo-RestartModeKey "daily") -eq "daily")
Assert "modo: valor desconocido -> disabled" ((ConvertTo-RestartModeKey "cualquier cosa") -eq "disabled")
Assert "modo: vacio -> disabled" ((ConvertTo-RestartModeKey "") -eq "disabled")
Assert "modo: orden del array = indices del combo" (($RestartModeKeys[0] -eq "disabled") -and ($RestartModeKeys[1] -eq "interval") -and ($RestartModeKeys[2] -eq "daily"))

# ---------- Caso 6: robustez de settings ----------
# 6a: ServerRoot con barras '/' y basura se normaliza (el filtro de procesos
#     compara por prefijo de string, una barra distinta lo dejaria ciego)
New-Item -ItemType Directory -Path $p2.DataRoot -Force | Out-Null
'{"ServerRoot":"D:/juegos/pal//server_root/"}' | Set-Content -Path $p2.SettingsFile -Encoding UTF8
$p6 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal
Assert "normaliza: barras / y dobles -> ruta canonica" ($p6.ServerRoot -eq "D:\juegos\pal\server_root")
Remove-Item $p2.SettingsFile -Force

# 6b: JSON corrupto -> flag SettingsCorrupt y default (el launcher avisa y respalda)
'{esto no es json' | Set-Content -Path $p2.SettingsFile -Encoding UTF8
$p7 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal
Assert "corrupto: SettingsCorrupt = true" $p7.SettingsCorrupt
Assert "corrupto: ServerRoot cae al default" ($p7.ServerRoot -eq "C:\PalworldServer")
Remove-Item $p2.SettingsFile -Force

# 6c: sin settings -> SettingsCorrupt = false
Assert "sano: SettingsCorrupt = false sin settings" (-not $p2.SettingsCorrupt)

# 6d: la migracion NO toca un settings preexistente en DataRoot
$oldRoot2 = Join-Path $tmp "old2\PalWorld_S"
New-Item -ItemType Directory -Path (Join-Path $oldRoot2 "launcher") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $oldRoot2 "server") -Force | Out-Null
Set-Content -Path (Join-Path $oldRoot2 "server\PalServer.exe") -Value "fake" -Encoding UTF8
Set-Content -Path (Join-Path $oldRoot2 "custom_messages.txt") -Value "viejo" -Encoding UTF8
$fakeLocal3 = Join-Path $tmp "localappdata3"
$pm = Get-LauncherPaths -ScriptDir (Join-Path $oldRoot2 "launcher") -LocalAppData $fakeLocal3
New-Item -ItemType Directory -Path $pm.DataRoot -Force | Out-Null
'{"ServerRoot":"E:\\otro"}' | Set-Content -Path $pm.SettingsFile -Encoding UTF8
Invoke-LauncherDataMigration -InstallRoot $pm.InstallRoot -DataRoot $pm.DataRoot | Out-Null
$afterMigration = Get-Content $pm.SettingsFile -Raw | ConvertFrom-Json
Assert "migracion: settings preexistente en DataRoot queda intacto" ($afterMigration.ServerRoot -eq "E:\otro")
Assert "migracion: los demas archivos pendientes si se copian" (Test-Path (Join-Path $pm.DataRoot "custom_messages.txt"))

# ---------- Caso 7: adopcion de server existente (wizard Fase 3) ----------
# 7a: layout clasico (carpeta con server\PalServer.exe)
$adoptClassic = Join-Path $tmp "adopt\clasico"
New-Item -ItemType Directory -Path (Join-Path $adoptClassic "server") -Force | Out-Null
Set-Content -Path (Join-Path $adoptClassic "server\PalServer.exe") -Value "fake" -Encoding UTF8
$sel1 = Resolve-ExistingServerSelection -Folder $adoptClassic
Assert "adopcion: layout clasico detectado" $sel1.Found
Assert "adopcion: clasico ServerRoot = carpeta elegida" ($sel1.ServerRoot -eq $adoptClassic)
Assert "adopcion: clasico ServerDir = <carpeta>\server" ($sel1.ServerDir -eq (Join-Path $adoptClassic "server"))

# 7b: PalServer.exe directo en la carpeta (instalacion "a mano")
$adoptDirect = Join-Path $tmp "adopt\directo"
New-Item -ItemType Directory -Path $adoptDirect -Force | Out-Null
Set-Content -Path (Join-Path $adoptDirect "PalServer.exe") -Value "fake" -Encoding UTF8
$sel2 = Resolve-ExistingServerSelection -Folder $adoptDirect
Assert "adopcion: exe directo detectado" $sel2.Found
Assert "adopcion: directo ServerDir = la misma carpeta" ($sel2.ServerDir -eq $adoptDirect)
Assert "adopcion: directo ServerRoot = la misma carpeta" ($sel2.ServerRoot -eq $adoptDirect)

# 7c: carpeta sin server
$adoptEmpty = Join-Path $tmp "adopt\vacia"
New-Item -ItemType Directory -Path $adoptEmpty -Force | Out-Null
$sel3 = Resolve-ExistingServerSelection -Folder $adoptEmpty
Assert "adopcion: carpeta sin server -> Found=false" (-not $sel3.Found)
$sel4 = Resolve-ExistingServerSelection -Folder (Join-Path $tmp "no\existe\nada")
Assert "adopcion: carpeta inexistente -> Found=false" (-not $sel4.Found)

# 7d: override de ServerDir persistido (server adoptado con exe directo)
$fakeLocal4 = Join-Path $tmp "localappdata4"
$dr4 = Join-Path $fakeLocal4 "FirebrandSoftware\PalworldLauncher"
New-Item -ItemType Directory -Path $dr4 -Force | Out-Null
('{"ServerRoot":"' + ($adoptDirect -replace '\\','\\\\') + '","ServerDir":"' + ($adoptDirect -replace '\\','\\\\') + '"}') |
    Set-Content -Path (Join-Path $dr4 "launcher-settings.json") -Encoding UTF8
$p8 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal4
Assert "override: ServerDir respetado desde settings" ($p8.ServerDir -eq $adoptDirect)
Assert "override: BackupDir sigue colgando de ServerRoot" ($p8.BackupDir -eq (Join-Path $adoptDirect "backups"))

# 7e: sin override -> ServerDir clasico
Remove-Item (Join-Path $dr4 "launcher-settings.json") -Force
('{"ServerRoot":"' + ($adoptClassic -replace '\\','\\\\') + '"}') |
    Set-Content -Path (Join-Path $dr4 "launcher-settings.json") -Encoding UTF8
$p9 = Get-LauncherPaths -ScriptDir (Join-Path $installRoot "launcher") -LocalAppData $fakeLocal4
Assert "sin override: ServerDir = <ServerRoot>\server" ($p9.ServerDir -eq (Join-Path $adoptClassic "server"))

# ---------- Limpieza ----------
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
