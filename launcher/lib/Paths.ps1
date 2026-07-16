# ============================================================
# Paths.ps1 - Resolucion de rutas del Firebrand Palworld Server Launcher
#
# Tres raices:
#   InstallRoot: donde vive el codigo del launcher (solo lectura si esta instalado)
#   DataRoot:    datos del usuario del launcher (settings, logs, secretos)
#   ServerRoot:  servidor Palworld + mundos + backups (elegida por el usuario)
#
# Modo portable: si existe "portable.flag" junto a la carpeta launcher\,
# todo funciona como el layout clasico (todo hermano de launcher\).
#
# Este modulo NO usa UI ni variables globales: es puro y testeable headless
# (tools\test_paths.ps1). Compatible con Windows PowerShell 5.1.
# ============================================================

function Get-LauncherPaths {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDir,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    $installRoot = Split-Path -Parent $ScriptDir
    $isPortable = Test-Path -LiteralPath (Join-Path $installRoot "portable.flag")

    $settingsCorrupt = $false

    if ($isPortable) {
        $dataRoot = $installRoot
        $serverRoot = $installRoot
    }
    else {
        $dataRoot = Join-Path $LocalAppData "FirebrandSoftware\PalworldLauncher"
        $serverRoot = $null

        # 1) ServerRoot persistido por el usuario. Se respeta aunque el path no
        #    exista en este momento (p.ej. disco externo desconectado): perder
        #    la referencia seria peor que mostrar "servidor no encontrado".
        $settingsFile = Join-Path $dataRoot "launcher-settings.json"
        if (Test-Path -LiteralPath $settingsFile) {
            try {
                $config = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
                if ($config.ServerRoot) {
                    $serverRoot = [string]$config.ServerRoot
                }
            }
            catch {
                # El llamador decide como avisar: aca no hay UI.
                $settingsCorrupt = $true
            }
        }

        # 2) Layout viejo pre-Firebrand: el server ya vive junto al launcher.
        if (-not $serverRoot) {
            if (Test-Path -LiteralPath (Join-Path $installRoot "server\PalServer.exe")) {
                $serverRoot = $installRoot
            }
        }

        # 3) Default para instalaciones nuevas.
        if (-not $serverRoot) {
            $serverRoot = "C:\PalworldServer"
        }
    }

    # Normalizar (barras '/', '..', barra final): el filtro de procesos compara
    # rutas por prefijo de string y una barra distinta dejaria al server propio
    # invisible para el launcher. Solo si es absoluta: una ruta relativa en el
    # JSON no debe resolverse contra el directorio de trabajo actual.
    try {
        if ([IO.Path]::IsPathRooted($serverRoot)) {
            $serverRoot = [IO.Path]::GetFullPath($serverRoot)
            if ($serverRoot.Length -gt 3) {
                # Sin barra final (pero "C:\" queda intacto)
                $serverRoot = $serverRoot.TrimEnd('\')
            }
        }
    }
    catch {}

    return @{
        IsPortable      = $isPortable
        InstallRoot     = $installRoot
        DataRoot        = $dataRoot
        ServerRoot      = $serverRoot
        ServerDir       = Join-Path $serverRoot "server"
        BackupDir       = Join-Path $serverRoot "backups"
        SteamCmdDir     = Join-Path $serverRoot "steamcmd"
        LogsDir         = Join-Path $dataRoot "logs"
        SettingsFile    = Join-Path $dataRoot "launcher-settings.json"
        SettingsCorrupt = $settingsCorrupt
    }
}

# Archivos de configuracion del layout viejo que todavia no existen en DataRoot.
function Get-OldLayoutMigrationFiles {
    param(
        [Parameter(Mandatory=$true)][string]$InstallRoot,
        [Parameter(Mandatory=$true)][string]$DataRoot
    )

    if ($InstallRoot -eq $DataRoot) {
        return @()
    }

    $names = @(
        "launcher-settings.json",
        "automation-settings.json",
        "gemini-key.dat",
        "palworld_tips.txt",
        "custom_messages.txt"
    )

    $pending = @()
    foreach ($name in $names) {
        $old = Join-Path $InstallRoot $name
        $new = Join-Path $DataRoot $name
        if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)) {
            $pending += $old
        }
    }

    # Sin coma: el llamador siempre envuelve con @(), y ",$pending" haria que
    # @() viera UN elemento (el array adentro) en vez de N rutas.
    return $pending
}

# Copia la configuracion vieja a DataRoot SIN borrar los originales, y si el
# server vive junto al launcher deja ServerRoot persistido apuntando ahi
# (los mundos y backups quedan exactamente donde estaban).
function Invoke-LauncherDataMigration {
    param(
        [Parameter(Mandatory=$true)][string]$InstallRoot,
        [Parameter(Mandatory=$true)][string]$DataRoot
    )

    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

    $settingsFile = Join-Path $DataRoot "launcher-settings.json"
    $settingsExistedBefore = Test-Path -LiteralPath $settingsFile

    $copied = @()
    foreach ($old in (Get-OldLayoutMigrationFiles -InstallRoot $InstallRoot -DataRoot $DataRoot)) {
        $target = Join-Path $DataRoot ([IO.Path]::GetFileName($old))
        Copy-Item -LiteralPath $old -Destination $target -Force
        $copied += $target
    }

    # Inyectar ServerRoot SOLO si el settings de DataRoot nacio de esta
    # migracion (o no existe): un settings preexistente no era parte de la
    # migracion y no se toca.
    if (-not $settingsExistedBefore -and (Test-Path -LiteralPath (Join-Path $InstallRoot "server\PalServer.exe"))) {
        $config = $null
        if (Test-Path -LiteralPath $settingsFile) {
            try { $config = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch {}
        }
        if ($null -eq $config) {
            $config = [pscustomobject]@{}
        }
        if (-not ($config.PSObject.Properties.Name -contains "ServerRoot")) {
            $config | Add-Member -NotePropertyName ServerRoot -NotePropertyValue $InstallRoot -Force
        }
        $config | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    }

    return $copied
}

# ------------------------------------------------------------
# Helpers de settings (puros, testeables)
# ------------------------------------------------------------

# El modo de reinicio se PERSISTE como clave neutra ('disabled'|'interval'|'daily')
# para que traducir la UI nunca rompa los settings guardados. El orden del array
# corresponde al indice del combo en la UI.
$RestartModeKeys = @("disabled", "interval", "daily")

function ConvertTo-RestartModeKey {
    param([string]$Value)

    switch ($Value) {
        # Valores legacy (v9 y anteriores guardaban el texto del combo en espanol)
        "Desactivado"        { return "disabled" }
        "Cada ciertas horas" { return "interval" }
        "Hora fija diaria"   { return "daily" }
        # Claves neutras actuales
        "disabled"           { return "disabled" }
        "interval"           { return "interval" }
        "daily"              { return "daily" }
    }

    return "disabled"
}
