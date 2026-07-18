Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ErrorActionPreference = "Stop"

# Resolucion de rutas: InstallRoot (codigo) / DataRoot (datos del usuario) /
# ServerRoot (server + mundos + backups). Ver launcher\lib\Paths.ps1.
. (Join-Path $PSScriptRoot "lib\Paths.ps1")
. (Join-Path $PSScriptRoot "lib\I18n.ps1")
. (Join-Path $PSScriptRoot "lib\Wizard.ps1")
. (Join-Path $PSScriptRoot "lib\Updater.ps1")

$script:LauncherScriptDir = $PSScriptRoot
$LauncherPaths = Get-LauncherPaths -ScriptDir $PSScriptRoot

# Identidad del producto (version.json) y links configurables (app_links.json).
$ProductInfo = @{ product = "Firebrand Palworld Server Launcher"; publisher = "Firebrand Software"; version = "0.0.0"; release_channel = "dev"; build_date = "" }
try {
    $versionJson = Get-Content -LiteralPath (Join-Path $LauncherPaths.InstallRoot "version.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $versionJson.PSObject.Properties) { $ProductInfo[$p.Name] = [string]$p.Value }
}
catch {}

$AppLinks = @{ donate_url = "https://ko-fi.com/firebrandsoftware"; homepage_url = "https://github.com/firebrand-dev/firebrand-palworld-server-launcher"; releases_url = "" }
try {
    $linksJson = Get-Content -LiteralPath (Join-Path $LauncherPaths.InstallRoot "config\app_links.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $linksJson.PSObject.Properties) { $AppLinks[$p.Name] = [string]$p.Value }
}
catch {}

# Idiomas: UI para el admin, idioma separado para los avisos in-game.
$LocalesDir = Join-Path $LauncherPaths.InstallRoot "locales"
$InitialLanguages = Get-InitialLanguages -DataRoot $LauncherPaths.DataRoot -InstallRoot $LauncherPaths.InstallRoot -LocalesDir $LocalesDir
$script:UILanguage = $InitialLanguages.UI
$script:ServerLanguage = $InitialLanguages.Server
Initialize-I18n -LocalesDir $LocalesDir -UILanguage $script:UILanguage -ServerLanguage $script:ServerLanguage

# Migracion unica desde el layout viejo (config junto al launcher).
# Si el usuario ya dijo que No, queda registrado y no se vuelve a preguntar.
$MigrationDeclinedFlag = Join-Path $LauncherPaths.DataRoot "migration-declined.flag"
if (-not $LauncherPaths.IsPortable -and -not (Test-Path -LiteralPath $MigrationDeclinedFlag)) {
    $pendingMigration = @(Get-OldLayoutMigrationFiles -InstallRoot $LauncherPaths.InstallRoot -DataRoot $LauncherPaths.DataRoot)
    if ($pendingMigration.Count -gt 0) {
        $migrationAnswer = [System.Windows.Forms.MessageBox]::Show(
            (T "startup.migrate_text" @($LauncherPaths.DataRoot)),
            (T "startup.migrate_title"),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($migrationAnswer -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Invoke-LauncherDataMigration -InstallRoot $LauncherPaths.InstallRoot -DataRoot $LauncherPaths.DataRoot | Out-Null
                $LauncherPaths = Get-LauncherPaths -ScriptDir $PSScriptRoot
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    (T "startup.migrate_failed" @($_.Exception.Message)),
                    (T "startup.migrate_title"),
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
        }
        else {
            try {
                New-Item -ItemType Directory -Force -Path $LauncherPaths.DataRoot | Out-Null
                Set-Content -LiteralPath $MigrationDeclinedFlag `
                    -Value "El usuario decidió no migrar la configuración vieja. Borrá este archivo para que se vuelva a ofrecer." `
                    -Encoding UTF8
            }
            catch {}
        }
    }
}

# Settings danados: respaldar y avisar en vez de relocalizar el server en silencio.
if ($LauncherPaths.SettingsCorrupt) {
    $corruptBackup = $null
    try {
        $corruptBackup = $LauncherPaths.SettingsFile + ".corrupt_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
        Copy-Item -LiteralPath $LauncherPaths.SettingsFile -Destination $corruptBackup -Force
    }
    catch { $corruptBackup = $null }

    $corruptNote = if ($corruptBackup) { T "startup.corrupt_backup_note" @($corruptBackup) } else { "" }
    [System.Windows.Forms.MessageBox]::Show(
        (T "startup.corrupt_text" @($corruptNote)),
        (T "startup.corrupt_title"),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

# Asigna todas las variables de rutas del launcher desde una resolucion de
# Get-LauncherPaths. Reutilizable: el wizard re-resuelve en caliente cuando
# el usuario instala o adopta un server.
function Set-LauncherPathVariables {
    param([Parameter(Mandatory=$true)]$Paths)

    $script:LauncherPaths = $Paths
    $script:IsPortable = $Paths.IsPortable
    $script:InstallRoot = $Paths.InstallRoot
    $script:DataRoot = $Paths.DataRoot
    $script:ServerRoot = $Paths.ServerRoot
    $script:ServerDir = $Paths.ServerDir
    $script:ServerExe = Join-Path $Paths.ServerDir "PalServer.exe"
    $script:SteamCmdExe = Join-Path $Paths.SteamCmdDir "steamcmd.exe"
    $script:ConfigFile = Join-Path $Paths.ServerDir "Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"
    $script:DefaultConfig = Join-Path $Paths.ServerDir "DefaultPalWorldSettings.ini"
    $script:SaveDir = Join-Path $Paths.ServerDir "Pal\Saved"
    $script:BackupDir = $Paths.BackupDir
    $script:LogsDir = $Paths.LogsDir
    $script:CurrentServerLog = Join-Path $Paths.LogsDir "server_current.log"
    $script:ChatHistoryFile = Join-Path $Paths.LogsDir "chat_history.log"
    $script:AutomationConfigFile = Join-Path $Paths.DataRoot "automation-settings.json"
    $script:TipsFile = Join-Path $Paths.DataRoot "palworld_tips.txt"
    $script:CustomMessagesFile = Join-Path $Paths.DataRoot "custom_messages.txt"
    $script:ActivityLogFile = Join-Path $Paths.LogsDir "activity.log"
    $script:GeminiKeyFile = Join-Path $Paths.DataRoot "gemini-key.dat"
    $script:LauncherConfig = $Paths.SettingsFile
}

Set-LauncherPathVariables $LauncherPaths

# Los datos del usuario nunca se escriben en la carpeta de instalacion
# (salvo modo portable, donde DataRoot == InstallRoot a proposito).
try {
    New-Item -ItemType Directory -Force -Path $DataRoot,$LogsDir | Out-Null
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        (T "startup.dataroot_error" @($DataRoot, $_.Exception.Message)),
        $ProductInfo.product,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:LastCpuTime = $null
$script:LastCpuAt = $null
$script:NextRestartAt = $null
$script:ScheduleSignature = ""
$script:AnnouncedMinutes = New-Object 'System.Collections.Generic.HashSet[int]'
$script:RestartInProgress = $false
$script:LogPosition = 0L
$script:LastChatLineKey = ""
$script:PlayersJob = $null
$script:LastAutoMessageAt = [datetime]::MinValue
$script:LastAutoMessage = ""
$script:LowFpsSince = $null
$script:PendingSmartRestart = $false
$script:LastPlayerCount = 0
$script:LastActivityText = ""
$script:LastBackupAt = $null
$script:MetricsJob = $null
$script:LastMetrics = $null
$script:LastServerInfo = $null
$script:LastMetricsError = ""
$script:LastMetricsAt = $null
$script:ServerPid = $null


function Show-Message(
    [string]$Text,
    [string]$Title = "Palworld Server Manager",
    [string]$Icon = "Information"
) {
    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon
    ) | Out-Null
}

# Un proceso es "nuestro" solo si su ejecutable vive dentro de $ServerDir.
# Asi el launcher jamas toca un PalServer de OTRA instalacion de la misma PC.
# Si la ruta no se puede leer (proceso elevado / de otro usuario), se asume
# que NO es nuestro: preferimos no poder gestionarlo antes que matar uno ajeno.
function Test-OwnServerProcess($Process) {
    if (-not $Process) { return $false }
    try {
        $exePath = $Process.Path
        if (-not $exePath) { return $false }
        $prefix = $ServerDir.TrimEnd('\') + '\'
        return $exePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-ServerProcess {
    try {
        if ($script:ServerPid) {
            $byPid = Get-Process -Id $script:ServerPid -ErrorAction SilentlyContinue
            if ($byPid -and $byPid.ProcessName -like "PalServer*" -and (Test-OwnServerProcess $byPid)) {
                return $byPid
            }
        }

        $processes = Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessName -like "PalServer*" -and (Test-OwnServerProcess $_)
            } |
            Sort-Object WorkingSet64 -Descending

        if ($processes) {
            $found = $processes | Select-Object -First 1
            $script:ServerPid = $found.Id
            return $found
        }
    }
    catch {}

    return $null
}

# Cantidad de procesos PalServer visibles por NOMBRE que NO se pueden
# identificar como de esta instalacion (otra instalacion, o un proceso
# elevado cuya ruta no podemos leer). Los guards de operaciones sensibles
# frenan o piden confirmacion ante estos procesos: podria ser NUESTRO
# server corriendo elevado y tocarlo/ignorarlo corromperia el mundo.
function Get-UnidentifiedPalServerCount {
    $all = @(
        Get-Process `
            -Name "PalServer","PalServer-Win64-Test","PalServer-Win64-Shipping" `
            -ErrorAction SilentlyContinue
    )
    return @($all | Where-Object { -not (Test-OwnServerProcess $_) }).Count
}

function Ensure-Ini {
    $configDirectory = Split-Path -Parent $ConfigFile
    New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null

    $valid = $false

    if (Test-Path -LiteralPath $ConfigFile) {
        $raw = [IO.File]::ReadAllText($ConfigFile)
        $valid = (
            ($raw -match '\[/Script/Pal\.PalGameWorldSettings\]') -and
            ($raw -match 'OptionSettings\s*=\s*\(')
        )
    }

    if (-not $valid) {
        if (Test-Path -LiteralPath $ConfigFile) {
            $backupName = $ConfigFile + ".broken_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak"
            Copy-Item -LiteralPath $ConfigFile -Destination $backupName -Force
        }

        if (Test-Path -LiteralPath $DefaultConfig) {
            Copy-Item -LiteralPath $DefaultConfig -Destination $ConfigFile -Force
        }
        else {
@'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="Mi servidor Palworld",ServerDescription="",AdminPassword="",ServerPassword="",ServerPlayerMaxNum=32,PublicPort=8211,RESTAPIEnabled=True,RESTAPIPort=8212,CrossplayPlatforms=(Steam,Xbox,PS5,Mac),ExpRate=1.000000,PalCaptureRate=1.000000,PalSpawnNumRate=1.000000,PalEggDefaultHatchingTime=72.000000,DeathPenalty=All,bIsPvP=False)
'@ | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
        }
    }
}

function Get-IniText {
    Ensure-Ini
    return [IO.File]::ReadAllText($ConfigFile)
}

function Get-IniValue(
    [string]$Text,
    [string]$Key,
    [string]$Default = ""
) {
    $escaped = [regex]::Escape($Key)
    $pattern = "(?<![A-Za-z0-9_])$escaped=(?:""(?<quoted>[^""]*)""|(?<value>\([^)]*\)|[^,\)`r`n]+))"
    $match = [regex]::Match($Text, $pattern)

    if (-not $match.Success) {
        return $Default
    }

    if ($match.Groups["quoted"].Success) {
        return $match.Groups["quoted"].Value
    }

    return $match.Groups["value"].Value.Trim()
}

function Set-IniValue(
    [string]$Text,
    [string]$Key,
    [string]$Value,
    [bool]$Quoted = $false
) {
    $escaped = [regex]::Escape($Key)
    $newValue = if ($Quoted) {
        '"' + ($Value -replace '"','') + '"'
    }
    else {
        $Value
    }

    $pattern = "(?<![A-Za-z0-9_])$escaped=(?:""[^""]*""|\([^)]*\)|[^,\)`r`n]+)"

    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, "$Key=$newValue", 1)
    }

    $lastParenthesis = $Text.LastIndexOf(")")

    if ($lastParenthesis -lt 0) {
        throw "Formato de PalWorldSettings.ini no reconocido."
    }

    return $Text.Insert($lastParenthesis, ",$Key=$newValue")
}

function Get-ApiHeaders {
    $credentials = "admin:" + $txtAdmin.Text
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($credentials)
    )

    return @{ Authorization = "Basic $encoded" }
}

function Invoke-PalApi(
    [string]$Method,
    [string]$Path,
    $Body = $null,
    [int]$TimeoutSeconds = 3
) {
    $port = [int]$numApiPort.Value
    $url = "http://127.0.0.1:$port/v1/api/$Path"

    $parameters = @{
        Uri = $url
        Method = $Method
        Headers = (Get-ApiHeaders)
        TimeoutSec = $TimeoutSeconds
        UseBasicParsing = $true
    }

    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = ($Body | ConvertTo-Json -Compress)
    }

    return Invoke-RestMethod @parameters
}

function Send-Announcement([string]$Message) {
    try {
        Invoke-PalApi -Method "POST" -Path "announce" -Body @{ message = $Message } -TimeoutSeconds 4 | Out-Null
        $lblAction.Text = T "panel.announce_sent" @($Message)
        return $true
    }
    catch {
        $lblAction.Text = T "panel.announce_failed"
        return $false
    }
}


function Write-Activity([string]$Message) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Message
        Add-Content -LiteralPath $ActivityLogFile -Value $line -Encoding UTF8
        $script:LastActivityText = $Message

        if ($rtbActivity) {
            $rtbActivity.AppendText($line + [Environment]::NewLine)
            $rtbActivity.SelectionStart = $rtbActivity.TextLength
            $rtbActivity.ScrollToCaret()
        }
    }
    catch {}
}

function Ensure-AutomationFiles {
    if (-not (Test-Path -LiteralPath $TipsFile)) {
@'
Asigná Pals con buena capacidad de transporte para que los materiales no queden tirados.
La temperatura correcta acelera la incubación de los huevos.
Llevá esferas de varios niveles; las comunes pierden efectividad contra Pals fuertes.
Una base cerca de minerales reduce mucho el tiempo de traslado.
Revisá las habilidades de trabajo antes de asignar un Pal a la base.
Los Pals nocturnos pueden mantener tareas activas mientras otros duermen.
No dejes demasiados objetos tirados: pueden afectar el rendimiento del servidor.
Usá cofres cerca de las estaciones de producción para reducir recorridos.
Llevá comida variada para evitar que el equipo pierda productividad.
Una montura voladora facilita explorar zonas altas y descubrir puntos de viaje.
Prepará equipo resistente al frío y al calor antes de entrar en biomas extremos.
Los Pals con Medicina ayudan a recuperar compañeros incapacitados en la base.
Mejorar la Estatua de Poder aumenta capacidades importantes del personaje y los Pals.
Los puntos de viaje rápido ahorran mucho tiempo; activalos aunque no los uses de inmediato.
Repará el equipo antes de una expedición larga.
Las mazmorras pueden cerrar o cambiar; entrá preparado y con espacio en el inventario.
Separá cofres por materiales para que la producción sea más ordenada.
Los Pals con enfriamiento mantienen alimentos frescos durante más tiempo.
Construí camas suficientes para evitar estrés y pérdida de productividad.
Los Pals enfermos trabajan peor; revisá sus estados y tratá las lesiones.
Elegí el Pal correcto para cada estación en lugar de usar solamente los de mayor nivel.
Una base demasiado cargada de estructuras y objetos puede reducir los FPS del servidor.
Guardá recursos importantes antes de explorar zonas peligrosas.
El peso máximo puede mejorarse; es útil para minería y construcción.
Usá los tipos elementales a tu favor durante los combates.
No todos los Pals sirven igual como montura; compará velocidad y habilidades.
Las armas y armaduras de mayor calidad pueden requerir materiales especiales.
Revisá las tecnologías antiguas para desbloquear equipamiento único.
Los jefes de torre requieren preparación, comida y munición suficientes.
Los Pals de agua son útiles para molinos y algunas cadenas de producción.
Los Pals eléctricos permiten automatizar estaciones avanzadas.
La producción mejora cuando comida, camas y baños están cerca de la zona de trabajo.
Las puertas y defensas pueden ayudar durante ataques a la base.
Guardá copias de seguridad antes de cambiar configuraciones importantes.
Evitá desconectarte durante un guardado o reinicio anunciado.
El servidor se guarda automáticamente, pero un backup adicional protege mejor el mundo.
Una base minera funciona mejor con transporte y cofres bien ubicados.
Los Pals con habilidades de recolección recogen cultivos maduros automáticamente.
La siembra, el riego y la recolección requieren aptitudes de trabajo diferentes.
La comida de mejor calidad puede mejorar la eficiencia de los trabajadores.
Usá el mapa para marcar minerales, jefes y zonas importantes.
Algunas habilidades pasivas mejoran velocidad de trabajo o movimiento.
Criar Pals permite combinar características y habilidades pasivas.
Mantené espacio libre en el Palbox antes de capturar muchos Pals.
Las capturas consecutivas de una misma especie pueden dar experiencia adicional.
Un Pal con alta cordura necesita menos descansos.
Colocá estaciones con espacio suficiente para que los Pals puedan llegar sin trabarse.
Si un Pal no trabaja, levantalo y volvé a asignarlo a la estación.
Los Pals grandes necesitan caminos más amplios dentro de la base.
El exceso de trabajadores sobre una misma tarea no siempre mejora la producción.
Usá armaduras adecuadas al nivel de la zona que vas a explorar.
Las estatuas Lifmunk mejoran la capacidad de captura al entregarlas en la Estatua de Poder.
La munición puede agotarse rápido; fabricá reservas antes de enfrentar jefes.
Los escudos se regeneran y pueden evitar daño directo a la salud.
Combiná armas a distancia con un Pal que aproveche la debilidad elemental del enemigo.
Los Pals de fuego pueden producir lingotes y cocinar alimentos.
El generador eléctrico necesita un Pal eléctrico asignado para mantenerse cargado.
Los recursos reaparecen mejor cuando no construís encima de sus puntos de aparición.
Reiniciar periódicamente puede recuperar rendimiento en mundos muy cargados.
Si los FPS del servidor bajan, revisá bases, objetos tirados y tiempo desde el último reinicio.
'@ | Set-Content -LiteralPath $TipsFile -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $CustomMessagesFile)) {
@'
Bienvenidos al servidor. Respeten a los demás jugadores y disfruten Palworld.
Recuerden guardar sus objetos importantes antes de una expedición peligrosa.
El servidor realiza backups automáticos para proteger el progreso.
Consulten el horario del próximo reinicio en los anuncios del servidor.
'@ | Set-Content -LiteralPath $CustomMessagesFile -Encoding UTF8
    }
}

function Save-GeminiKey([string]$ApiKey) {
    try {
        if ([string]::IsNullOrWhiteSpace($ApiKey)) {
            Remove-Item -LiteralPath $GeminiKeyFile -Force -ErrorAction SilentlyContinue
            return
        }

        $secure = ConvertTo-SecureString -String $ApiKey -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString -SecureString $secure
        Set-Content -LiteralPath $GeminiKeyFile -Value $encrypted -Encoding UTF8
    }
    catch {
        throw "No se pudo proteger la clave de Gemini: $($_.Exception.Message)"
    }
}

function Load-GeminiKey {
    try {
        if (-not (Test-Path -LiteralPath $GeminiKeyFile)) {
            return ""
        }

        $encrypted = Get-Content -LiteralPath $GeminiKeyFile -Raw
        $secure = ConvertTo-SecureString -String $encrypted
        $credential = New-Object System.Management.Automation.PSCredential("Gemini",$secure)
        return $credential.GetNetworkCredential().Password
    }
    catch {
        return ""
    }
}

function Save-AutomationSettings {
    try {
        @{
            Enabled = $chkAutoMessages.Checked
            IntervalMinutes = [int]$numMessageInterval.Value
            IncludeTips = $chkIncludeTips.Checked
            IncludeCustom = $chkIncludeCustom.Checked
            IncludeTime = $chkIncludeTime.Checked
            Prefix = $txtMessagePrefix.Text
            GeminiModel = $txtGeminiModel.Text
            RestartOnlyWhenEmpty = $chkRestartOnlyEmpty.Checked
            RestartOnLowFps = $chkRestartLowFps.Checked
            LowFpsThreshold = [int]$numLowFps.Value
            LowFpsMinutes = [int]$numLowFpsMinutes.Value
            BackupRetention = [int]$numBackupRetention.Value
            JoinLeaveAnnouncements = $chkJoinLeave.Checked
        } | ConvertTo-Json | Set-Content -LiteralPath $AutomationConfigFile -Encoding UTF8

        Save-GeminiKey $txtGeminiKey.Text
        $lblAutomationStatus.Text = T "config.saved_status" @((Get-Date -Format "HH:mm:ss"))
        Write-Activity (T "auto.saved_activity")
    }
    catch {
        Show-Message $_.Exception.Message (T "auto.title") "Error"
    }
}

function Load-AutomationSettings {
    Ensure-AutomationFiles

    $chkAutoMessages.Checked = $false
    $numMessageInterval.Value = 30
    $chkIncludeTips.Checked = $true
    $chkIncludeCustom.Checked = $true
    $chkIncludeTime.Checked = $true
    $txtMessagePrefix.Text = TS "game.default_prefix"
    $txtGeminiModel.Text = "gemini-3.5-flash"
    $txtGeminiKey.Text = Load-GeminiKey
    $chkRestartOnlyEmpty.Checked = $false
    $chkRestartLowFps.Checked = $false
    $numLowFps.Value = 25
    $numLowFpsMinutes.Value = 10
    $numBackupRetention.Value = 20
    $chkJoinLeave.Checked = $true

    if (-not (Test-Path -LiteralPath $AutomationConfigFile)) {
        return
    }

    try {
        $cfg = Get-Content -LiteralPath $AutomationConfigFile -Raw | ConvertFrom-Json

        if ($null -ne $cfg.Enabled) { $chkAutoMessages.Checked = [bool]$cfg.Enabled }
        if ($null -ne $cfg.IntervalMinutes) { $numMessageInterval.Value = [decimal]$cfg.IntervalMinutes }
        if ($null -ne $cfg.IncludeTips) { $chkIncludeTips.Checked = [bool]$cfg.IncludeTips }
        if ($null -ne $cfg.IncludeCustom) { $chkIncludeCustom.Checked = [bool]$cfg.IncludeCustom }
        if ($null -ne $cfg.IncludeTime) { $chkIncludeTime.Checked = [bool]$cfg.IncludeTime }
        if ($null -ne $cfg.Prefix) { $txtMessagePrefix.Text = [string]$cfg.Prefix }
        if ($null -ne $cfg.GeminiModel) { $txtGeminiModel.Text = [string]$cfg.GeminiModel }
        if ($null -ne $cfg.RestartOnlyWhenEmpty) { $chkRestartOnlyEmpty.Checked = [bool]$cfg.RestartOnlyWhenEmpty }
        if ($null -ne $cfg.RestartOnLowFps) { $chkRestartLowFps.Checked = [bool]$cfg.RestartOnLowFps }
        if ($null -ne $cfg.LowFpsThreshold) { $numLowFps.Value = [decimal]$cfg.LowFpsThreshold }
        if ($null -ne $cfg.LowFpsMinutes) { $numLowFpsMinutes.Value = [decimal]$cfg.LowFpsMinutes }
        if ($null -ne $cfg.BackupRetention) { $numBackupRetention.Value = [decimal]$cfg.BackupRetention }
        if ($null -ne $cfg.JoinLeaveAnnouncements) { $chkJoinLeave.Checked = [bool]$cfg.JoinLeaveAnnouncements }
    }
    catch {
        $lblAutomationStatus.Text = T "auto.read_error"
    }
}

function Get-AutomaticMessage {
    $messages = New-Object System.Collections.Generic.List[string]

    if ($chkIncludeTips.Checked -and (Test-Path -LiteralPath $TipsFile)) {
        Get-Content -LiteralPath $TipsFile |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $messages.Add($_.Trim()) }
    }

    if ($chkIncludeCustom.Checked -and (Test-Path -LiteralPath $CustomMessagesFile)) {
        Get-Content -LiteralPath $CustomMessagesFile |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $messages.Add($_.Trim()) }
    }

    if ($messages.Count -eq 0) {
        return $null
    }

    $available = @($messages | Where-Object { $_ -ne $script:LastAutoMessage })

    if ($available.Count -eq 0) {
        $available = @($messages)
    }

    $selected = Get-Random -InputObject $available
    $script:LastAutoMessage = $selected

    $parts = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($txtMessagePrefix.Text)) {
        $parts.Add($txtMessagePrefix.Text.Trim())
    }

    $parts.Add($selected)

    if ($chkIncludeTime.Checked) {
        $parts.Add((TS "game.server_time" @((Get-Date -Format "HH:mm"))))
    }

    return ($parts -join " ")
}

