$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$SteamCmdDir = Join-Path $Root "steamcmd"
$ServerDir = Join-Path $Root "server"
$BackupsDir = Join-Path $Root "backups"
$LogsDir = Join-Path $Root "logs"
$ConfigDir = Join-Path $ServerDir "Pal\Saved\Config\WindowsServer"
$ConfigFile = Join-Path $ConfigDir "PalWorldSettings.ini"
$DefaultConfig = Join-Path $ServerDir "DefaultPalWorldSettings.ini"

Write-Host "=== Instalador Palworld Dedicated Server ===" -ForegroundColor Cyan

foreach ($Dir in @($SteamCmdDir, $ServerDir, $BackupsDir, $LogsDir)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
}

$SteamCmdExe = Join-Path $SteamCmdDir "steamcmd.exe"
if (-not (Test-Path $SteamCmdExe)) {
    Write-Host "Descargando SteamCMD..."
    $ZipPath = Join-Path $env:TEMP "steamcmd.zip"
    Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $SteamCmdDir -Force
    Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Instalando/actualizando Palworld Dedicated Server..."
& $SteamCmdExe +force_install_dir $ServerDir +login anonymous +app_update 2394010 validate +quit
if ($LASTEXITCODE -ne 0) {
    throw "SteamCMD finalizo con codigo $LASTEXITCODE"
}

# Ejecutar brevemente una vez para que Unreal cree la estructura Saved\Config.
$ServerExe = Join-Path $ServerDir "PalServer.exe"
if (-not (Test-Path $ServerExe)) {
    throw "No se encontro PalServer.exe despues de instalar."
}

if (-not (Test-Path $ConfigDir)) {
    Write-Host "Generando carpetas iniciales..."
    $p = Start-Process -FilePath $ServerExe `
        -ArgumentList "-useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS" `
        -WorkingDirectory $ServerDir -PassThru
    Start-Sleep -Seconds 12
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null

$ConfigNeedsRepair = $true
if (Test-Path $ConfigFile) {
    $ExistingConfig = [IO.File]::ReadAllText($ConfigFile)
    $ConfigNeedsRepair = -not ($ExistingConfig -match '(?s)\[/Script/Pal\.PalGameWorldSettings\].*OptionSettings\s*=\s*\(.*\)')
}

if ($ConfigNeedsRepair) {
    if (Test-Path $ConfigFile) {
        Copy-Item $ConfigFile ($ConfigFile + ".broken_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")) -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $DefaultConfig) {
        Copy-Item $DefaultConfig $ConfigFile -Force
    } else {
        @'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(Difficulty=None,DayTimeSpeedRate=1.000000,NightTimeSpeedRate=1.000000,ExpRate=1.000000,PalCaptureRate=1.000000,PalSpawnNumRate=1.000000,PalDamageRateAttack=1.000000,PalDamageRateDefense=1.000000,PlayerDamageRateAttack=1.000000,PlayerDamageRateDefense=1.000000,PlayerStomachDecreaceRate=1.000000,PlayerStaminaDecreaceRate=1.000000,PlayerAutoHPRegeneRate=1.000000,PlayerAutoHpRegeneRateInSleep=1.000000,PalStomachDecreaceRate=1.000000,PalStaminaDecreaceRate=1.000000,PalAutoHPRegeneRate=1.000000,PalAutoHpRegeneRateInSleep=1.000000,BuildObjectDamageRate=1.000000,BuildObjectDeteriorationDamageRate=1.000000,CollectionDropRate=1.000000,CollectionObjectHpRate=1.000000,CollectionObjectRespawnSpeedRate=1.000000,EnemyDropItemRate=1.000000,DeathPenalty=All,bEnablePlayerToPlayerDamage=False,bEnableFriendlyFire=False,bEnableInvaderEnemy=True,bActiveUNKO=False,bEnableAimAssistPad=True,bEnableAimAssistKeyboard=False,DropItemMaxNum=3000,DropItemMaxNum_UNKO=100,BaseCampMaxNum=128,BaseCampWorkerMaxNum=15,DropItemAliveMaxHours=1.000000,bAutoResetGuildNoOnlinePlayers=False,AutoResetGuildTimeNoOnlinePlayers=72.000000,GuildPlayerMaxNum=20,PalEggDefaultHatchingTime=72.000000,WorkSpeedRate=1.000000,bIsMultiplay=False,bIsPvP=False,bCanPickupOtherGuildDeathPenaltyDrop=False,bEnableNonLoginPenalty=True,bEnableFastTravel=True,bIsStartLocationSelectByMap=True,bExistPlayerAfterLogout=False,bEnableDefenseOtherGuildPlayer=False,CoopPlayerMaxNum=4,ServerPlayerMaxNum=32,ServerName="Mi servidor Palworld",ServerDescription="Servidor privado administrado con Palworld Server Manager",AdminPassword="CAMBIAR_ADMIN",ServerPassword="",PublicPort=8211,PublicIP="",RCONEnabled=False,RCONPort=25575,Region="",bUseAuth=True,BanListURL="https://api.palworldgame.com/api/banlist.txt")
'@ | Set-Content -Path $ConfigFile -Encoding UTF8
    }
}

# Habilitar clientes Xbox/Microsoft Store en la configuración.
$ConfigText = [IO.File]::ReadAllText($ConfigFile)
if ($ConfigText -match 'AllowConnectPlatform\s*=') {
    $ConfigText = [regex]::Replace($ConfigText, 'AllowConnectPlatform\s*=\s*[^,\)]+', 'AllowConnectPlatform=Xbox', 1)
} else {
    $LastParen = $ConfigText.LastIndexOf(')')
    if ($LastParen -ge 0) { $ConfigText = $ConfigText.Insert($LastParen, ',AllowConnectPlatform=Xbox') }
}
[IO.File]::WriteAllText($ConfigFile, $ConfigText, [Text.UTF8Encoding]::new($false))

# Regla de firewall. Puede requerir elevacion.
try {
    if (-not (Get-NetFirewallRule -DisplayName "Palworld Dedicated Server UDP 8211" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Palworld Dedicated Server UDP 8211" `
            -Direction Inbound -Action Allow -Protocol UDP -LocalPort 8211 | Out-Null
    }
} catch {
    Write-Warning "No se pudo crear automaticamente la regla de Firewall. Ejecuta este instalador como Administrador."
}

Write-Host ""
Write-Host "INSTALACION COMPLETA" -ForegroundColor Green
Write-Host "Servidor: $ServerDir"
Write-Host "Configuracion: $ConfigFile"
Write-Host "Ejecuta ABRIR_LAUNCHER.bat"