function Send-AutomaticMessage([bool]$ManualTest = $false) {
    if (-not (Get-ServerProcess)) {
        if ($ManualTest) {
            Show-Message (T "auto.server_stopped") (T "auto.msg_title") "Warning"
        }
        return
    }

    $message = Get-AutomaticMessage

    if ([string]::IsNullOrWhiteSpace($message)) {
        if ($ManualTest) {
            Show-Message (T "auto.no_messages") (T "auto.msg_title") "Warning"
        }
        return
    }

    if (Send-Announcement $message) {
        $script:LastAutoMessageAt = Get-Date
        Append-ChatLine `
            -Timestamp (Get-Date -Format "HH:mm:ss") `
            -Author (T "chat.server_author") `
            -Message $message `
            -IsServer $true

        Write-Activity (T "auto.sent_activity" @($message))
        $lblAutomationStatus.Text = T "auto.last_sent" @((Get-Date -Format "HH:mm:ss"))

        if ($ManualTest) {
            Show-Message (T "auto.sent_ok" @($message))
        }
    }
}

function Update-AutomaticMessages {
    if (-not $chkAutoMessages.Checked) {
        return
    }

    if (-not (Get-ServerProcess)) {
        return
    }

    $interval = [int]$numMessageInterval.Value

    if ($interval -le 0) {
        return
    }

    if (
        $script:LastAutoMessageAt -eq [datetime]::MinValue -or
        ((Get-Date) - $script:LastAutoMessageAt).TotalMinutes -ge $interval
    ) {
        Send-AutomaticMessage
    }
}

function Generate-GeminiTips {
    $apiKey = $txtGeminiKey.Text.Trim()
    $model = $txtGeminiModel.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Show-Message (T "gemini.key_missing") (T "gemini.title") "Warning"
        return
    }

    if ([string]::IsNullOrWhiteSpace($model)) {
        Show-Message (T "gemini.model_missing") (T "gemini.title") "Warning"
        return
    }

    $lblAutomationStatus.Text = T "gemini.generating"
    $form.Refresh()

    try {
        # Los consejos los leen los JUGADORES: se piden en el idioma del server.
        $tipsLanguage = Get-LocaleDisplayName $script:ServerLanguage
        $prompt = @"
Generá exactamente 40 consejos breves, útiles y seguros sobre Palworld para anunciar dentro de un servidor dedicado.
Reglas:
- Idioma de los consejos: $tipsLanguage.
- Una sola oración por consejo.
- Máximo 150 caracteres por consejo.
- Sin numeración, viñetas, encabezados ni explicaciones.
- No inventes estadísticas exactas ni información dudosa.
- Mezclá consejos de bases, Pals, producción, exploración, combate, rendimiento y convivencia.
- Un consejo por línea.
"@

        $body = @{
            contents = @(
                @{
                    role = "user"
                    parts = @(
                        @{ text = $prompt }
                    )
                }
            )
            generationConfig = @{
                temperature = 0.8
                maxOutputTokens = 2500
            }
        } | ConvertTo-Json -Depth 8

        $uri = "https://generativelanguage.googleapis.com/v1beta/models/$model`:generateContent"

        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method POST `
            -Headers @{ "x-goog-api-key" = $apiKey } `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 60

        $generatedText = $response.candidates[0].content.parts[0].text

        if ([string]::IsNullOrWhiteSpace($generatedText)) {
            throw "Gemini no devolvió texto."
        }

        $newTips = @(
            $generatedText -split "`r?`n" |
            ForEach-Object {
                $_.Trim() -replace '^\s*[-*•\d\.\)\(]+\s*',''
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_.Length -le 220
            } |
            Select-Object -Unique
        )

        if ($newTips.Count -lt 10) {
            throw "Se recibieron muy pocos consejos válidos."
        }

        $existing = @()

        if (Test-Path -LiteralPath $TipsFile) {
            $existing = @(Get-Content -LiteralPath $TipsFile)
        }

        $merged = @($existing + $newTips | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique)

        $merged | Set-Content -LiteralPath $TipsFile -Encoding UTF8
        Save-GeminiKey $apiKey

        $lblAutomationStatus.Text = T "gemini.added_status" @($newTips.Count)
        Write-Activity (T "gemini.added_activity" @($newTips.Count))
        Show-Message (T "gemini.added" @($newTips.Count, $merged.Count))
    }
    catch {
        Show-Message (T "gemini.failed" @($_.Exception.Message)) (T "gemini.title") "Error"
        $lblAutomationStatus.Text = T "gemini.error_status"
    }
}

function Apply-BackupRetention {
    try {
        $keep = [int]$numBackupRetention.Value

        if ($keep -le 0) {
            return
        }

        $backups = @(
            Get-ChildItem -LiteralPath $BackupDir -Filter "*.zip" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        )

        if ($backups.Count -le $keep) {
            return
        }

        $backups[$keep..($backups.Count - 1)] |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Write-Activity (T "activity.retention" @($keep))
    }
    catch {}
}

function Delete-SelectedBackup {
    if ($listBackups.SelectedItems.Count -eq 0) {
        Show-Message (T "backups.select") (T "backups.title") "Warning"
        return
    }

    $path = [string]$listBackups.SelectedItems[0].Tag
    $answer = [Windows.Forms.MessageBox]::Show(
        (T "backups.delete_confirm" @($path)),
        (T "backups.delete_confirm_title"),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        Remove-Item -LiteralPath $path -Force
        Write-Activity (T "activity.backup_deleted" @([IO.Path]::GetFileName($path)))
        Refresh-BackupsList
    }
}

function Restore-SelectedBackup {
    if (Get-ServerProcess) {
        Show-Message (T "restore.stop_first") (T "restore.title") "Warning"
        return
    }

    if ((Get-UnidentifiedPalServerCount) -gt 0) {
        Show-Message (T "restore.unidentified") (T "restore.title") "Warning"
        return
    }

    if ($listBackups.SelectedItems.Count -eq 0) {
        Show-Message (T "backups.select") (T "restore.title") "Warning"
        return
    }

    $backupPath = [string]$listBackups.SelectedItems[0].Tag

    $first = [Windows.Forms.MessageBox]::Show(
        (T "restore.first_confirm"),
        (T "restore.title"),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($first -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    $second = [Windows.Forms.MessageBox]::Show(
        (T "restore.final_confirm" @([IO.Path]::GetFileName($backupPath))),
        (T "restore.final_confirm_title"),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($second -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        $safety = Backup-World -SkipRetention $true
        $temp = Join-Path $env:TEMP ("palworld_restore_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($backupPath, $temp)

        Remove-Item -LiteralPath $SaveDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null

        Get-ChildItem -LiteralPath $temp -Force |
            Copy-Item -Destination $SaveDir -Recurse -Force

        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Activity (T "activity.backup_restored" @([IO.Path]::GetFileName($backupPath)))
        Show-Message (T "restore.done")
    }
    catch {
        Show-Message (T "restore.failed" @($_.Exception.Message)) (T "restore.title") "Error"
    }
}

function Get-SelectedPlayer {
    if ($listPlayers.SelectedItems.Count -eq 0) {
        Show-Message (T "players.select") (T "players.title") "Warning"
        return $null
    }

    return $listPlayers.SelectedItems[0].Tag
}

function Copy-SelectedPlayerUid {
    $player = Get-SelectedPlayer

    if ($null -eq $player) {
        return
    }

    $uid = [string]$player.userId
    [Windows.Forms.Clipboard]::SetText($uid)
    $lblPlayersStatus.Text = T "players.uid_copied" @($uid)
}

function Kick-SelectedPlayer {
    $player = Get-SelectedPlayer

    if ($null -eq $player) {
        return
    }

    $uid = [string]$player.userId
    $name = [string]$player.name

    try {
        Invoke-PalApi -Method "POST" -Path "kick" -Body @{ userid = $uid; message = (TS "game.kicked") } -TimeoutSeconds 5 | Out-Null
        Write-Activity (T "activity.player_kicked" @($name, $uid))
        Show-Message (T "players.kicked" @($name))
        Start-PlayersJob
    }
    catch {
        Show-Message $_.Exception.Message (T "players.kick_error_title") "Error"
    }
}

function Ban-SelectedPlayer {
    $player = Get-SelectedPlayer

    if ($null -eq $player) {
        return
    }

    $uid = [string]$player.userId
    $name = [string]$player.name

    $answer = [Windows.Forms.MessageBox]::Show(
        (T "players.ban_confirm" @($name)),
        (T "players.ban_confirm_title"),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Invoke-PalApi -Method "POST" -Path "ban" -Body @{ userid = $uid } -TimeoutSeconds 5 | Out-Null
        Write-Activity (T "activity.player_banned" @($name, $uid))
        Show-Message (T "players.banned" @($name))
        Start-PlayersJob
    }
    catch {
        Show-Message $_.Exception.Message (T "players.ban_error_title") "Error"
    }
}

function Update-SmartRestart {
    if (-not (Get-ServerProcess)) {
        $script:LowFpsSince = $null
        $script:PendingSmartRestart = $false
        return
    }

    if ($chkRestartLowFps.Checked -and $script:LastMetrics) {
        $fps = [int]$script:LastMetrics.serverfps
        $threshold = [int]$numLowFps.Value

        if ($fps -lt $threshold) {
            if ($null -eq $script:LowFpsSince) {
                $script:LowFpsSince = Get-Date
                Write-Activity (T "smart.low_fps_activity" @($fps))
            }

            if (
                ((Get-Date) - $script:LowFpsSince).TotalMinutes -ge
                [int]$numLowFpsMinutes.Value
            ) {
                $script:PendingSmartRestart = $true
            }
        }
        else {
            $script:LowFpsSince = $null
        }
    }

    if ($script:PendingSmartRestart) {
        $players = 0

        if ($script:LastMetrics) {
            $players = [int]$script:LastMetrics.currentplayernum
        }

        if ($chkRestartOnlyEmpty.Checked -and $players -gt 0) {
            $lblAutomationStatus.Text = T "smart.waiting_empty"
            return
        }

        Send-Announcement (TS "game.maintenance_restart") | Out-Null
        Write-Activity (T "smart.restart_activity")
        $script:PendingSmartRestart = $false
        $script:LowFpsSince = $null
        Restart-Server -Automatic $true
    }
}

# El modo de reinicio del combo, como clave neutra persistible ('disabled'|'interval'|'daily').
# El indice del combo se corresponde 1 a 1 con $RestartModeKeys (definido en lib\Paths.ps1).
function Get-RestartModeKey {
    $index = $cmbRestartMode.SelectedIndex
    if ($index -ge 0 -and $index -lt $RestartModeKeys.Count) {
        return $RestartModeKeys[$index]
    }
    return "disabled"
}

function Save-LauncherOptions {
    $timeValue = $timeRestart.Value.ToString("HH:mm")

    @{
        PublicLobby = $chkPublicLobby.Checked
        AutoBackup = $chkAutoBackup.Checked
        WorkerThreads = [int]$numWorkers.Value
        UseLegacyPerformanceArgs = $chkLegacyPerfArgs.Checked
        AutoStartServer = $chkAutoStartServer.Checked
        RestartMode = (Get-RestartModeKey)
        AutoRestartHours = [int]$numAutoRestart.Value
        DailyRestartTime = $timeValue
        ServerRoot = $ServerRoot
        # ServerDir solo se persiste si difiere del layout clasico
        # <ServerRoot>\server (caso "server existente adoptado" del wizard).
        ServerDir = $(if ($ServerDir -ne (Join-Path $ServerRoot "server")) { $ServerDir } else { $null })
        Language = $script:UILanguage
        ServerMessageLanguage = $script:ServerLanguage
    } | ConvertTo-Json | Set-Content -LiteralPath $LauncherConfig -Encoding UTF8
}

function Load-LauncherOptions {
    # Mientras se cargan valores, los eventos de los controles (p.ej.
    # SelectedIndexChanged del combo) NO deben disparar Save-LauncherOptions:
    # guardarian el archivo con estado a medio cargar (bug heredado de v9 que
    # pisaba DailyRestartTime con el default 06:00 en cada arranque).
    $script:LoadingOptions = $true
    try {
    $chkPublicLobby.Checked = $true
    $chkAutoBackup.Checked = $true
    $numWorkers.Value = 4
    $chkLegacyPerfArgs.Checked = $false
    $chkAutoStartServer.Checked = $false
    $cmbRestartMode.SelectedIndex = 0
    $numAutoRestart.Value = 12
    $timeRestart.Value = [datetime]::Today.AddHours(6)

    if (-not (Test-Path -LiteralPath $LauncherConfig)) {
        return
    }

    try {
        $config = Get-Content -LiteralPath $LauncherConfig -Raw | ConvertFrom-Json

        if ($null -ne $config.PublicLobby) {
            $chkPublicLobby.Checked = [bool]$config.PublicLobby
        }

        if ($null -ne $config.AutoBackup) {
            $chkAutoBackup.Checked = [bool]$config.AutoBackup
        }

        if ($null -ne $config.WorkerThreads) {
            $numWorkers.Value = [decimal]$config.WorkerThreads
        }

        if ($null -ne $config.UseLegacyPerformanceArgs) {
            $chkLegacyPerfArgs.Checked = [bool]$config.UseLegacyPerformanceArgs
        }

        if ($null -ne $config.AutoStartServer) {
            $chkAutoStartServer.Checked = [bool]$config.AutoStartServer
        }

        if ($null -ne $config.AutoRestartHours) {
            $numAutoRestart.Value = [decimal]$config.AutoRestartHours
        }

        if ($null -ne $config.RestartMode) {
            # Acepta claves neutras nuevas y los textos en espanol de settings viejos.
            $modeKey = ConvertTo-RestartModeKey ([string]$config.RestartMode)
            $modeIndex = [array]::IndexOf($RestartModeKeys, $modeKey)
            if ($modeIndex -ge 0) {
                $cmbRestartMode.SelectedIndex = $modeIndex
            }
        }

        if ($null -ne $config.DailyRestartTime) {
            $parts = ([string]$config.DailyRestartTime).Split(":")
            if ($parts.Count -eq 2) {
                $timeRestart.Value = [datetime]::Today.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
            }
        }
    }
    catch {
        $lblAction.Text = T "config.options_read_error"
    }
    }
    finally {
        $script:LoadingOptions = $false
    }
}


function Save-CriticalRuntimeSettings {
    $text = Get-IniText

    $criticalSettings = @(
        @("ServerName",$txtName.Text,$true),
        @("ServerDescription",$txtDescription.Text,$true),
        @("ServerPassword",$txtPassword.Text,$true),
        @("AdminPassword",$txtAdmin.Text,$true),
        @("ServerPlayerMaxNum",$numPlayers.Value.ToString(),$false),
        @("PublicPort",$numPort.Value.ToString(),$false),
        @("RESTAPIEnabled","True",$false),
        @("RESTAPIPort",$numApiPort.Value.ToString(),$false),
        @("CrossplayPlatforms","(Steam,Xbox,PS5,Mac)",$false)
    )

    foreach ($setting in $criticalSettings) {
        $text = Set-IniValue `
            -Text $text `
            -Key $setting[0] `
            -Value $setting[1] `
            -Quoted $setting[2]
    }

    [IO.File]::WriteAllText(
        $ConfigFile,
        $text,
        [Text.UTF8Encoding]::new($false)
    )
}

function Save-Settings {
    try {
        $text = Get-IniText

        $settings = @(
            @("ServerName",$txtName.Text,$true),
            @("ServerDescription",$txtDescription.Text,$true),
            @("ServerPassword",$txtPassword.Text,$true),
            @("AdminPassword",$txtAdmin.Text,$true),
            @("ServerPlayerMaxNum",$numPlayers.Value.ToString(),$false),
            @("PublicPort",$numPort.Value.ToString(),$false),
            @("RESTAPIEnabled","True",$false),
            @("RESTAPIPort",$numApiPort.Value.ToString(),$false),
            @("CrossplayPlatforms","(Steam,Xbox,PS5,Mac)",$false),
            @("ExpRate",$numExp.Value.ToString([Globalization.CultureInfo]::InvariantCulture),$false),
            @("PalCaptureRate",$numCapture.Value.ToString([Globalization.CultureInfo]::InvariantCulture),$false),
            @("PalSpawnNumRate",$numSpawn.Value.ToString([Globalization.CultureInfo]::InvariantCulture),$false),
            @("PalEggDefaultHatchingTime",$numEgg.Value.ToString([Globalization.CultureInfo]::InvariantCulture),$false),
            @("DeathPenalty",$cmbDeath.SelectedItem.ToString(),$false),
            @("bIsPvP",$(if ($chkPvP.Checked) { "True" } else { "False" }),$false)
        )

        foreach ($setting in $settings) {
            $text = Set-IniValue -Text $text -Key $setting[0] -Value $setting[1] -Quoted $setting[2]
        }

        [IO.File]::WriteAllText(
            $ConfigFile,
            $text,
            [Text.UTF8Encoding]::new($false)
        )

        Save-LauncherOptions
        Reset-RestartSchedule

        $lblAction.Text = T "config.saved_status" @((Get-Date -Format "HH:mm:ss"))
        Show-Message (T "config.saved_msg")
    }
    catch {
        Show-Message $_.Exception.Message (T "config.save_error_title") "Error"
    }
}

function Load-Settings {
    try {
        # No materializar el arbol del server en el primer arranque: recien se
        # crea el INI cuando el server existe o el usuario guarda/instala algo.
        $text = ""
        if ((Test-Path -LiteralPath $ConfigFile) -or (Test-Path -LiteralPath $ServerDir)) {
            $text = Get-IniText
        }

        $txtName.Text = Get-IniValue $text "ServerName" (T "default.server_name")
        $txtDescription.Text = Get-IniValue $text "ServerDescription" ""
        $txtPassword.Text = Get-IniValue $text "ServerPassword" ""
        $txtAdmin.Text = Get-IniValue $text "AdminPassword" ""
        $numPlayers.Value = [decimal](Get-IniValue $text "ServerPlayerMaxNum" "32")
        $numPort.Value = [decimal](Get-IniValue $text "PublicPort" "8211")
        $numApiPort.Value = [decimal](Get-IniValue $text "RESTAPIPort" "8212")

        $numExp.Value = [decimal]::Parse(
            (Get-IniValue $text "ExpRate" "1"),
            [Globalization.CultureInfo]::InvariantCulture
        )

        $numCapture.Value = [decimal]::Parse(
            (Get-IniValue $text "PalCaptureRate" "1"),
            [Globalization.CultureInfo]::InvariantCulture
        )

        $numSpawn.Value = [decimal]::Parse(
            (Get-IniValue $text "PalSpawnNumRate" "1"),
            [Globalization.CultureInfo]::InvariantCulture
        )

        $numEgg.Value = [decimal]::Parse(
            (Get-IniValue $text "PalEggDefaultHatchingTime" "72"),
            [Globalization.CultureInfo]::InvariantCulture
        )

        $deathPenalty = Get-IniValue $text "DeathPenalty" "All"

        if ($cmbDeath.Items.Contains($deathPenalty)) {
            $cmbDeath.SelectedItem = $deathPenalty
        }
        else {
            $cmbDeath.SelectedItem = "All"
        }

        $chkPvP.Checked = (Get-IniValue $text "bIsPvP" "False") -eq "True"
    }
    catch {
        Show-Message $_.Exception.Message (T "config.read_error_title") "Error"
    }

    # Las opciones del launcher se cargan SIEMPRE, aunque el INI del server
    # haya fallado: si no, un ServerRoot inaccesible dejaria los defaults en
    # la UI y el proximo guardado pisaria la configuracion real del usuario.
    Load-LauncherOptions
    Reset-RestartSchedule
}

function Backup-World([bool]$SkipRetention = $false) {
    if (-not (Test-Path -LiteralPath $SaveDir)) {
        return $null
    }

    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $destination = Join-Path $BackupDir "Palworld_Save_$timestamp.zip"
    $tempDestination = $destination + ".tmp"

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Force
    }

    try {
        # ZipFile en lugar de Compress-Archive: en PowerShell 5.1 Compress-Archive
        # falla con entradas >2 GB y consume mucha memoria con mundos grandes.
        # Se comprime a .tmp y se renombra al final: si falla a mitad de camino
        # no queda un .zip corrupto contando para la retencion ni para restaurar.
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $SaveDir,
            $tempDestination,
            [IO.Compression.CompressionLevel]::Optimal,
            $false
        )
        Move-Item -LiteralPath $tempDestination -Destination $destination -Force
    }
    catch {
        Remove-Item -LiteralPath $tempDestination -Force -ErrorAction SilentlyContinue
        throw
    }

    $script:LastBackupAt = Get-Date
    Write-Activity (T "activity.backup_created" @([IO.Path]::GetFileName($destination)))

    # El backup de seguridad previo a una restauracion NO aplica retencion:
    # la retencion podria borrar justo el zip que se esta por restaurar.
    if (-not $SkipRetention) {
        Apply-BackupRetention
    }

    return $destination
}

function Start-Server {
    try {
        $existing = Get-ServerProcess
        if ($existing) { Show-Message (T "server.already_running" @($existing.Id)); Update-Status; return }
        if (-not (Test-Path -LiteralPath $ServerExe)) { Show-Message (T "server.exe_missing" @($ServerExe)) (T "server.start_error_title") "Error"; return }
        if ((Get-UnidentifiedPalServerCount) -gt 0) {
            $confirmStart = [Windows.Forms.MessageBox]::Show(
                (T "server.unidentified_start"),
                (T "server.unidentified_start_title"),
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmStart -ne [Windows.Forms.DialogResult]::Yes) { return }
        }
        Save-CriticalRuntimeSettings
        Save-LauncherOptions
        $arguments = ""
        if ($chkLegacyPerfArgs.Checked) {
            $arguments = "-useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS"
            if ([int]$numWorkers.Value -gt 0) { $arguments += " -NumberOfWorkerThreadsServer=$([int]$numWorkers.Value)" }
        }
        if ($chkPublicLobby.Checked) { if ($arguments.Length -gt 0) { $arguments += " " }; $arguments += "-publiclobby" }
        if (Test-Path -LiteralPath $CurrentServerLog) {
            Move-Item -LiteralPath $CurrentServerLog -Destination (Join-Path $LogsDir ("server_"+(Get-Date -Format "yyyy-MM-dd_HH-mm-ss")+".log")) -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Path $CurrentServerLog -Force | Out-Null
        $script:LogPosition = 0L
        $script:ServerPid = $null
        # Lanzar el binario de CONSOLA directamente: el wrapper PalServer.exe
        # abre una consola propia para el hijo Shipping-Cmd y la redireccion
        # no captura NADA (por eso los server_*.log quedaban en 0 bytes y la
        # pestana Chat nunca veia el output real del server).
        $exeToLaunch = $ServerExe
        $workDir = $ServerDir
        $shippingCmd = Join-Path $ServerDir "Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe"
        if (Test-Path -LiteralPath $shippingCmd) {
            $exeToLaunch = $shippingCmd
            $workDir = Split-Path -Parent $shippingCmd
        }
        $commandLine = '""' + $exeToLaunch + '" ' + $arguments + ' >> "' + $CurrentServerLog + '" 2>&1"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/d /s /c $commandLine"
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $proc) { throw (T "server.wrapper_error") }
        $lblAction.Text = T "server.starting"
        Write-Activity (T "server.start_requested_activity")
        Start-Sleep -Seconds 4
        if (-not (Get-ServerProcess)) { throw (T "server.not_alive") }
        $script:NextRestartAt=$null; $script:ScheduleSignature=""; $script:AnnouncedMinutes.Clear(); $script:LastServerInfo=$null
        Update-Status; Update-RestartSchedule
    } catch { Show-Message (T "server.start_failed" @($_.Exception.Message)) (T "server.start_error_title") "Error"; Update-Status }
}

function Stop-Server(
    [bool]$RestartAfter = $false,
    [string]$ShutdownMessage = ""
) {
    if ([string]::IsNullOrWhiteSpace($ShutdownMessage)) {
        $ShutdownMessage = TS "game.shutting_down"
    }
    $process = Get-ServerProcess

    if (-not $process) {
        Update-Status
        if ($RestartAfter) {
            Start-Server
        }
        return
    }

    $lblStatus.Text = T "panel.status_stopping"
    $form.Refresh()

    $gracefulRequested = $false

    try {
        Invoke-PalApi -Method "POST" -Path "save" -TimeoutSeconds 5 | Out-Null
        Start-Sleep -Seconds 2

        Invoke-PalApi `
            -Method "POST" `
            -Path "shutdown" `
            -Body @{
                waittime = 1
                message = $ShutdownMessage
            } `
            -TimeoutSeconds 5 | Out-Null

        $gracefulRequested = $true
    }
    catch {
        $lblAction.Text = T "server.rest_no_response"
    }

    $deadline = (Get-Date).AddSeconds(25)

    while ((Get-ServerProcess) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Seconds 1
        [System.Windows.Forms.Application]::DoEvents()
    }

    $process = Get-ServerProcess

    if ($process) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
        Start-Sleep -Seconds 2
    }

    # Barrida final SOLO sobre procesos de ESTA instalacion (por ruta del exe):
    # jamas se mata un PalServer de otra carpeta/instalacion de la misma PC.
    # Patron PalServer* (no lista fija): el proceso real se llama
    # PalServer-Win64-Shipping-Cmd y la lista vieja lo dejaba afuera.
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "PalServer*" -and (Test-OwnServerProcess $_) } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $script:ServerPid = $null

    Update-Status
    Write-Activity (T "server.stopped_activity")

    if ($RestartAfter) {
        Start-Sleep -Seconds 3
        Start-Server
    }
}

function Restart-Server([bool]$Automatic = $false) {
    if ($script:RestartInProgress) {
        return
    }

    $script:RestartInProgress = $true

    try {
        if ($chkAutoBackup.Checked) {
            try {
                Invoke-PalApi -Method "POST" -Path "save" -TimeoutSeconds 5 | Out-Null
                Start-Sleep -Seconds 2
            }
            catch {}

            $lblAction.Text = T "backups.creating"
            $form.Refresh()

            try {
                $backup = Backup-World
                if ($backup) {
                    $lblAction.Text = T "backups.created_status" @([IO.Path]::GetFileName($backup))
                }
            }
            catch {
                $lblAction.Text = T "backups.create_failed" @($_.Exception.Message)
            }
        }

        if ($Automatic) {
            Send-Announcement (TS "game.restart_now") | Out-Null
        }

        Stop-Server -RestartAfter $true -ShutdownMessage (TS "game.shutting_down")
    }
    finally {
        $script:RestartInProgress = $false
        $script:NextRestartAt = $null
        $script:ScheduleSignature = ""
        $script:AnnouncedMinutes.Clear()
    }
}

# Descarga y extrae SteamCMD. Reutilizable desde el wizard: $TargetDir y
# $OnStatus opcionales (sin ellos usa las rutas y labels del launcher).
function Install-SteamCmd {
    param(
        [string]$TargetDir = "",
        [scriptblock]$OnStatus = $null
    )

    $steamCmdDir = $TargetDir
    if ([string]::IsNullOrWhiteSpace($steamCmdDir)) {
        $steamCmdDir = [IO.Path]::GetDirectoryName($SteamCmdExe)
    }
    New-Item -ItemType Directory -Force -Path $steamCmdDir | Out-Null

    $zipPath = Join-Path $env:TEMP ("steamcmd_" + [guid]::NewGuid().ToString("N") + ".zip")

    if ($OnStatus) {
        & $OnStatus (T "update.steamcmd_downloading")
    }
    else {
        $lblAction.Text = T "update.steamcmd_downloading"
        $form.Refresh()
    }

    # PS 5.1 sobre .NET Framework viejo puede no ofrecer TLS 1.2 por default
    # y el CDN de Valve lo exige; -bor para no deshabilitar protocolos futuros.
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest `
            -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" `
            -OutFile $zipPath `
            -UseBasicParsing `
            -TimeoutSec 120

        Expand-Archive -Path $zipPath -DestinationPath $steamCmdDir -Force
    }
    finally {
        $ProgressPreference = $previousProgress
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    Write-Activity (T "update.steamcmd_installed_activity" @($steamCmdDir))
}

function Update-Server {
    if (-not (Test-Path -LiteralPath $SteamCmdExe)) {
        $answer = [Windows.Forms.MessageBox]::Show(
            (T "update.steamcmd_missing" @([IO.Path]::GetDirectoryName($SteamCmdExe))),
            (T "update.steamcmd_title"),
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )

        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            return
        }

        try {
            Install-SteamCmd
        }
        catch {
            Show-Message (T "update.steamcmd_failed" @($_.Exception.Message)) (T "update.steamcmd_title") "Error"
            return
        }
    }

    $wasRunning = [bool](Get-ServerProcess)

    if (-not $wasRunning -and (Get-UnidentifiedPalServerCount) -gt 0) {
        $confirmUpdate = [Windows.Forms.MessageBox]::Show(
            (T "update.unidentified"),
            (T "update.unidentified_title"),
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirmUpdate -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    if ($wasRunning) {
        Stop-Server
    }

    $lblStatus.Text = T "panel.status_updating"
    $form.Refresh()

    $arguments = "+force_install_dir `"$ServerDir`" +login anonymous +app_update 2394010 validate +quit"

    # Ventana visible: SteamCMD muestra su propio progreso de descarga.
    $process = Start-Process `
        -FilePath $SteamCmdExe `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -WindowStyle Normal

    # SteamCMD puede devolver codigos raros (p.ej. 7 al auto-actualizarse):
    # el criterio real de exito es que el binario del server exista.
    if (-not (Test-Path -LiteralPath $ServerExe)) {
        Show-Message (T "update.steamcmd_exit" @($process.ExitCode)) (T "update.error_title") "Error"
    }
    elseif ($wasRunning) {
        Start-Server
    }

    $script:LastServerInfo = $null
    $lblVersion.Text = T "panel.server_version" @((Get-ServerVersion))
    Update-Status
}

function Get-ServerVersion {
    if ($script:LastServerInfo -and $script:LastServerInfo.version) {
        return [string]$script:LastServerInfo.version
    }

    if (-not (Test-Path -LiteralPath $ServerExe)) {
        return (T "panel.version_not_installed")
    }

    try {
        $binary = Get-ChildItem `
            -LiteralPath $ServerDir `
            -Filter "PalServer*.exe" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ne "PalServer.exe"
            } |
            Select-Object -First 1

        if ($binary) {
            $version = $binary.VersionInfo.ProductVersion

            if (-not $version) {
                $version = $binary.VersionInfo.FileVersion
            }

            if ($version) {
                return $version
            }
        }
    }
    catch {}

    try {
        $manifestPath = Join-Path $ServerDir "steamapps\appmanifest_2394010.acf"

        if (Test-Path -LiteralPath $manifestPath) {
            $raw = Get-Content -LiteralPath $manifestPath -Raw
            $match = [regex]::Match($raw, '"buildid"\s+"(?<id>\d+)"')

            if ($match.Success) {
                return "Steam Build " + $match.Groups["id"].Value
            }
        }
    }
    catch {}

    return (T "panel.version_waiting")
}

function Get-ScheduleSignature {
    $process = Get-ServerProcess
    $processPart = if ($process) {
        "$($process.Id)|$($process.StartTime.Ticks)"
    }
    else {
        "offline"
    }

    $mode = Get-RestartModeKey
    $hours = [int]$numAutoRestart.Value
    $time = $timeRestart.Value.ToString("HH:mm")

    return "$processPart|$mode|$hours|$time"
}

function Reset-RestartSchedule {
    $script:NextRestartAt = $null
    $script:ScheduleSignature = ""
    $script:AnnouncedMinutes.Clear()
    Update-RestartSchedule
}

function Calculate-NextRestart {
    $process = Get-ServerProcess

    if (-not $process) {
        return $null
    }

    $mode = Get-RestartModeKey

    if ($mode -eq "interval") {
        $hours = [int]$numAutoRestart.Value

        if ($hours -le 0) {
            return $null
        }

        $candidate = $process.StartTime.AddHours($hours)

        while ($candidate -le (Get-Date)) {
            $candidate = $candidate.AddHours($hours)
        }

        return $candidate
    }

    if ($mode -eq "daily") {
        $now = Get-Date
        $candidate = Get-Date `
            -Year $now.Year `
            -Month $now.Month `
            -Day $now.Day `
            -Hour $timeRestart.Value.Hour `
            -Minute $timeRestart.Value.Minute `
            -Second 0

        if ($candidate -le $now) {
            $candidate = $candidate.AddDays(1)
        }

        return $candidate
    }

    return $null
}

function Update-RestartSchedule {
    $signature = Get-ScheduleSignature

    if ($signature -ne $script:ScheduleSignature) {
        $script:ScheduleSignature = $signature
        $script:NextRestartAt = Calculate-NextRestart
        $script:AnnouncedMinutes.Clear()
    }

    if ($null -eq $script:NextRestartAt) {
        $lblNextRestart.Text = T "schedule.next_disabled"
        $btnCancelRestart.Enabled = $false
        return
    }

    $remaining = $script:NextRestartAt - (Get-Date)

    if ($remaining.TotalSeconds -le 0) {
        # "Solo cuando no haya jugadores" aplica TAMBIEN al reinicio
        # programado (bug reportado: antes solo frenaba el reinicio por
        # FPS). Si hay gente adentro, se espera y se reintenta cada tick.
        # Sin metricas disponibles se asume 0 (igual que el smart restart).
        $playersNow = 0
        if ($script:LastMetrics) {
            try { $playersNow = [int]$script:LastMetrics.currentplayernum } catch { $playersNow = 0 }
        }
        if ($chkRestartOnlyEmpty.Checked -and $playersNow -gt 0) {
            $lblNextRestart.Text = T "schedule.waiting_empty" @($playersNow)
            $btnCancelRestart.Enabled = $true
            return
        }

        $lblNextRestart.Text = T "schedule.in_progress"
        $btnCancelRestart.Enabled = $false
        Restart-Server -Automatic $true
        return
    }

    $btnCancelRestart.Enabled = $true

    $hours = [math]::Floor($remaining.TotalHours)
    $minutes = $remaining.Minutes
    $seconds = $remaining.Seconds

    $lblNextRestart.Text = T "schedule.next" @($script:NextRestartAt, $hours, $minutes, $seconds)

    $warningThresholds = @(25,15,10,9,8,7,6,5,4,3,2,1)

    foreach ($threshold in $warningThresholds) {
        if (
            $remaining.TotalSeconds -le ($threshold * 60) -and
            -not $script:AnnouncedMinutes.Contains($threshold)
        ) {
            $message = if ($threshold -eq 1) {
                TS "game.restart_one_minute"
            }
            else {
                TS "game.restart_minutes" @($threshold)
            }

            Send-Announcement $message | Out-Null
            $script:AnnouncedMinutes.Add($threshold) | Out-Null
            break
        }
    }
}

function Cancel-ScheduledRestart {
    if ($null -eq $script:NextRestartAt) {
        Show-Message (T "schedule.no_active")
        return
    }

    $previousTarget = $script:NextRestartAt
    $mode = Get-RestartModeKey

    if ($mode -eq "interval") {
        $hours = [int]$numAutoRestart.Value
        $script:NextRestartAt = (Get-Date).AddHours($hours)
    }
    elseif ($mode -eq "daily") {
        $script:NextRestartAt = $previousTarget.AddDays(1)
    }
    else {
        $script:NextRestartAt = $null
    }

    $script:AnnouncedMinutes.Clear()

    Send-Announcement (TS "game.restart_cancelled") | Out-Null

    if ($null -ne $script:NextRestartAt) {
        $lblAction.Text = T "schedule.cancelled_next" @($script:NextRestartAt)
    }
    else {
        $lblAction.Text = T "schedule.cancelled"
    }

    Update-RestartSchedule
}


function Start-MetricsWorker {
    if ($script:MetricsJob) {
        $state = $script:MetricsJob.State

        if ($state -eq "Running" -or $state -eq "NotStarted") {
            return
        }

        Collect-MetricsJob
    }

    $process = Get-ServerProcess

    if (-not $process) {
        return
    }

    $adminPassword = $txtAdmin.Text
    $apiPort = [int]$numApiPort.Value
    $needInfo = ($null -eq $script:LastServerInfo)

    $script:MetricsJob = Start-Job `
        -ArgumentList $adminPassword,$apiPort,$needInfo `
        -ScriptBlock {
            param($Password,$Port,$NeedInfo)

            $credentials = "admin:" + $Password
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes($credentials)
            )

            $headers = @{
                Authorization = "Basic $encoded"
                Accept = "application/json"
            }

            $baseUrl = "http://127.0.0.1:$Port/v1/api"

            try {
                $metrics = Invoke-RestMethod `
                    -Uri "$baseUrl/metrics" `
                    -Method GET `
                    -Headers $headers `
                    -TimeoutSec 3 `
                    -UseBasicParsing

                $info = $null

                if ($NeedInfo) {
                    $info = Invoke-RestMethod `
                        -Uri "$baseUrl/info" `
                        -Method GET `
                        -Headers $headers `
                        -TimeoutSec 3 `
                        -UseBasicParsing
                }

                [pscustomobject]@{
                    Success = $true
                    Metrics = $metrics
                    Info = $info
                    Error = ""
                }
            }
            catch {
                $message = $_.Exception.Message

                if ($_.Exception.Response) {
                    try {
                        $statusCode = [int]$_.Exception.Response.StatusCode

                        if ($statusCode -eq 401) {
                            $message = "API respondió 401: la Clave admin/API no coincide con AdminPassword."
                        }
                        elseif ($statusCode -eq 404) {
                            $message = "API respondió 404: endpoint REST no disponible."
                        }
                        else {
                            $message = "API respondió HTTP ${statusCode}: $message"
                        }
                    }
                    catch {}
                }
                elseif (
                    $message -match
                    "No se puede establecer conexión|Unable to connect|conexión subyacente|actively refused|rechazó"
                ) {
                    $message = "No hay conexión con 127.0.0.1:$Port. REST API desactivada, puerto incorrecto o servidor iniciando."
                }

                [pscustomobject]@{
                    Success = $false
                    Metrics = $null
                    Info = $null
                    Error = $message
                }
            }
        }
}

function Collect-MetricsJob {
    if (-not $script:MetricsJob) {
        return
    }

    if ($script:MetricsJob.State -eq "Running" -or $script:MetricsJob.State -eq "NotStarted") {
        return
    }

    try {
        $result = Receive-Job -Job $script:MetricsJob -ErrorAction SilentlyContinue |
            Select-Object -Last 1

        if ($result) {
            if ($result.Success) {
                $script:LastMetrics = $result.Metrics
                if ($result.Info) {
                    $script:LastServerInfo = $result.Info
                }
                $script:LastMetricsError = ""
                $script:LastMetricsAt = Get-Date
            }
            else {
                $script:LastMetrics = $null
                $script:LastMetricsError = [string]$result.Error
            }
        }
    }
    catch {
        $script:LastMetrics = $null
        $script:LastMetricsError = $_.Exception.Message
    }
    finally {
        Remove-Job -Job $script:MetricsJob -Force -ErrorAction SilentlyContinue
        $script:MetricsJob = $null
    }
}

function Test-RestApi {
    $lblAction.Text = T "apitest.testing"
    Start-MetricsWorker

    $deadline = (Get-Date).AddSeconds(8)

    while (
        $script:MetricsJob -and
        ($script:MetricsJob.State -eq "Running" -or $script:MetricsJob.State -eq "NotStarted") -and
        (Get-Date) -lt $deadline
    ) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    Collect-MetricsJob

    if ($script:LastMetrics) {
        Show-Message (T "apitest.ok" @($script:LastMetrics.serverfps, $script:LastMetrics.currentplayernum, $script:LastMetrics.maxplayernum, $script:LastServerInfo.version))
    }
    else {
        Show-Message (T "apitest.failed" @($script:LastMetricsError)) (T "apitest.title") "Warning"
    }
}



function Append-ChatLine([string]$Timestamp,[string]$Author,[string]$Message,[bool]$IsServer=$false) {
    if (-not $rtbChat) { return }
    $line = if ($IsServer) { "[${Timestamp}] $(T 'chat.server_author'): $Message" } else { "[${Timestamp}] ${Author}: $Message" }
    $rtbChat.AppendText($line+[Environment]::NewLine); $rtbChat.SelectionStart=$rtbChat.TextLength; $rtbChat.ScrollToCaret()
    Add-Content -LiteralPath $ChatHistoryFile -Value $line -Encoding UTF8
}
function Read-NewServerLogLines {
    if (-not (Test-Path -LiteralPath $CurrentServerLog)) { return }
    try {
        $fs=New-Object IO.FileStream($CurrentServerLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {
            if ($script:LogPosition -gt $fs.Length) { $script:LogPosition=0L }
            $fs.Seek($script:LogPosition,[IO.SeekOrigin]::Begin)|Out-Null
            $sr=New-Object IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $line=$sr.ReadLine(); if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($rtbServerLog) { $rtbServerLog.AppendText($line+[Environment]::NewLine); $rtbServerLog.SelectionStart=$rtbServerLog.TextLength; $rtbServerLog.ScrollToCaret() }
                $m=[regex]::Match($line,'^\[(?<date>[^\]]+)\]\s+\[CHAT\]\s+<(?<name>[^>]+)>\s*(?<message>.*)$')
                if ($m.Success -and $line -ne $script:LastChatLineKey) {
                    $script:LastChatLineKey=$line; $tm=$m.Groups['date'].Value
                    try { $tm=([datetime]::Parse($tm)).ToString('HH:mm:ss') } catch {}
                    Append-ChatLine $tm $m.Groups['name'].Value $m.Groups['message'].Value
                }
                elseif ($line -match '\[CHAT\]' -and $line -ne $script:LastChatLineKey) {
                    # Linea de chat con formato distinto al esperado: mostrarla
                    # cruda igual (sirve para ajustar el parser con datos reales).
                    $script:LastChatLineKey=$line
                    Append-ChatLine (Get-Date -Format 'HH:mm:ss') (T 'chat.raw_author') $line
                }
                elseif ($line -match 'joined the server|left the server') {
                    # El vanilla no publica el chat, pero SI las entradas y
                    # salidas: a la pestana Chat y (opcional) a actividad.
                    $evt=[regex]::Match($line,'^\[(?<date>[^\]]+)\]\s+\[LOG\]\s+(?<msg>.+)$')
                    $evtMsg = if ($evt.Success) { $evt.Groups['msg'].Value } else { $line }
                    $evtTime = Get-Date -Format 'HH:mm:ss'
                    if ($evt.Success) { try { $evtTime=([datetime]::Parse($evt.Groups['date'].Value)).ToString('HH:mm:ss') } catch {} }
                    Append-ChatLine $evtTime (T 'chat.event_author') $evtMsg
                    if ($chkJoinLeave -and $chkJoinLeave.Checked) { Write-Activity $evtMsg }
                }
            }
            $script:LogPosition=$fs.Position; $sr.Dispose()
        } finally { $fs.Dispose() }
    } catch { $lblAction.Text=(T 'chat.log_read_error' @($_.Exception.Message)) }
}
function Send-ServerChat {
    $message=$txtChatMessage.Text.Trim(); if ([string]::IsNullOrWhiteSpace($message)) { return }
    if (Send-Announcement $message) { Append-ChatLine (Get-Date -Format 'HH:mm:ss') (T 'chat.server_author') $message $true; $txtChatMessage.Clear() }
    else { Show-Message (T 'chat.send_failed') (T 'chat.title') 'Warning' }
}
function Load-ChatHistory { if ($rtbChat -and (Test-Path -LiteralPath $ChatHistoryFile)) { try { $rtbChat.Lines=Get-Content -LiteralPath $ChatHistoryFile -Tail 1000; $rtbChat.SelectionStart=$rtbChat.TextLength; $rtbChat.ScrollToCaret() } catch {} } }
function Refresh-BackupsList {
    if (-not $listBackups) { return }; $listBackups.Items.Clear()
    Get-ChildItem -LiteralPath $BackupDir -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $i=New-Object Windows.Forms.ListViewItem($_.Name); [void]$i.SubItems.Add($_.LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss')); [void]$i.SubItems.Add(('{0:N1} MB' -f ($_.Length/1MB))); $i.Tag=$_.FullName; [void]$listBackups.Items.Add($i)
    }
}
function Start-PlayersJob {
    if ($script:PlayersJob) {
        if ($script:PlayersJob.State -in @('Running','NotStarted')) { return }
        try { $r=Receive-Job $script:PlayersJob -ErrorAction SilentlyContinue|Select-Object -Last 1; if ($r.Success) { $listPlayers.Items.Clear(); foreach($pl in @($r.Players)) { $i=New-Object Windows.Forms.ListViewItem([string]$pl.name); [void]$i.SubItems.Add([string]$pl.level); [void]$i.SubItems.Add([string]$pl.ping); [void]$i.SubItems.Add([string]$pl.accountName); [void]$i.SubItems.Add([string]$pl.userId); [void]$listPlayers.Items.Add($i) }; $lblPlayersStatus.Text=(T 'players.count' @(@($r.Players).Count)) } else { $lblPlayersStatus.Text=(T 'players.error' @($r.Error)) } } catch { $lblPlayersStatus.Text=(T 'players.error' @($_.Exception.Message)) }
        Remove-Job $script:PlayersJob -Force -ErrorAction SilentlyContinue; $script:PlayersJob=$null
    }
    if (-not (Get-ServerProcess)) { $lblPlayersStatus.Text=(T 'players.stopped'); return }
    $pw=$txtAdmin.Text; $port=[int]$numApiPort.Value
    $script:PlayersJob=Start-Job -ArgumentList $pw,$port -ScriptBlock { param($Password,$Port) try { $cred='admin:'+$Password; $enc=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cred)); $resp=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/api/players" -Headers @{Authorization="Basic $enc"} -TimeoutSec 3 -UseBasicParsing; $pls=if($resp.players){@($resp.players)}else{@($resp)}; [pscustomobject]@{Success=$true;Players=$pls;Error=''} } catch { [pscustomobject]@{Success=$false;Players=@();Error=$_.Exception.Message} } }
}

function Update-Status {
    $process = Get-ServerProcess

    if (-not $process) {
        $lblStatus.Text = T "panel.status_stopped"
        $lblStatus.ForeColor = [Drawing.Color]::DarkRed
        $lblMetrics.Text = T "panel.metrics_empty"
        $lblQuality.Text = T "panel.quality_none"
        $lblUptime.Text = T "panel.uptime_empty"
        $script:LastCpuTime = $null
        $script:LastCpuAt = $null
        $script:LastMetrics = $null
        return
    }

    $lblStatus.Text = T "panel.status_online" @($process.Id)
    $lblStatus.ForeColor = [Drawing.Color]::DarkGreen

    $ram = [math]::Round($process.WorkingSet64 / 1GB, 2)
    $cpuText = "--"

    try {
        $now = Get-Date
        $cpuNow = $process.TotalProcessorTime.TotalSeconds

        if ($null -ne $script:LastCpuTime) {
            $elapsed = ($now - $script:LastCpuAt).TotalSeconds

            if ($elapsed -gt 0) {
                $percentage = (
                    ($cpuNow - $script:LastCpuTime) /
                    $elapsed /
                    [Environment]::ProcessorCount
                ) * 100

                $cpuText = ([math]::Round([math]::Max(0,$percentage),1)).ToString() + "%"
            }
        }

        $script:LastCpuTime = $cpuNow
        $script:LastCpuAt = $now
    }
    catch {}

    $lblUptime.Text = T "panel.uptime" @(((Get-Date)-$process.StartTime).ToString("dd\.hh\:mm\:ss"))

    $fps = "--"
    $players = "--"
    $frame = "--"

    if ($script:LastMetrics) {
        try {
            $fps = $script:LastMetrics.serverfps
            $players = "$($script:LastMetrics.currentplayernum)/$($script:LastMetrics.maxplayernum)"
            $frame = [math]::Round([double]$script:LastMetrics.serverframetime,1)

            if ([int]$fps -ge 55) {
                $lblQuality.Text = T "panel.quality_excellent"
            }
            elseif ([int]$fps -ge 40) {
                $lblQuality.Text = T "panel.quality_good"
            }
            elseif ([int]$fps -ge 30) {
                $lblQuality.Text = T "panel.quality_acceptable"
            }
            else {
                $lblQuality.Text = T "panel.quality_low"
            }
        }
        catch {
            $lblQuality.Text = T "panel.quality_unexpected"
        }
    }
    else {
        if ($script:LastMetricsError) {
            $lblQuality.Text = T "panel.quality_rest_error" @($script:LastMetricsError)
        }
        else {
            $lblQuality.Text = T "panel.quality_waiting"
        }
    }

    $lblMetrics.Text = T "panel.metrics" @($fps, $players, $frame, $ram, $cpuText)
    $lblVersion.Text = T "panel.server_version" @((Get-ServerVersion))
}

$form = New-Object Windows.Forms.Form
$form.Text = $ProductInfo.product + " — v" + $ProductInfo.version
$form.Size = New-Object Drawing.Size(1100,900)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI",10)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = "FIREBRAND PALWORLD SERVER LAUNCHER"
$title.Font = New-Object Drawing.Font("Segoe UI",18,[Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(25,15)
$form.Controls.Add($title)

$lblVersion = New-Object Windows.Forms.Label
$lblVersion.Text = T "panel.server_version" @((Get-ServerVersion))
$lblVersion.AutoSize = $true
$lblVersion.Location = New-Object Drawing.Point(710,25)
$form.Controls.Add($lblVersion)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Font = New-Object Drawing.Font("Segoe UI",11,[Drawing.FontStyle]::Bold)
$lblStatus.Location = New-Object Drawing.Point(28,58)
$form.Controls.Add($lblStatus)

$lblMetrics = New-Object Windows.Forms.Label
$lblMetrics.AutoSize = $true
$lblMetrics.Font = New-Object Drawing.Font("Segoe UI",11,[Drawing.FontStyle]::Bold)
$lblMetrics.Location = New-Object Drawing.Point(28,88)
$form.Controls.Add($lblMetrics)

$lblQuality = New-Object Windows.Forms.Label
$lblQuality.AutoSize = $true
$lblQuality.Location = New-Object Drawing.Point(28,116)
$form.Controls.Add($lblQuality)

$lblUptime = New-Object Windows.Forms.Label
$lblUptime.AutoSize = $true
$lblUptime.Location = New-Object Drawing.Point(700,116)
$form.Controls.Add($lblUptime)

$lblClock = New-Object Windows.Forms.Label
$lblClock.Text = T "panel.clock_empty"
$lblClock.Font = New-Object Drawing.Font("Segoe UI",11,[Drawing.FontStyle]::Bold)
$lblClock.AutoSize = $true
$lblClock.Location = New-Object Drawing.Point(870,116)
$form.Controls.Add($lblClock)

function Add-MainButton($Text,$X,$Width,$Handler) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X,145)
    $button.Size = New-Object Drawing.Size($Width,42)
    $button.Add_Click($Handler)
    $form.Controls.Add($button)
    return $button
}

Add-MainButton (T "panel.btn_start") 25 135 { Start-Server } | Out-Null
Add-MainButton (T "panel.btn_stop") 170 135 { Stop-Server } | Out-Null
Add-MainButton (T "panel.btn_restart") 315 150 { Restart-Server } | Out-Null
Add-MainButton (T "panel.btn_update") 475 135 { Update-Server } | Out-Null
Add-MainButton (T "panel.btn_backup") 620 135 {
    try {
        $backup = Backup-World
        if ($backup) {
            Show-Message (T "backups.created" @($backup))
        }
    }
    catch {
        Show-Message $_.Exception.Message (T "update.error_title") "Error"
    }
} | Out-Null
Add-MainButton (T "panel.btn_server_folder") 765 170 {
    if (Test-Path -LiteralPath $ServerDir) {
        Start-Process explorer.exe $ServerDir
    }
    else {
        Show-Message (T "server.folder_missing" @($ServerDir)) (T "server.folder_title")
    }
} | Out-Null

$group = New-Object Windows.Forms.GroupBox
$group.Text = T "config.group"
$group.Location = New-Object Drawing.Point(25,205)
$group.Size = New-Object Drawing.Size(920,390)
$form.Controls.Add($group)

function Add-Label($Text,$X,$Y) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Location = New-Object Drawing.Point($X,$Y)
    $group.Controls.Add($label)
}

function Add-TextBox($X,$Y,$Width,$Password=$false) {
    $textBox = New-Object Windows.Forms.TextBox
    $textBox.Location = New-Object Drawing.Point($X,$Y)
    $textBox.Size = New-Object Drawing.Size($Width,25)
    $textBox.UseSystemPasswordChar = $Password
    $group.Controls.Add($textBox)
    return $textBox
}

function Add-Number($X,$Y,$Min,$Max,$Decimals=0,$Increment=1) {
    $number = New-Object Windows.Forms.NumericUpDown
    $number.Location = New-Object Drawing.Point($X,$Y)
    $number.Size = New-Object Drawing.Size(115,25)
    $number.Minimum = $Min
    $number.Maximum = $Max
    $number.DecimalPlaces = $Decimals
    $number.Increment = $Increment
    $group.Controls.Add($number)
    return $number
}

Add-Label (T "config.name") 18 35
$txtName = Add-TextBox 160 31 725

Add-Label (T "config.description") 18 70
$txtDescription = Add-TextBox 160 66 725

Add-Label (T "config.player_password") 18 105
$txtPassword = Add-TextBox 160 101 250 $true

Add-Label (T "config.admin_password") 475 105
$txtAdmin = Add-TextBox 610 101 275 $true

Add-Label (T "config.max_players") 18 140
$numPlayers = Add-Number 160 136 1 128

Add-Label (T "config.game_port") 475 140
$numPort = Add-Number 610 136 1 65535

Add-Label (T "config.api_port") 18 175
$numApiPort = Add-Number 160 171 1 65535

Add-Label (T "config.workers") 475 175
$numWorkers = Add-Number 610 171 1 16

$chkLegacyPerfArgs = New-Object Windows.Forms.CheckBox
$chkLegacyPerfArgs.Text = T "config.legacy_args"
$chkLegacyPerfArgs.Location = New-Object Drawing.Point(735,172)
$chkLegacyPerfArgs.AutoSize = $true
$group.Controls.Add($chkLegacyPerfArgs)

Add-Label (T "config.exp") 18 210
$numExp = Add-Number 160 206 0.1 20 1 0.1

Add-Label (T "config.capture") 475 210
$numCapture = Add-Number 610 206 0.1 20 1 0.1

Add-Label (T "config.spawn") 18 245
$numSpawn = Add-Number 160 241 0.1 10 1 0.1

Add-Label (T "config.egg") 475 245
$numEgg = Add-Number 610 241 0 240 1 0.5

Add-Label (T "config.death") 18 280
$cmbDeath = New-Object Windows.Forms.ComboBox
$cmbDeath.Location = New-Object Drawing.Point(160,276)
$cmbDeath.Size = New-Object Drawing.Size(250,25)
$cmbDeath.DropDownStyle = "DropDownList"
[void]$cmbDeath.Items.AddRange(@("None","Item","ItemAndEquipment","All"))
$group.Controls.Add($cmbDeath)

$chkPvP = New-Object Windows.Forms.CheckBox
$chkPvP.Text = T "config.pvp"
$chkPvP.Location = New-Object Drawing.Point(20,320)
$chkPvP.AutoSize = $true
$group.Controls.Add($chkPvP)

$chkPublicLobby = New-Object Windows.Forms.CheckBox
$chkPublicLobby.Text = T "config.public_lobby"
$chkPublicLobby.Location = New-Object Drawing.Point(120,320)
$chkPublicLobby.AutoSize = $true
$group.Controls.Add($chkPublicLobby)

$chkAutoBackup = New-Object Windows.Forms.CheckBox
$chkAutoBackup.Text = T "config.auto_backup"
$chkAutoBackup.Location = New-Object Drawing.Point(490,320)
$chkAutoBackup.AutoSize = $true
$group.Controls.Add($chkAutoBackup)

$chkAutoStartServer = New-Object Windows.Forms.CheckBox
$chkAutoStartServer.Text = T "config.autostart_server"
$chkAutoStartServer.Location = New-Object Drawing.Point(690,320)
$chkAutoStartServer.AutoSize = $true
$group.Controls.Add($chkAutoStartServer)

$btnSave = New-Object Windows.Forms.Button
$btnSave.Text = T "config.btn_save"
$btnSave.Location = New-Object Drawing.Point(20,345)
$btnSave.Size = New-Object Drawing.Size(245,35)
$btnSave.Add_Click({ Save-Settings })
$group.Controls.Add($btnSave)

$btnIni = New-Object Windows.Forms.Button
$btnIni.Text = T "config.btn_open_ini"
$btnIni.Location = New-Object Drawing.Point(280,345)
$btnIni.Size = New-Object Drawing.Size(145,35)
$btnIni.Add_Click({
    try {
        Ensure-Ini
        Start-Process notepad.exe $ConfigFile
    }
    catch {
        Show-Message (T "config.ini_open_error" @($_.Exception.Message)) (T "config.ini_open_title") "Error"
    }
})
$group.Controls.Add($btnIni)

$btnBackups = New-Object Windows.Forms.Button
$btnBackups.Text = T "config.btn_backups_folder"
$btnBackups.Location = New-Object Drawing.Point(440,345)
$btnBackups.Size = New-Object Drawing.Size(180,35)
$btnBackups.Add_Click({
    try {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
        Start-Process explorer.exe $BackupDir
    }
    catch {
        Show-Message (T "backups.folder_error" @($_.Exception.Message)) (T "backups.title") "Error"
    }
})
$group.Controls.Add($btnBackups)

$scheduleGroup = New-Object Windows.Forms.GroupBox
$scheduleGroup.Text = T "schedule.group"
$scheduleGroup.Location = New-Object Drawing.Point(25,610)
$scheduleGroup.Size = New-Object Drawing.Size(920,150)
$form.Controls.Add($scheduleGroup)

$scheduleModeLabel = New-Object Windows.Forms.Label
$scheduleModeLabel.Text = T "schedule.mode"
$scheduleModeLabel.AutoSize = $true
$scheduleModeLabel.Location = New-Object Drawing.Point(20,32)
$scheduleGroup.Controls.Add($scheduleModeLabel)

$cmbRestartMode = New-Object Windows.Forms.ComboBox
$cmbRestartMode.Location = New-Object Drawing.Point(80,28)
$cmbRestartMode.Size = New-Object Drawing.Size(210,25)
$cmbRestartMode.DropDownStyle = "DropDownList"
# El ORDEN de los items corresponde 1 a 1 con $RestartModeKeys (disabled/interval/daily)
[void]$cmbRestartMode.Items.AddRange(@(
    (T "schedule.mode_disabled"),
    (T "schedule.mode_interval"),
    (T "schedule.mode_daily")
))
$cmbRestartMode.SelectedIndex = 0
$scheduleGroup.Controls.Add($cmbRestartMode)

$hoursLabel = New-Object Windows.Forms.Label
$hoursLabel.Text = T "schedule.every"
$hoursLabel.AutoSize = $true
$hoursLabel.Location = New-Object Drawing.Point(320,32)
$scheduleGroup.Controls.Add($hoursLabel)

$numAutoRestart = New-Object Windows.Forms.NumericUpDown
$numAutoRestart.Location = New-Object Drawing.Point(365,28)
$numAutoRestart.Size = New-Object Drawing.Size(75,25)
$numAutoRestart.Minimum = 1
$numAutoRestart.Maximum = 168
$numAutoRestart.Value = 12
$scheduleGroup.Controls.Add($numAutoRestart)

$hoursSuffix = New-Object Windows.Forms.Label
$hoursSuffix.Text = T "schedule.hours"
$hoursSuffix.AutoSize = $true
$hoursSuffix.Location = New-Object Drawing.Point(445,32)
$scheduleGroup.Controls.Add($hoursSuffix)

$timeLabel = New-Object Windows.Forms.Label
$timeLabel.Text = T "schedule.daily_time"
$timeLabel.AutoSize = $true
$timeLabel.Location = New-Object Drawing.Point(535,32)
$scheduleGroup.Controls.Add($timeLabel)

$timeRestart = New-Object Windows.Forms.DateTimePicker
$timeRestart.Location = New-Object Drawing.Point(620,28)
$timeRestart.Size = New-Object Drawing.Size(95,25)
$timeRestart.Format = [Windows.Forms.DateTimePickerFormat]::Time
$timeRestart.ShowUpDown = $true
$timeRestart.Value = [datetime]::Today.AddHours(6)
$scheduleGroup.Controls.Add($timeRestart)

$btnApplySchedule = New-Object Windows.Forms.Button
$btnApplySchedule.Text = T "schedule.btn_apply"
$btnApplySchedule.Location = New-Object Drawing.Point(735,25)
$btnApplySchedule.Size = New-Object Drawing.Size(160,32)
$btnApplySchedule.Add_Click({
    Save-LauncherOptions
    Reset-RestartSchedule
    $lblAction.Text = T "schedule.applied"
})
$scheduleGroup.Controls.Add($btnApplySchedule)

$lblNextRestart = New-Object Windows.Forms.Label
$lblNextRestart.Text = T "schedule.next_disabled"
$lblNextRestart.Font = New-Object Drawing.Font("Segoe UI",10,[Drawing.FontStyle]::Bold)
$lblNextRestart.AutoSize = $true
$lblNextRestart.Location = New-Object Drawing.Point(20,78)
$scheduleGroup.Controls.Add($lblNextRestart)

$btnCancelRestart = New-Object Windows.Forms.Button
$btnCancelRestart.Text = T "schedule.btn_cancel"
$btnCancelRestart.Location = New-Object Drawing.Point(650,70)
$btnCancelRestart.Size = New-Object Drawing.Size(245,38)
$btnCancelRestart.Enabled = $false
$btnCancelRestart.Add_Click({ Cancel-ScheduledRestart })
$scheduleGroup.Controls.Add($btnCancelRestart)

$warningLabel = New-Object Windows.Forms.Label
$warningLabel.Text = T "schedule.warnings_note"
$warningLabel.AutoSize = $true
$warningLabel.Location = New-Object Drawing.Point(20,115)
$scheduleGroup.Controls.Add($warningLabel)

$btnTestApi = New-Object Windows.Forms.Button
$btnTestApi.Text = T "schedule.btn_test_api"
$btnTestApi.Location = New-Object Drawing.Point(735,108)
$btnTestApi.Size = New-Object Drawing.Size(160,30)
$btnTestApi.Add_Click({ Test-RestApi })
$scheduleGroup.Controls.Add($btnTestApi)

$lblAction = New-Object Windows.Forms.Label
$lblAction.Text = T "panel.ready"
$lblAction.AutoSize = $true
$lblAction.Location = New-Object Drawing.Point(28,780)
$form.Controls.Add($lblAction)

$securityNote = New-Object Windows.Forms.Label
$securityNote.Text = T "panel.security_note"
$securityNote.AutoSize = $true
$securityNote.Location = New-Object Drawing.Point(28,810)
$form.Controls.Add($securityNote)

$cmbRestartMode.Add_SelectedIndexChanged({
    if ($script:LoadingOptions) { return }
    Save-LauncherOptions
    Reset-RestartSchedule
})

$numAutoRestart.Add_ValueChanged({
    if ((Get-RestartModeKey) -eq "interval") {
        Reset-RestartSchedule
    }
})

$timeRestart.Add_ValueChanged({
    if ((Get-RestartModeKey) -eq "daily") {
        Reset-RestartSchedule
    }
})


$existingControls=@($form.Controls)
$tabs=New-Object Windows.Forms.TabControl; $tabs.Location=New-Object Drawing.Point(5,5); $tabs.Size=New-Object Drawing.Size(1070,845); $tabs.Anchor='Top,Bottom,Left,Right'
$tabPanel=New-Object Windows.Forms.TabPage; $tabPanel.Text=(T 'tab.panel')
$tabChat=New-Object Windows.Forms.TabPage; $tabChat.Text=(T 'tab.chat')
$tabPlayers=New-Object Windows.Forms.TabPage; $tabPlayers.Text=(T 'tab.players')
$tabBackups=New-Object Windows.Forms.TabPage; $tabBackups.Text=(T 'tab.backups')
$tabAutomation=New-Object Windows.Forms.TabPage; $tabAutomation.Text=(T 'tab.automation')
$tabAbout=New-Object Windows.Forms.TabPage; $tabAbout.Text=(T 'tab.about')
[void]$tabs.TabPages.Add($tabPanel); [void]$tabs.TabPages.Add($tabChat); [void]$tabs.TabPages.Add($tabPlayers); [void]$tabs.TabPages.Add($tabBackups); [void]$tabs.TabPages.Add($tabAutomation); [void]$tabs.TabPages.Add($tabAbout)
foreach($c in $existingControls){$form.Controls.Remove($c);$tabPanel.Controls.Add($c)}; $form.Controls.Add($tabs)
$split=New-Object Windows.Forms.SplitContainer; $split.Dock='Fill'; $split.SplitterDistance=650; $tabChat.Controls.Add($split)
$rtbChat=New-Object Windows.Forms.RichTextBox; $rtbChat.Dock='Fill'; $rtbChat.ReadOnly=$true; $rtbChat.Font=New-Object Drawing.Font('Consolas',10); $split.Panel1.Controls.Add($rtbChat)
$bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Bottom'; $bottom.Height=75; $split.Panel1.Controls.Add($bottom)
$txtChatMessage=New-Object Windows.Forms.TextBox; $txtChatMessage.Location=New-Object Drawing.Point(10,10); $txtChatMessage.Size=New-Object Drawing.Size(500,27); $bottom.Controls.Add($txtChatMessage)
$send=New-Object Windows.Forms.Button; $send.Text=(T 'chat.btn_send'); $send.Location=New-Object Drawing.Point(515,8); $send.Size=New-Object Drawing.Size(125,32); $send.Add_Click({Send-ServerChat}); $bottom.Controls.Add($send)
$hist=New-Object Windows.Forms.Button; $hist.Text=(T 'chat.btn_history'); $hist.Location=New-Object Drawing.Point(10,42); $hist.Size=New-Object Drawing.Size(150,28); $hist.Add_Click({if(-not(Test-Path $ChatHistoryFile)){New-Item -ItemType File -Path $ChatHistoryFile -Force|Out-Null};Start-Process notepad.exe $ChatHistoryFile}); $bottom.Controls.Add($hist)
$chatNote=New-Object Windows.Forms.Label; $chatNote.Text=(T 'chat.note'); $chatNote.Location=New-Object Drawing.Point(170,44); $chatNote.Size=New-Object Drawing.Size(660,28); $bottom.Controls.Add($chatNote)
$txtChatMessage.Add_KeyDown({if($_.KeyCode -eq [Windows.Forms.Keys]::Enter){$_.SuppressKeyPress=$true;Send-ServerChat}})
$rtbServerLog=New-Object Windows.Forms.RichTextBox; $rtbServerLog.Dock='Fill'; $rtbServerLog.ReadOnly=$true; $rtbServerLog.Font=New-Object Drawing.Font('Consolas',9); $rtbServerLog.BackColor=[Drawing.Color]::Black; $rtbServerLog.ForeColor=[Drawing.Color]::Gainsboro; $split.Panel2.Controls.Add($rtbServerLog)
$lblPlayersStatus=New-Object Windows.Forms.Label; $lblPlayersStatus.Text=(T 'players.waiting'); $lblPlayersStatus.Location=New-Object Drawing.Point(15,15); $lblPlayersStatus.AutoSize=$true; $tabPlayers.Controls.Add($lblPlayersStatus)
$pr=New-Object Windows.Forms.Button; $pr.Text=(T 'players.btn_refresh'); $pr.Location=New-Object Drawing.Point(820,10); $pr.Size=New-Object Drawing.Size(200,35); $pr.Add_Click({Start-PlayersJob}); $tabPlayers.Controls.Add($pr)
$listPlayers=New-Object Windows.Forms.ListView; $listPlayers.Location=New-Object Drawing.Point(15,60); $listPlayers.Size=New-Object Drawing.Size(1010,700); $listPlayers.View='Details'; $listPlayers.FullRowSelect=$true; $listPlayers.GridLines=$true; [void]$listPlayers.Columns.Add((T 'players.col_player'),220); [void]$listPlayers.Columns.Add((T 'players.col_level'),80); [void]$listPlayers.Columns.Add((T 'players.col_ping'),80); [void]$listPlayers.Columns.Add((T 'players.col_account'),220); [void]$listPlayers.Columns.Add((T 'players.col_userid'),360); $tabPlayers.Controls.Add($listPlayers)
$btnCopyUid=New-Object Windows.Forms.Button; $btnCopyUid.Text=(T 'players.btn_copy'); $btnCopyUid.Location=New-Object Drawing.Point(15,770); $btnCopyUid.Size=New-Object Drawing.Size(160,35); $btnCopyUid.Add_Click({Copy-SelectedPlayerUid}); $tabPlayers.Controls.Add($btnCopyUid)
$btnKickPlayer=New-Object Windows.Forms.Button; $btnKickPlayer.Text=(T 'players.btn_kick'); $btnKickPlayer.Location=New-Object Drawing.Point(190,770); $btnKickPlayer.Size=New-Object Drawing.Size(140,35); $btnKickPlayer.Add_Click({Kick-SelectedPlayer}); $tabPlayers.Controls.Add($btnKickPlayer)
$btnBanPlayer=New-Object Windows.Forms.Button; $btnBanPlayer.Text=(T 'players.btn_ban'); $btnBanPlayer.Location=New-Object Drawing.Point(345,770); $btnBanPlayer.Size=New-Object Drawing.Size(140,35); $btnBanPlayer.Add_Click({Ban-SelectedPlayer}); $tabPlayers.Controls.Add($btnBanPlayer)

$nb=New-Object Windows.Forms.Button; $nb.Text=(T 'backups.btn_create'); $nb.Location=New-Object Drawing.Point(15,15); $nb.Size=New-Object Drawing.Size(200,36); $nb.Add_Click({try{$b=Backup-World;Refresh-BackupsList;if($b){Show-Message (T 'backups.created' @($b))}}catch{Show-Message $_.Exception.Message (T 'backups.title') 'Error'}}); $tabBackups.Controls.Add($nb)
$ob=New-Object Windows.Forms.Button; $ob.Text=(T 'backups.btn_open'); $ob.Location=New-Object Drawing.Point(230,15); $ob.Size=New-Object Drawing.Size(160,36); $ob.Add_Click({try{New-Item -ItemType Directory -Force -Path $BackupDir|Out-Null;Start-Process explorer.exe $BackupDir}catch{Show-Message (T 'backups.folder_error' @($_.Exception.Message)) (T 'backups.title') 'Error'}}); $tabBackups.Controls.Add($ob)
$listBackups=New-Object Windows.Forms.ListView; $listBackups.Location=New-Object Drawing.Point(15,65); $listBackups.Size=New-Object Drawing.Size(1010,695); $listBackups.View='Details'; $listBackups.FullRowSelect=$true; $listBackups.GridLines=$true; [void]$listBackups.Columns.Add((T 'backups.col_file'),570); [void]$listBackups.Columns.Add((T 'backups.col_date'),230); [void]$listBackups.Columns.Add((T 'backups.col_size'),150); $tabBackups.Controls.Add($listBackups)
$btnRestoreBackup=New-Object Windows.Forms.Button; $btnRestoreBackup.Text=(T 'backups.btn_restore'); $btnRestoreBackup.Location=New-Object Drawing.Point(580,15); $btnRestoreBackup.Size=New-Object Drawing.Size(210,36); $btnRestoreBackup.Add_Click({Restore-SelectedBackup}); $tabBackups.Controls.Add($btnRestoreBackup)
$btnDeleteBackup=New-Object Windows.Forms.Button; $btnDeleteBackup.Text=(T 'backups.btn_delete'); $btnDeleteBackup.Location=New-Object Drawing.Point(805,15); $btnDeleteBackup.Size=New-Object Drawing.Size(200,36); $btnDeleteBackup.Add_Click({Delete-SelectedBackup}); $tabBackups.Controls.Add($btnDeleteBackup)


# Automatizaciones
$autoGroup=New-Object Windows.Forms.GroupBox; $autoGroup.Text=(T 'auto.group'); $autoGroup.Location=New-Object Drawing.Point(15,15); $autoGroup.Size=New-Object Drawing.Size(1015,230); $tabAutomation.Controls.Add($autoGroup)
$chkAutoMessages=New-Object Windows.Forms.CheckBox; $chkAutoMessages.Text=(T 'auto.enable'); $chkAutoMessages.Location=New-Object Drawing.Point(20,30); $chkAutoMessages.AutoSize=$true; $autoGroup.Controls.Add($chkAutoMessages)
$lblInterval=New-Object Windows.Forms.Label; $lblInterval.Text=(T 'auto.every'); $lblInterval.Location=New-Object Drawing.Point(260,32); $lblInterval.AutoSize=$true; $autoGroup.Controls.Add($lblInterval)
$numMessageInterval=New-Object Windows.Forms.NumericUpDown; $numMessageInterval.Location=New-Object Drawing.Point(305,28); $numMessageInterval.Minimum=1; $numMessageInterval.Maximum=1440; $numMessageInterval.Value=30; $autoGroup.Controls.Add($numMessageInterval)
$lblMinutes=New-Object Windows.Forms.Label; $lblMinutes.Text=(T 'auto.minutes'); $lblMinutes.Location=New-Object Drawing.Point(430,32); $lblMinutes.AutoSize=$true; $autoGroup.Controls.Add($lblMinutes)
$chkIncludeTips=New-Object Windows.Forms.CheckBox; $chkIncludeTips.Text=(T 'auto.tips'); $chkIncludeTips.Location=New-Object Drawing.Point(20,70); $chkIncludeTips.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeTips)
$chkIncludeCustom=New-Object Windows.Forms.CheckBox; $chkIncludeCustom.Text=(T 'auto.custom'); $chkIncludeCustom.Location=New-Object Drawing.Point(220,70); $chkIncludeCustom.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeCustom)
$chkIncludeTime=New-Object Windows.Forms.CheckBox; $chkIncludeTime.Text=(T 'auto.add_time'); $chkIncludeTime.Location=New-Object Drawing.Point(440,70); $chkIncludeTime.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeTime)
$lblPrefix=New-Object Windows.Forms.Label; $lblPrefix.Text=(T 'auto.prefix'); $lblPrefix.Location=New-Object Drawing.Point(20,110); $lblPrefix.AutoSize=$true; $autoGroup.Controls.Add($lblPrefix)
$txtMessagePrefix=New-Object Windows.Forms.TextBox; $txtMessagePrefix.Location=New-Object Drawing.Point(90,106); $txtMessagePrefix.Size=New-Object Drawing.Size(180,25); $autoGroup.Controls.Add($txtMessagePrefix)
$btnTestAuto=New-Object Windows.Forms.Button; $btnTestAuto.Text=(T 'auto.btn_test'); $btnTestAuto.Location=New-Object Drawing.Point(300,102); $btnTestAuto.Size=New-Object Drawing.Size(150,34); $btnTestAuto.Add_Click({Send-AutomaticMessage -ManualTest $true}); $autoGroup.Controls.Add($btnTestAuto)
$btnEditTips=New-Object Windows.Forms.Button; $btnEditTips.Text=(T 'auto.btn_edit_tips'); $btnEditTips.Location=New-Object Drawing.Point(465,102); $btnEditTips.Size=New-Object Drawing.Size(160,34); $btnEditTips.Add_Click({Ensure-AutomationFiles;Start-Process notepad.exe $TipsFile}); $autoGroup.Controls.Add($btnEditTips)
$btnEditCustom=New-Object Windows.Forms.Button; $btnEditCustom.Text=(T 'auto.btn_edit_custom'); $btnEditCustom.Location=New-Object Drawing.Point(640,102); $btnEditCustom.Size=New-Object Drawing.Size(200,34); $btnEditCustom.Add_Click({Ensure-AutomationFiles;Start-Process notepad.exe $CustomMessagesFile}); $autoGroup.Controls.Add($btnEditCustom)
$lblAutomationStatus=New-Object Windows.Forms.Label; $lblAutomationStatus.Text=(T 'auto.ready'); $lblAutomationStatus.Location=New-Object Drawing.Point(20,165); $lblAutomationStatus.Size=New-Object Drawing.Size(950,45); $autoGroup.Controls.Add($lblAutomationStatus)

$geminiGroup=New-Object Windows.Forms.GroupBox; $geminiGroup.Text=(T 'gemini.group'); $geminiGroup.Location=New-Object Drawing.Point(15,260); $geminiGroup.Size=New-Object Drawing.Size(1015,140); $tabAutomation.Controls.Add($geminiGroup)
$lblGeminiKey=New-Object Windows.Forms.Label; $lblGeminiKey.Text=(T 'gemini.api_key'); $lblGeminiKey.Location=New-Object Drawing.Point(20,35); $lblGeminiKey.AutoSize=$true; $geminiGroup.Controls.Add($lblGeminiKey)
$txtGeminiKey=New-Object Windows.Forms.TextBox; $txtGeminiKey.Location=New-Object Drawing.Point(90,31); $txtGeminiKey.Size=New-Object Drawing.Size(420,25); $txtGeminiKey.UseSystemPasswordChar=$true; $geminiGroup.Controls.Add($txtGeminiKey)
$lblGeminiModel=New-Object Windows.Forms.Label; $lblGeminiModel.Text=(T 'gemini.model'); $lblGeminiModel.Location=New-Object Drawing.Point(535,35); $lblGeminiModel.AutoSize=$true; $geminiGroup.Controls.Add($lblGeminiModel)
$txtGeminiModel=New-Object Windows.Forms.TextBox; $txtGeminiModel.Location=New-Object Drawing.Point(600,31); $txtGeminiModel.Size=New-Object Drawing.Size(210,25); $geminiGroup.Controls.Add($txtGeminiModel)
$btnGenerateTips=New-Object Windows.Forms.Button; $btnGenerateTips.Text=(T 'gemini.btn_generate'); $btnGenerateTips.Location=New-Object Drawing.Point(825,27); $btnGenerateTips.Size=New-Object Drawing.Size(170,34); $btnGenerateTips.Add_Click({Generate-GeminiTips}); $geminiGroup.Controls.Add($btnGenerateTips)
$lblGeminiNote=New-Object Windows.Forms.Label; $lblGeminiNote.Text=(T 'gemini.note'); $lblGeminiNote.Location=New-Object Drawing.Point(20,85); $lblGeminiNote.Size=New-Object Drawing.Size(950,45); $geminiGroup.Controls.Add($lblGeminiNote)

$smartGroup=New-Object Windows.Forms.GroupBox; $smartGroup.Text=(T 'smart.group'); $smartGroup.Location=New-Object Drawing.Point(15,415); $smartGroup.Size=New-Object Drawing.Size(1015,160); $tabAutomation.Controls.Add($smartGroup)
$chkRestartOnlyEmpty=New-Object Windows.Forms.CheckBox; $chkRestartOnlyEmpty.Text=(T 'smart.only_empty'); $chkRestartOnlyEmpty.Location=New-Object Drawing.Point(20,32); $chkRestartOnlyEmpty.AutoSize=$true; $smartGroup.Controls.Add($chkRestartOnlyEmpty)
$chkRestartLowFps=New-Object Windows.Forms.CheckBox; $chkRestartLowFps.Text=(T 'smart.low_fps'); $chkRestartLowFps.Location=New-Object Drawing.Point(20,70); $chkRestartLowFps.AutoSize=$true; $smartGroup.Controls.Add($chkRestartLowFps)
$lblLowFps=New-Object Windows.Forms.Label; $lblLowFps.Text=(T 'smart.less_than'); $lblLowFps.Location=New-Object Drawing.Point(230,73); $lblLowFps.AutoSize=$true; $smartGroup.Controls.Add($lblLowFps)
$numLowFps=New-Object Windows.Forms.NumericUpDown; $numLowFps.Location=New-Object Drawing.Point(300,69); $numLowFps.Minimum=5; $numLowFps.Maximum=60; $numLowFps.Value=25; $smartGroup.Controls.Add($numLowFps)
$lblDuring=New-Object Windows.Forms.Label; $lblDuring.Text=(T 'smart.fps_during'); $lblDuring.Location=New-Object Drawing.Point(430,73); $lblDuring.AutoSize=$true; $smartGroup.Controls.Add($lblDuring)
$numLowFpsMinutes=New-Object Windows.Forms.NumericUpDown; $numLowFpsMinutes.Location=New-Object Drawing.Point(520,69); $numLowFpsMinutes.Minimum=1; $numLowFpsMinutes.Maximum=120; $numLowFpsMinutes.Value=10; $smartGroup.Controls.Add($numLowFpsMinutes)
$lblLowMinutes=New-Object Windows.Forms.Label; $lblLowMinutes.Text=(T 'smart.minutes'); $lblLowMinutes.Location=New-Object Drawing.Point(650,73); $lblLowMinutes.AutoSize=$true; $smartGroup.Controls.Add($lblLowMinutes)
$lblRetention=New-Object Windows.Forms.Label; $lblRetention.Text=(T 'smart.keep_last'); $lblRetention.Location=New-Object Drawing.Point(20,112); $lblRetention.AutoSize=$true; $smartGroup.Controls.Add($lblRetention)
$numBackupRetention=New-Object Windows.Forms.NumericUpDown; $numBackupRetention.Location=New-Object Drawing.Point(140,108); $numBackupRetention.Minimum=1; $numBackupRetention.Maximum=500; $numBackupRetention.Value=20; $smartGroup.Controls.Add($numBackupRetention)
$lblRetentionSuffix=New-Object Windows.Forms.Label; $lblRetentionSuffix.Text=(T 'smart.backups'); $lblRetentionSuffix.Location=New-Object Drawing.Point(270,112); $lblRetentionSuffix.AutoSize=$true; $smartGroup.Controls.Add($lblRetentionSuffix)
$chkJoinLeave=New-Object Windows.Forms.CheckBox; $chkJoinLeave.Text=(T 'smart.join_leave'); $chkJoinLeave.Location=New-Object Drawing.Point(390,110); $chkJoinLeave.AutoSize=$true; $smartGroup.Controls.Add($chkJoinLeave)
$btnSaveAutomation=New-Object Windows.Forms.Button; $btnSaveAutomation.Text=(T 'smart.btn_save'); $btnSaveAutomation.Location=New-Object Drawing.Point(760,103); $btnSaveAutomation.Size=New-Object Drawing.Size(235,38); $btnSaveAutomation.Add_Click({Save-AutomationSettings}); $smartGroup.Controls.Add($btnSaveAutomation)

$activityGroup=New-Object Windows.Forms.GroupBox; $activityGroup.Text=(T 'activity.group'); $activityGroup.Location=New-Object Drawing.Point(15,590); $activityGroup.Size=New-Object Drawing.Size(1015,210); $tabAutomation.Controls.Add($activityGroup)
$rtbActivity=New-Object Windows.Forms.RichTextBox; $rtbActivity.Location=New-Object Drawing.Point(15,28); $rtbActivity.Size=New-Object Drawing.Size(980,140); $rtbActivity.ReadOnly=$true; $rtbActivity.Font=New-Object Drawing.Font('Consolas',9); $activityGroup.Controls.Add($rtbActivity)
$btnOpenActivity=New-Object Windows.Forms.Button; $btnOpenActivity.Text=(T 'activity.btn_open'); $btnOpenActivity.Location=New-Object Drawing.Point(15,172); $btnOpenActivity.Size=New-Object Drawing.Size(160,30); $btnOpenActivity.Add_Click({if(-not(Test-Path $ActivityLogFile)){New-Item -ItemType File -Path $ActivityLogFile -Force|Out-Null};Start-Process notepad.exe $ActivityLogFile}); $activityGroup.Controls.Add($btnOpenActivity)

# ============ Pestaña Acerca de (bienvenida, version, idiomas, donacion) ============
$aboutTitle = New-Object Windows.Forms.Label
$aboutTitle.Text = $ProductInfo.product
$aboutTitle.Font = New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)
$aboutTitle.AutoSize = $true
$aboutTitle.Location = New-Object Drawing.Point(25, 20)
$tabAbout.Controls.Add($aboutTitle)

$aboutSubtitle = New-Object Windows.Forms.Label
$aboutSubtitle.Text = T "about.subtitle"
$aboutSubtitle.AutoSize = $true
$aboutSubtitle.Location = New-Object Drawing.Point(27, 58)
$tabAbout.Controls.Add($aboutSubtitle)

$featuresGroup = New-Object Windows.Forms.GroupBox
$featuresGroup.Text = T "about.features_title"
$featuresGroup.Location = New-Object Drawing.Point(25, 95)
$featuresGroup.Size = New-Object Drawing.Size(500, 215)
$tabAbout.Controls.Add($featuresGroup)

$featuresLabel = New-Object Windows.Forms.Label
$featuresLabel.Text = T "about.features"
$featuresLabel.Location = New-Object Drawing.Point(18, 28)
$featuresLabel.Size = New-Object Drawing.Size(465, 175)
$featuresGroup.Controls.Add($featuresLabel)

$versionGroup = New-Object Windows.Forms.GroupBox
$versionGroup.Text = T "about.version_title"
$versionGroup.Location = New-Object Drawing.Point(545, 95)
$versionGroup.Size = New-Object Drawing.Size(485, 215)
$tabAbout.Controls.Add($versionGroup)

$versionLabel = New-Object Windows.Forms.Label
$versionLabel.Text = ($ProductInfo.publisher + "`n" + (T "about.version_info" @($ProductInfo.version, $ProductInfo.release_channel, $ProductInfo.build_date)) + "`n`n" + (T "about.license"))
$versionLabel.Location = New-Object Drawing.Point(18, 28)
$versionLabel.Size = New-Object Drawing.Size(450, 130)
$versionGroup.Controls.Add($versionLabel)

$btnGitHub = New-Object Windows.Forms.Button
$btnGitHub.Text = T "about.btn_github"
$btnGitHub.Location = New-Object Drawing.Point(18, 165)
$btnGitHub.Size = New-Object Drawing.Size(180, 34)
$btnGitHub.Add_Click({ if ($AppLinks.homepage_url) { Start-Process $AppLinks.homepage_url } })
$versionGroup.Controls.Add($btnGitHub)

$btnOpenWizard = New-Object Windows.Forms.Button
$btnOpenWizard.Text = T "wizard.btn_open_wizard"
$btnOpenWizard.Location = New-Object Drawing.Point(210, 165)
$btnOpenWizard.Size = New-Object Drawing.Size(255, 34)
$btnOpenWizard.Add_Click({ Show-FirstRunWizard })
$versionGroup.Controls.Add($btnOpenWizard)

$langGroup = New-Object Windows.Forms.GroupBox
$langGroup.Text = T "about.language"
$langGroup.Location = New-Object Drawing.Point(25, 330)
$langGroup.Size = New-Object Drawing.Size(500, 140)
$tabAbout.Controls.Add($langGroup)

$script:LocaleCodes = @(Get-AvailableLocales -LocalesDir $LocalesDir)

$cmbUILanguage = New-Object Windows.Forms.ComboBox
$cmbUILanguage.Location = New-Object Drawing.Point(18, 30)
$cmbUILanguage.Size = New-Object Drawing.Size(220, 25)
$cmbUILanguage.DropDownStyle = "DropDownList"
foreach ($code in $script:LocaleCodes) { [void]$cmbUILanguage.Items.Add((Get-LocaleDisplayName $code)) }
$uiLangIndex = [array]::IndexOf($script:LocaleCodes, $script:UILanguage)
if ($uiLangIndex -ge 0) { $cmbUILanguage.SelectedIndex = $uiLangIndex }
$langGroup.Controls.Add($cmbUILanguage)

$langRestartNote = New-Object Windows.Forms.Label
$langRestartNote.Text = T "about.language_restart"
$langRestartNote.AutoSize = $true
$langRestartNote.Location = New-Object Drawing.Point(255, 34)
$langGroup.Controls.Add($langRestartNote)

$serverLangLabel = New-Object Windows.Forms.Label
$serverLangLabel.Text = T "schedule.server_lang"
$serverLangLabel.AutoSize = $true
$serverLangLabel.Location = New-Object Drawing.Point(18, 72)
$langGroup.Controls.Add($serverLangLabel)

$cmbServerLanguage = New-Object Windows.Forms.ComboBox
$cmbServerLanguage.Location = New-Object Drawing.Point(18, 95)
$cmbServerLanguage.Size = New-Object Drawing.Size(220, 25)
$cmbServerLanguage.DropDownStyle = "DropDownList"
foreach ($code in $script:LocaleCodes) { [void]$cmbServerLanguage.Items.Add((Get-LocaleDisplayName $code)) }
$serverLangIndex = [array]::IndexOf($script:LocaleCodes, $script:ServerLanguage)
if ($serverLangIndex -ge 0) { $cmbServerLanguage.SelectedIndex = $serverLangIndex }
$langGroup.Controls.Add($cmbServerLanguage)

# Los handlers se agregan DESPUES de fijar la seleccion inicial (no disparan al construir)
$cmbUILanguage.Add_SelectedIndexChanged({
    if ($script:LoadingOptions) { return }
    $index = $cmbUILanguage.SelectedIndex
    if ($index -ge 0 -and $index -lt $script:LocaleCodes.Count) {
        $script:UILanguage = $script:LocaleCodes[$index]
        Save-LauncherOptions
        Show-Message (T "about.language_restart")
    }
})

$cmbServerLanguage.Add_SelectedIndexChanged({
    if ($script:LoadingOptions) { return }
    $index = $cmbServerLanguage.SelectedIndex
    if ($index -ge 0 -and $index -lt $script:LocaleCodes.Count) {
        $script:ServerLanguage = $script:LocaleCodes[$index]
        # Los avisos in-game cambian de idioma al instante (no requiere reiniciar)
        Initialize-I18n -LocalesDir $LocalesDir -UILanguage $script:UILanguage -ServerLanguage $script:ServerLanguage
        Save-LauncherOptions
    }
})

$donateGroup = New-Object Windows.Forms.GroupBox
$donateGroup.Text = T "about.donate_title"
$donateGroup.Location = New-Object Drawing.Point(545, 330)
$donateGroup.Size = New-Object Drawing.Size(485, 140)
$tabAbout.Controls.Add($donateGroup)

$donateLabel = New-Object Windows.Forms.Label
$donateLabel.Text = T "about.donate_text"
$donateLabel.Location = New-Object Drawing.Point(18, 28)
$donateLabel.Size = New-Object Drawing.Size(450, 55)
$donateGroup.Controls.Add($donateLabel)

$btnDonate = New-Object Windows.Forms.Button
$btnDonate.Text = T "about.btn_donate"
$btnDonate.Location = New-Object Drawing.Point(18, 90)
$btnDonate.Size = New-Object Drawing.Size(160, 36)
$btnDonate.Add_Click({ if ($AppLinks.donate_url) { Start-Process $AppLinks.donate_url } })
$donateGroup.Controls.Add($btnDonate)

$updateGroup = New-Object Windows.Forms.GroupBox
$updateGroup.Text = T "updater.group"
$updateGroup.Location = New-Object Drawing.Point(25, 490)
$updateGroup.Size = New-Object Drawing.Size(1005, 100)
$tabAbout.Controls.Add($updateGroup)

$btnCheckUpdates = New-Object Windows.Forms.Button
$btnCheckUpdates.Text = T "updater.btn_check"
$btnCheckUpdates.Location = New-Object Drawing.Point(18, 32)
$btnCheckUpdates.Size = New-Object Drawing.Size(250, 38)
$btnCheckUpdates.Add_Click({ Invoke-LauncherUpdateCheck })
$updateGroup.Controls.Add($btnCheckUpdates)

# Solo para desarrolladores: aparece unicamente si el launcher corre
# dentro de un repo git (el usuario final instalado nunca lo ve).
$btnGitUpdate = New-Object Windows.Forms.Button
$btnGitUpdate.Text = T "updater.btn_git"
$btnGitUpdate.Location = New-Object Drawing.Point(285, 32)
$btnGitUpdate.Size = New-Object Drawing.Size(250, 38)
$btnGitUpdate.Visible = (Test-Path -LiteralPath (Join-Path $InstallRoot ".git"))
$btnGitUpdate.Add_Click({ Invoke-GitUpdate })
$updateGroup.Controls.Add($btnGitUpdate)

$lblUpdateStatus = New-Object Windows.Forms.Label
$lblUpdateStatus.Text = ""
$lblUpdateStatus.AutoSize = $true
$lblUpdateStatus.Location = New-Object Drawing.Point(555, 42)
$updateGroup.Controls.Add($lblUpdateStatus)

$tabs.Add_SelectedIndexChanged({if($tabs.SelectedTab -eq $tabPlayers){Start-PlayersJob}elseif($tabs.SelectedTab -eq $tabBackups){Refresh-BackupsList}})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $lblClock.Text = T "panel.clock" @((Get-Date -Format "HH:mm:ss"))
        Update-AutomaticMessages
        Update-SmartRestart
        Update-Status
        Update-RestartSchedule
    }
    catch {
        $lblAction.Text = T "panel.tick_error" @($_.Exception.Message)
    }
})
$timer.Start()

$metricsTimer = New-Object Windows.Forms.Timer
$metricsTimer.Interval = 15000
$metricsTimer.Add_Tick({
    try {
        Start-MetricsWorker
    }
    catch {
        $lblAction.Text = T "panel.metrics_error" @($_.Exception.Message)
    }
})
$metricsTimer.Start()

$form.Add_Shown({
    Load-Settings
    Load-AutomationSettings

    if (Test-Path -LiteralPath $ActivityLogFile) {
        try {
            $rtbActivity.Lines = @(Get-Content -LiteralPath $ActivityLogFile -Tail 500)
            $rtbActivity.SelectionStart = $rtbActivity.TextLength
            $rtbActivity.ScrollToCaret()
        }
        catch {}
    }

    Load-ChatHistory
    Refresh-BackupsList
    Update-Status
    Update-RestartSchedule
    Start-MetricsWorker

    # Primera ejecucion sin server configurado: ofrecer el asistente.
    # "Ahora no" queda registrado y no se vuelve a preguntar (boton manual
    # en Acerca de). En modo portable no aplica (layout clasico).
    if (
        -not $IsPortable -and
        -not (Test-Path -LiteralPath $ServerExe) -and
        -not (Test-Path -LiteralPath (Join-Path $DataRoot "wizard-declined.flag"))
    ) {
        Show-FirstRunWizard
    }

    # Opcion "iniciar el servidor al abrir el launcher": combinada con el
    # autostart del launcher en Windows (tarea del instalador), el server
    # completo levanta solo al prender la PC.
    if ($chkAutoStartServer.Checked -and (Test-Path -LiteralPath $ServerExe) -and -not (Get-ServerProcess)) {
        Start-Server
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    $metricsTimer.Stop()

    if ($script:MetricsJob) {
        Stop-Job -Job $script:MetricsJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:MetricsJob -Force -ErrorAction SilentlyContinue
        $script:MetricsJob = $null
    }
})

[void]$form.ShowDialog()
