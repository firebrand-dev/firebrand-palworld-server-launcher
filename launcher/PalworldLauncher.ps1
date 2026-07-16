Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $Root "server"
$ServerExe = Join-Path $ServerDir "PalServer.exe"
$SteamCmdExe = Join-Path $Root "steamcmd\steamcmd.exe"
$ConfigFile = Join-Path $ServerDir "Pal\Saved\Config\WindowsServer\PalWorldSettings.ini"
$DefaultConfig = Join-Path $ServerDir "DefaultPalWorldSettings.ini"
$SaveDir = Join-Path $ServerDir "Pal\Saved"
$BackupDir = Join-Path $Root "backups"
$LogsDir = Join-Path $Root "logs"
$CurrentServerLog = Join-Path $LogsDir "server_current.log"
$ChatHistoryFile = Join-Path $LogsDir "chat_history.log"
$AutomationConfigFile = Join-Path $Root "automation-settings.json"
$TipsFile = Join-Path $Root "palworld_tips.txt"
$CustomMessagesFile = Join-Path $Root "custom_messages.txt"
$ActivityLogFile = Join-Path $LogsDir "activity.log"
$GeminiKeyFile = Join-Path $Root "gemini-key.dat"
$LauncherConfig = Join-Path $Root "launcher-settings.json"

New-Item -ItemType Directory -Force -Path $BackupDir,$LogsDir | Out-Null

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

function Get-ServerProcess {
    try {
        $processes = Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessName -like "PalServer*"
            } |
            Sort-Object WorkingSet64 -Descending

        if ($processes) {
            return $processes | Select-Object -First 1
        }
    }
    catch {}

    return $null
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
        $lblAction.Text = "Aviso enviado: $Message"
        return $true
    }
    catch {
        $lblAction.Text = "No se pudo enviar el aviso por REST API."
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
        $lblAutomationStatus.Text = "Configuración guardada: " + (Get-Date -Format "HH:mm:ss")
        Write-Activity "Configuración de automatizaciones guardada."
    }
    catch {
        Show-Message $_.Exception.Message "Automatizaciones" "Error"
    }
}

function Load-AutomationSettings {
    Ensure-AutomationFiles

    $chkAutoMessages.Checked = $false
    $numMessageInterval.Value = 30
    $chkIncludeTips.Checked = $true
    $chkIncludeCustom.Checked = $true
    $chkIncludeTime.Checked = $true
    $txtMessagePrefix.Text = "[SERVIDOR]"
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
        $lblAutomationStatus.Text = "No se pudo leer automation-settings.json."
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
        $parts.Add("Hora del servidor: " + (Get-Date -Format "HH:mm"))
    }

    return ($parts -join " ")
}

function Send-AutomaticMessage([bool]$ManualTest = $false) {
    if (-not (Get-ServerProcess)) {
        if ($ManualTest) {
            Show-Message "El servidor está detenido." "Mensajes automáticos" "Warning"
        }
        return
    }

    $message = Get-AutomaticMessage

    if ([string]::IsNullOrWhiteSpace($message)) {
        if ($ManualTest) {
            Show-Message "No hay mensajes disponibles. Revisá los archivos de consejos y mensajes personalizados." "Mensajes automáticos" "Warning"
        }
        return
    }

    if (Send-Announcement $message) {
        $script:LastAutoMessageAt = Get-Date
        Append-ChatLine `
            -Timestamp (Get-Date -Format "HH:mm:ss") `
            -Author "SERVIDOR" `
            -Message $message `
            -IsServer $true

        Write-Activity "Mensaje automático enviado: $message"
        $lblAutomationStatus.Text = "Último mensaje: " + (Get-Date -Format "HH:mm:ss")

        if ($ManualTest) {
            Show-Message "Mensaje enviado correctamente:`n`n$message"
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
        Show-Message "Ingresá una clave de Gemini API." "Gemini" "Warning"
        return
    }

    if ([string]::IsNullOrWhiteSpace($model)) {
        Show-Message "Ingresá el nombre del modelo de Gemini." "Gemini" "Warning"
        return
    }

    $lblAutomationStatus.Text = "Generando consejos con Gemini..."
    $form.Refresh()

    try {
        $prompt = @"
Generá exactamente 40 consejos breves, útiles y seguros sobre Palworld para anunciar dentro de un servidor dedicado.
Reglas:
- Español rioplatense neutro.
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

        $lblAutomationStatus.Text = "Gemini agregó $($newTips.Count) consejos."
        Write-Activity "Gemini agregó $($newTips.Count) consejos al archivo local."
        Show-Message "Se agregaron $($newTips.Count) consejos.`nTotal disponible: $($merged.Count)"
    }
    catch {
        Show-Message ("No se pudieron generar consejos:`n`n" + $_.Exception.Message) "Gemini" "Error"
        $lblAutomationStatus.Text = "Error al generar consejos."
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

        Write-Activity "Se aplicó retención de backups: máximo $keep."
    }
    catch {}
}

function Delete-SelectedBackup {
    if ($listBackups.SelectedItems.Count -eq 0) {
        Show-Message "Seleccioná un backup." "Backups" "Warning"
        return
    }

    $path = [string]$listBackups.SelectedItems[0].Tag
    $answer = [Windows.Forms.MessageBox]::Show(
        "¿Eliminar este backup?`n`n$path",
        "Confirmar eliminación",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        Remove-Item -LiteralPath $path -Force
        Write-Activity "Backup eliminado: $([IO.Path]::GetFileName($path))"
        Refresh-BackupsList
    }
}

function Restore-SelectedBackup {
    if (Get-ServerProcess) {
        Show-Message "Detené el servidor antes de restaurar un backup." "Restaurar backup" "Warning"
        return
    }

    if ($listBackups.SelectedItems.Count -eq 0) {
        Show-Message "Seleccioná un backup." "Restaurar backup" "Warning"
        return
    }

    $backupPath = [string]$listBackups.SelectedItems[0].Tag

    $first = [Windows.Forms.MessageBox]::Show(
        "Esto reemplazará la carpeta Pal\Saved actual.`n`n¿Continuar?",
        "Restaurar backup",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($first -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    $second = [Windows.Forms.MessageBox]::Show(
        "Confirmación final: ¿restaurar $([IO.Path]::GetFileName($backupPath))?",
        "Confirmación final",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($second -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        $safety = Backup-World
        $temp = Join-Path $env:TEMP ("palworld_restore_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        Expand-Archive -LiteralPath $backupPath -DestinationPath $temp -Force

        Remove-Item -LiteralPath $SaveDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null

        Get-ChildItem -LiteralPath $temp -Force |
            Copy-Item -Destination $SaveDir -Recurse -Force

        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Activity "Backup restaurado: $([IO.Path]::GetFileName($backupPath))"
        Show-Message "Backup restaurado correctamente.`nSe creó una copia de seguridad previa."
    }
    catch {
        Show-Message ("No se pudo restaurar:`n`n" + $_.Exception.Message) "Restaurar backup" "Error"
    }
}

function Get-SelectedPlayer {
    if ($listPlayers.SelectedItems.Count -eq 0) {
        Show-Message "Seleccioná un jugador." "Jugadores" "Warning"
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
    $lblPlayersStatus.Text = "User ID copiado: $uid"
}

function Kick-SelectedPlayer {
    $player = Get-SelectedPlayer

    if ($null -eq $player) {
        return
    }

    $uid = [string]$player.userId
    $name = [string]$player.name

    try {
        Invoke-PalApi -Method "POST" -Path "kick" -Body @{ userid = $uid; message = "Expulsado por administración." } -TimeoutSeconds 5 | Out-Null
        Write-Activity "Jugador expulsado: $name ($uid)"
        Show-Message "$name fue expulsado."
        Start-PlayersJob
    }
    catch {
        Show-Message $_.Exception.Message "Expulsar jugador" "Error"
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
        "¿Banear a $name?",
        "Confirmar ban",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Invoke-PalApi -Method "POST" -Path "ban" -Body @{ userid = $uid } -TimeoutSeconds 5 | Out-Null
        Write-Activity "Jugador baneado: $name ($uid)"
        Show-Message "$name fue baneado."
        Start-PlayersJob
    }
    catch {
        Show-Message $_.Exception.Message "Banear jugador" "Error"
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
                Write-Activity "FPS bajos detectados: $fps."
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
            $lblAutomationStatus.Text = "Reinicio inteligente esperando servidor vacío."
            return
        }

        Send-Announcement "El servidor se reiniciará por mantenimiento de rendimiento." | Out-Null
        Write-Activity "Reinicio inteligente iniciado."
        $script:PendingSmartRestart = $false
        $script:LowFpsSince = $null
        Restart-Server -Automatic $true
    }
}

function Save-LauncherOptions {
    $timeValue = $timeRestart.Value.ToString("HH:mm")

    @{
        PublicLobby = $chkPublicLobby.Checked
        AutoBackup = $chkAutoBackup.Checked
        WorkerThreads = [int]$numWorkers.Value
        UseLegacyPerformanceArgs = $chkLegacyPerfArgs.Checked
        RestartMode = [string]$cmbRestartMode.SelectedItem
        AutoRestartHours = [int]$numAutoRestart.Value
        DailyRestartTime = $timeValue
    } | ConvertTo-Json | Set-Content -LiteralPath $LauncherConfig -Encoding UTF8
}

function Load-LauncherOptions {
    $chkPublicLobby.Checked = $true
    $chkAutoBackup.Checked = $true
    $numWorkers.Value = 4
    $chkLegacyPerfArgs.Checked = $false
    $cmbRestartMode.SelectedItem = "Desactivado"
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

        if ($null -ne $config.AutoRestartHours) {
            $numAutoRestart.Value = [decimal]$config.AutoRestartHours
        }

        if (
            $null -ne $config.RestartMode -and
            $cmbRestartMode.Items.Contains([string]$config.RestartMode)
        ) {
            $cmbRestartMode.SelectedItem = [string]$config.RestartMode
        }

        if ($null -ne $config.DailyRestartTime) {
            $parts = ([string]$config.DailyRestartTime).Split(":")
            if ($parts.Count -eq 2) {
                $timeRestart.Value = [datetime]::Today.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
            }
        }
    }
    catch {
        $lblAction.Text = "No se pudo leer launcher-settings.json; se usarán valores predeterminados."
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

        $lblAction.Text = "Configuración guardada: " + (Get-Date -Format "HH:mm:ss")
        Show-Message "Configuración guardada. Reiniciá el servidor para aplicar cambios del juego."
    }
    catch {
        Show-Message $_.Exception.Message "Error al guardar" "Error"
    }
}

function Load-Settings {
    try {
        $text = Get-IniText

        $txtName.Text = Get-IniValue $text "ServerName" "Mi servidor Palworld"
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

        Load-LauncherOptions
        Reset-RestartSchedule
    }
    catch {
        Show-Message $_.Exception.Message "Error al leer configuración" "Error"
    }
}

function Backup-World {
    if (-not (Test-Path -LiteralPath $SaveDir)) {
        return $null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $destination = Join-Path $BackupDir "Palworld_Save_$timestamp.zip"

    Compress-Archive `
        -Path (Join-Path $SaveDir "*") `
        -DestinationPath $destination `
        -CompressionLevel Optimal `
        -Force

    $script:LastBackupAt = Get-Date
    Write-Activity "Backup creado: $([IO.Path]::GetFileName($destination))"
    Apply-BackupRetention
    return $destination
}

function Start-Server {
    try {
        $existing = Get-ServerProcess
        if ($existing) { Show-Message "El servidor ya está ejecutándose. PID: $($existing.Id)"; Update-Status; return }
        if (-not (Test-Path -LiteralPath $ServerExe)) { Show-Message "No se encontró:`n$ServerExe" "Error al iniciar" "Error"; return }
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
        $commandLine = '""' + $ServerExe + '" ' + $arguments + ' >> "' + $CurrentServerLog + '" 2>&1"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/d /s /c $commandLine"
        $psi.WorkingDirectory = $ServerDir
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $proc) { throw "Windows no devolvió el proceso iniciador." }
        $lblAction.Text = "Iniciando servidor y captura de logs..."
        Write-Activity "Inicio del servidor solicitado."
        Start-Sleep -Seconds 4
        if (-not (Get-ServerProcess)) { throw "PalServer se abrió, pero el proceso no quedó ejecutándose." }
        $script:NextRestartAt=$null; $script:ScheduleSignature=""; $script:AnnouncedMinutes.Clear(); $script:LastServerInfo=$null
        Update-Status; Update-RestartSchedule
    } catch { Show-Message ("No se pudo iniciar PalServer:`n`n"+$_.Exception.Message) "Error al iniciar" "Error"; Update-Status }
}

function Stop-Server(
    [bool]$RestartAfter = $false,
    [string]$ShutdownMessage = "El servidor se está reiniciando."
) {
    $process = Get-ServerProcess

    if (-not $process) {
        Update-Status
        if ($RestartAfter) {
            Start-Server
        }
        return
    }

    $lblStatus.Text = "Estado: guardando y deteniendo..."
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
        $lblAction.Text = "REST API no respondió; se usará cierre forzado de respaldo."
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

    Get-Process `
        -Name "PalServer","PalServer-Win64-Test","PalServer-Win64-Shipping" `
        -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Update-Status
    Write-Activity "Servidor detenido."

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

            $lblAction.Text = "Creando backup antes de reiniciar..."
            $form.Refresh()

            try {
                $backup = Backup-World
                if ($backup) {
                    $lblAction.Text = "Backup creado: " + [IO.Path]::GetFileName($backup)
                }
            }
            catch {
                $lblAction.Text = "No se pudo crear el backup: " + $_.Exception.Message
            }
        }

        if ($Automatic) {
            Send-Announcement "El servidor se reinicia ahora." | Out-Null
        }

        Stop-Server -RestartAfter $true -ShutdownMessage "El servidor se está reiniciando."
    }
    finally {
        $script:RestartInProgress = $false
        $script:NextRestartAt = $null
        $script:ScheduleSignature = ""
        $script:AnnouncedMinutes.Clear()
    }
}

function Update-Server {
    if (-not (Test-Path -LiteralPath $SteamCmdExe)) {
        Show-Message "No se encontró SteamCMD." "Error" "Error"
        return
    }

    $wasRunning = [bool](Get-ServerProcess)

    if ($wasRunning) {
        Stop-Server
    }

    $lblStatus.Text = "Estado: actualizando servidor..."
    $form.Refresh()

    $arguments = "+force_install_dir `"$ServerDir`" +login anonymous +app_update 2394010 validate +quit"

    $process = Start-Process `
        -FilePath $SteamCmdExe `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    if ($process.ExitCode -ne 0) {
        Show-Message "SteamCMD terminó con código $($process.ExitCode)." "Error" "Error"
    }
    elseif ($wasRunning) {
        Start-Server
    }

    $script:LastServerInfo = $null
    $lblVersion.Text = "Servidor: " + (Get-ServerVersion)
    Update-Status
}

function Get-ServerVersion {
    if ($script:LastServerInfo -and $script:LastServerInfo.version) {
        return [string]$script:LastServerInfo.version
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
        $manifest = Get-ChildItem `
            -LiteralPath $Root `
            -Filter "appmanifest_2394010.acf" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($manifest) {
            $raw = Get-Content -LiteralPath $manifest.FullName -Raw
            $match = [regex]::Match($raw, '"buildid"\s+"(?<id>\d+)"')

            if ($match.Success) {
                return "Steam Build " + $match.Groups["id"].Value
            }
        }
    }
    catch {}

    return "Esperando API"
}

function Get-ScheduleSignature {
    $process = Get-ServerProcess
    $processPart = if ($process) {
        "$($process.Id)|$($process.StartTime.Ticks)"
    }
    else {
        "offline"
    }

    $mode = [string]$cmbRestartMode.SelectedItem
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

    $mode = [string]$cmbRestartMode.SelectedItem

    if ($mode -eq "Cada ciertas horas") {
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

    if ($mode -eq "Hora fija diaria") {
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
        $lblNextRestart.Text = "Próximo reinicio: desactivado"
        $btnCancelRestart.Enabled = $false
        return
    }

    $remaining = $script:NextRestartAt - (Get-Date)

    if ($remaining.TotalSeconds -le 0) {
        $lblNextRestart.Text = "Reinicio programado en curso..."
        $btnCancelRestart.Enabled = $false
        Restart-Server -Automatic $true
        return
    }

    $btnCancelRestart.Enabled = $true

    $hours = [math]::Floor($remaining.TotalHours)
    $minutes = $remaining.Minutes
    $seconds = $remaining.Seconds

    $lblNextRestart.Text = (
        "Próximo reinicio: {0:dd/MM/yyyy HH:mm}  |  Faltan {1:00}:{2:00}:{3:00}" -f
        $script:NextRestartAt,
        $hours,
        $minutes,
        $seconds
    )

    $warningThresholds = @(25,15,10,9,8,7,6,5,4,3,2,1)

    foreach ($threshold in $warningThresholds) {
        if (
            $remaining.TotalSeconds -le ($threshold * 60) -and
            -not $script:AnnouncedMinutes.Contains($threshold)
        ) {
            $message = if ($threshold -eq 1) {
                "El servidor se reiniciará en 1 minuto."
            }
            else {
                "El servidor se reiniciará en $threshold minutos."
            }

            Send-Announcement $message | Out-Null
            $script:AnnouncedMinutes.Add($threshold) | Out-Null
            break
        }
    }
}

function Cancel-ScheduledRestart {
    if ($null -eq $script:NextRestartAt) {
        Show-Message "No hay un reinicio programado activo."
        return
    }

    $previousTarget = $script:NextRestartAt
    $mode = [string]$cmbRestartMode.SelectedItem

    if ($mode -eq "Cada ciertas horas") {
        $hours = [int]$numAutoRestart.Value
        $script:NextRestartAt = (Get-Date).AddHours($hours)
    }
    elseif ($mode -eq "Hora fija diaria") {
        $script:NextRestartAt = $previousTarget.AddDays(1)
    }
    else {
        $script:NextRestartAt = $null
    }

    $script:AnnouncedMinutes.Clear()

    Send-Announcement "El reinicio programado fue cancelado." | Out-Null

    if ($null -ne $script:NextRestartAt) {
        $lblAction.Text = "Reinicio cancelado. Próximo: " + $script:NextRestartAt.ToString("dd/MM/yyyy HH:mm")
    }
    else {
        $lblAction.Text = "Reinicio programado cancelado."
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
    $lblAction.Text = "Probando REST API..."
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
        Show-Message (
            "REST API conectada correctamente.`n`n" +
            "FPS: $($script:LastMetrics.serverfps)`n" +
            "Jugadores: $($script:LastMetrics.currentplayernum)/$($script:LastMetrics.maxplayernum)`n" +
            "Versión: $($script:LastServerInfo.version)"
        )
    }
    else {
        Show-Message (
            "La REST API no respondió correctamente.`n`n" +
            $script:LastMetricsError +
            "`n`nVerificá la Clave admin/API, guardá la configuración y reiniciá PalServer."
        ) "Diagnóstico REST API" "Warning"
    }
}



function Append-ChatLine([string]$Timestamp,[string]$Author,[string]$Message,[bool]$IsServer=$false) {
    if (-not $rtbChat) { return }
    $line = if ($IsServer) { "[${Timestamp}] SERVIDOR: $Message" } else { "[${Timestamp}] ${Author}: $Message" }
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
            }
            $script:LogPosition=$fs.Position; $sr.Dispose()
        } finally { $fs.Dispose() }
    } catch { $lblAction.Text='No se pudo leer el log: '+$_.Exception.Message }
}
function Send-ServerChat {
    $message=$txtChatMessage.Text.Trim(); if ([string]::IsNullOrWhiteSpace($message)) { return }
    if (Send-Announcement $message) { Append-ChatLine (Get-Date -Format 'HH:mm:ss') 'SERVIDOR' $message $true; $txtChatMessage.Clear() }
    else { Show-Message 'No se pudo enviar el mensaje. Revisá REST API y clave admin.' 'Chat' 'Warning' }
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
        try { $r=Receive-Job $script:PlayersJob -ErrorAction SilentlyContinue|Select-Object -Last 1; if ($r.Success) { $listPlayers.Items.Clear(); foreach($pl in @($r.Players)) { $i=New-Object Windows.Forms.ListViewItem([string]$pl.name); [void]$i.SubItems.Add([string]$pl.level); [void]$i.SubItems.Add([string]$pl.ping); [void]$i.SubItems.Add([string]$pl.accountName); [void]$i.SubItems.Add([string]$pl.userId); [void]$listPlayers.Items.Add($i) }; $lblPlayersStatus.Text='Jugadores conectados: '+@($r.Players).Count } else { $lblPlayersStatus.Text='Error: '+$r.Error } } catch { $lblPlayersStatus.Text='Error: '+$_.Exception.Message }
        Remove-Job $script:PlayersJob -Force -ErrorAction SilentlyContinue; $script:PlayersJob=$null
    }
    if (-not (Get-ServerProcess)) { $lblPlayersStatus.Text='Servidor detenido.'; return }
    $pw=$txtAdmin.Text; $port=[int]$numApiPort.Value
    $script:PlayersJob=Start-Job -ArgumentList $pw,$port -ScriptBlock { param($Password,$Port) try { $cred='admin:'+$Password; $enc=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cred)); $resp=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/api/players" -Headers @{Authorization="Basic $enc"} -TimeoutSec 3 -UseBasicParsing; $pls=if($resp.players){@($resp.players)}else{@($resp)}; [pscustomobject]@{Success=$true;Players=$pls;Error=''} } catch { [pscustomobject]@{Success=$false;Players=@();Error=$_.Exception.Message} } }
}

function Update-Status {
    $process = Get-ServerProcess

    if (-not $process) {
        $lblStatus.Text = "Estado: DETENIDO"
        $lblStatus.ForeColor = [Drawing.Color]::DarkRed
        $lblMetrics.Text = "FPS: --   Jugadores: --   Frame: -- ms   RAM: --   CPU: --"
        $lblQuality.Text = "Rendimiento: --"
        $lblUptime.Text = "Tiempo encendido: --"
        $script:LastCpuTime = $null
        $script:LastCpuAt = $null
        $script:LastMetrics = $null
        return
    }

    $lblStatus.Text = "Estado: ONLINE | PID $($process.Id)"
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

    $lblUptime.Text = "Tiempo encendido: " + ((Get-Date)-$process.StartTime).ToString("dd\.hh\:mm\:ss")

    $fps = "--"
    $players = "--"
    $frame = "--"

    if ($script:LastMetrics) {
        try {
            $fps = $script:LastMetrics.serverfps
            $players = "$($script:LastMetrics.currentplayernum)/$($script:LastMetrics.maxplayernum)"
            $frame = [math]::Round([double]$script:LastMetrics.serverframetime,1)

            if ([int]$fps -ge 55) {
                $lblQuality.Text = "Rendimiento: EXCELENTE"
            }
            elseif ([int]$fps -ge 40) {
                $lblQuality.Text = "Rendimiento: BUENO"
            }
            elseif ([int]$fps -ge 30) {
                $lblQuality.Text = "Rendimiento: ACEPTABLE"
            }
            else {
                $lblQuality.Text = "Rendimiento: BAJO"
            }
        }
        catch {
            $lblQuality.Text = "Métricas recibidas con formato inesperado"
        }
    }
    else {
        if ($script:LastMetricsError) {
            $lblQuality.Text = "REST API: " + $script:LastMetricsError
        }
        else {
            $lblQuality.Text = "Esperando REST API..."
        }
    }

    $lblMetrics.Text = "FPS: $fps   Jugadores: $players   Frame: $frame ms   RAM: $ram GB   CPU: $cpuText"
    $lblVersion.Text = "Servidor: " + (Get-ServerVersion)
}

$form = New-Object Windows.Forms.Form
$form.Text = "Palworld Server Manager v8 - Chat y gestión"
$form.Size = New-Object Drawing.Size(1100,900)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI",10)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = "PALWORLD DEDICATED SERVER"
$title.Font = New-Object Drawing.Font("Segoe UI",18,[Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(25,15)
$form.Controls.Add($title)

$lblVersion = New-Object Windows.Forms.Label
$lblVersion.Text = "Servidor: " + (Get-ServerVersion)
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
$lblClock.Text = "Hora: --:--:--"
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

Add-MainButton "INICIAR" 25 135 { Start-Server } | Out-Null
Add-MainButton "DETENER" 170 135 { Stop-Server } | Out-Null
Add-MainButton "REINICIAR AHORA" 315 150 { Restart-Server } | Out-Null
Add-MainButton "ACTUALIZAR" 475 135 { Update-Server } | Out-Null
Add-MainButton "BACKUP" 620 135 {
    try {
        $backup = Backup-World
        if ($backup) {
            Show-Message "Backup creado:`n$backup"
        }
    }
    catch {
        Show-Message $_.Exception.Message "Error" "Error"
    }
} | Out-Null
Add-MainButton "CARPETA SERVER" 765 170 {
    Start-Process explorer.exe $ServerDir
} | Out-Null

$group = New-Object Windows.Forms.GroupBox
$group.Text = "Configuración del servidor"
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

Add-Label "Nombre" 18 35
$txtName = Add-TextBox 160 31 725

Add-Label "Descripción" 18 70
$txtDescription = Add-TextBox 160 66 725

Add-Label "Clave jugadores" 18 105
$txtPassword = Add-TextBox 160 101 250 $true

Add-Label "Clave admin/API" 475 105
$txtAdmin = Add-TextBox 610 101 275 $true

Add-Label "Máx. jugadores" 18 140
$numPlayers = Add-Number 160 136 1 128

Add-Label "Puerto juego UDP" 475 140
$numPort = Add-Number 610 136 1 65535

Add-Label "Puerto REST local" 18 175
$numApiPort = Add-Number 160 171 1 65535

Add-Label "Workers CPU" 475 175
$numWorkers = Add-Number 610 171 1 16

$chkLegacyPerfArgs = New-Object Windows.Forms.CheckBox
$chkLegacyPerfArgs.Text = "Usar parámetros de rendimiento antiguos"
$chkLegacyPerfArgs.Location = New-Object Drawing.Point(735,172)
$chkLegacyPerfArgs.AutoSize = $true
$group.Controls.Add($chkLegacyPerfArgs)

Add-Label "EXP" 18 210
$numExp = Add-Number 160 206 0.1 20 1 0.1

Add-Label "Captura" 475 210
$numCapture = Add-Number 610 206 0.1 20 1 0.1

Add-Label "Cantidad de Pals" 18 245
$numSpawn = Add-Number 160 241 0.1 10 1 0.1

Add-Label "Incubación (horas)" 475 245
$numEgg = Add-Number 610 241 0 240 1 0.5

Add-Label "Penalidad al morir" 18 280
$cmbDeath = New-Object Windows.Forms.ComboBox
$cmbDeath.Location = New-Object Drawing.Point(160,276)
$cmbDeath.Size = New-Object Drawing.Size(250,25)
$cmbDeath.DropDownStyle = "DropDownList"
[void]$cmbDeath.Items.AddRange(@("None","Item","ItemAndEquipment","All"))
$group.Controls.Add($cmbDeath)

$chkPvP = New-Object Windows.Forms.CheckBox
$chkPvP.Text = "PvP"
$chkPvP.Location = New-Object Drawing.Point(20,320)
$chkPvP.AutoSize = $true
$group.Controls.Add($chkPvP)

$chkPublicLobby = New-Object Windows.Forms.CheckBox
$chkPublicLobby.Text = "Servidor comunitario / Xbox (-publiclobby)"
$chkPublicLobby.Location = New-Object Drawing.Point(120,320)
$chkPublicLobby.AutoSize = $true
$group.Controls.Add($chkPublicLobby)

$chkAutoBackup = New-Object Windows.Forms.CheckBox
$chkAutoBackup.Text = "Backup antes de reiniciar"
$chkAutoBackup.Location = New-Object Drawing.Point(490,320)
$chkAutoBackup.AutoSize = $true
$group.Controls.Add($chkAutoBackup)

$btnSave = New-Object Windows.Forms.Button
$btnSave.Text = "GUARDAR CONFIGURACIÓN"
$btnSave.Location = New-Object Drawing.Point(20,345)
$btnSave.Size = New-Object Drawing.Size(245,35)
$btnSave.Add_Click({ Save-Settings })
$group.Controls.Add($btnSave)

$btnIni = New-Object Windows.Forms.Button
$btnIni.Text = "ABRIR INI"
$btnIni.Location = New-Object Drawing.Point(280,345)
$btnIni.Size = New-Object Drawing.Size(145,35)
$btnIni.Add_Click({
    Ensure-Ini
    Start-Process notepad.exe $ConfigFile
})
$group.Controls.Add($btnIni)

$btnBackups = New-Object Windows.Forms.Button
$btnBackups.Text = "CARPETA BACKUPS"
$btnBackups.Location = New-Object Drawing.Point(440,345)
$btnBackups.Size = New-Object Drawing.Size(180,35)
$btnBackups.Add_Click({
    Start-Process explorer.exe $BackupDir
})
$group.Controls.Add($btnBackups)

$scheduleGroup = New-Object Windows.Forms.GroupBox
$scheduleGroup.Text = "Reinicio automático y avisos a jugadores"
$scheduleGroup.Location = New-Object Drawing.Point(25,610)
$scheduleGroup.Size = New-Object Drawing.Size(920,150)
$form.Controls.Add($scheduleGroup)

$scheduleModeLabel = New-Object Windows.Forms.Label
$scheduleModeLabel.Text = "Modo"
$scheduleModeLabel.AutoSize = $true
$scheduleModeLabel.Location = New-Object Drawing.Point(20,32)
$scheduleGroup.Controls.Add($scheduleModeLabel)

$cmbRestartMode = New-Object Windows.Forms.ComboBox
$cmbRestartMode.Location = New-Object Drawing.Point(80,28)
$cmbRestartMode.Size = New-Object Drawing.Size(210,25)
$cmbRestartMode.DropDownStyle = "DropDownList"
[void]$cmbRestartMode.Items.AddRange(@(
    "Desactivado",
    "Cada ciertas horas",
    "Hora fija diaria"
))
$cmbRestartMode.SelectedItem = "Desactivado"
$scheduleGroup.Controls.Add($cmbRestartMode)

$hoursLabel = New-Object Windows.Forms.Label
$hoursLabel.Text = "Cada"
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
$hoursSuffix.Text = "horas"
$hoursSuffix.AutoSize = $true
$hoursSuffix.Location = New-Object Drawing.Point(445,32)
$scheduleGroup.Controls.Add($hoursSuffix)

$timeLabel = New-Object Windows.Forms.Label
$timeLabel.Text = "Hora diaria"
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
$btnApplySchedule.Text = "APLICAR HORARIO"
$btnApplySchedule.Location = New-Object Drawing.Point(735,25)
$btnApplySchedule.Size = New-Object Drawing.Size(160,32)
$btnApplySchedule.Add_Click({
    Save-LauncherOptions
    Reset-RestartSchedule
    $lblAction.Text = "Horario de reinicio aplicado."
})
$scheduleGroup.Controls.Add($btnApplySchedule)

$lblNextRestart = New-Object Windows.Forms.Label
$lblNextRestart.Text = "Próximo reinicio: desactivado"
$lblNextRestart.Font = New-Object Drawing.Font("Segoe UI",10,[Drawing.FontStyle]::Bold)
$lblNextRestart.AutoSize = $true
$lblNextRestart.Location = New-Object Drawing.Point(20,78)
$scheduleGroup.Controls.Add($lblNextRestart)

$btnCancelRestart = New-Object Windows.Forms.Button
$btnCancelRestart.Text = "CANCELAR PRÓXIMO REINICIO"
$btnCancelRestart.Location = New-Object Drawing.Point(650,70)
$btnCancelRestart.Size = New-Object Drawing.Size(245,38)
$btnCancelRestart.Enabled = $false
$btnCancelRestart.Add_Click({ Cancel-ScheduledRestart })
$scheduleGroup.Controls.Add($btnCancelRestart)

$warningLabel = New-Object Windows.Forms.Label
$warningLabel.Text = "Avisos automáticos: 25, 15 y 10 minutos; después 9, 8, 7... hasta 1 minuto."
$warningLabel.AutoSize = $true
$warningLabel.Location = New-Object Drawing.Point(20,115)
$scheduleGroup.Controls.Add($warningLabel)

$btnTestApi = New-Object Windows.Forms.Button
$btnTestApi.Text = "PROBAR REST API"
$btnTestApi.Location = New-Object Drawing.Point(735,108)
$btnTestApi.Size = New-Object Drawing.Size(160,30)
$btnTestApi.Add_Click({ Test-RestApi })
$scheduleGroup.Controls.Add($btnTestApi)

$lblAction = New-Object Windows.Forms.Label
$lblAction.Text = "Listo."
$lblAction.AutoSize = $true
$lblAction.Location = New-Object Drawing.Point(28,780)
$form.Controls.Add($lblAction)

$securityNote = New-Object Windows.Forms.Label
$securityNote.Text = "REST API: solo local/LAN. No abras el puerto REST en Internet."
$securityNote.AutoSize = $true
$securityNote.Location = New-Object Drawing.Point(28,810)
$form.Controls.Add($securityNote)

$cmbRestartMode.Add_SelectedIndexChanged({
    Save-LauncherOptions
    Reset-RestartSchedule
})

$numAutoRestart.Add_ValueChanged({
    if ([string]$cmbRestartMode.SelectedItem -eq "Cada ciertas horas") {
        Reset-RestartSchedule
    }
})

$timeRestart.Add_ValueChanged({
    if ([string]$cmbRestartMode.SelectedItem -eq "Hora fija diaria") {
        Reset-RestartSchedule
    }
})


$existingControls=@($form.Controls)
$tabs=New-Object Windows.Forms.TabControl; $tabs.Location=New-Object Drawing.Point(5,5); $tabs.Size=New-Object Drawing.Size(1070,845); $tabs.Anchor='Top,Bottom,Left,Right'
$tabPanel=New-Object Windows.Forms.TabPage; $tabPanel.Text='Panel'
$tabChat=New-Object Windows.Forms.TabPage; $tabChat.Text='Chat'
$tabPlayers=New-Object Windows.Forms.TabPage; $tabPlayers.Text='Jugadores'
$tabBackups=New-Object Windows.Forms.TabPage; $tabBackups.Text='Backups'
$tabAutomation=New-Object Windows.Forms.TabPage; $tabAutomation.Text='Automatizaciones'
[void]$tabs.TabPages.Add($tabPanel); [void]$tabs.TabPages.Add($tabChat); [void]$tabs.TabPages.Add($tabPlayers); [void]$tabs.TabPages.Add($tabBackups); [void]$tabs.TabPages.Add($tabAutomation)
foreach($c in $existingControls){$form.Controls.Remove($c);$tabPanel.Controls.Add($c)}; $form.Controls.Add($tabs)
$split=New-Object Windows.Forms.SplitContainer; $split.Dock='Fill'; $split.SplitterDistance=650; $tabChat.Controls.Add($split)
$rtbChat=New-Object Windows.Forms.RichTextBox; $rtbChat.Dock='Fill'; $rtbChat.ReadOnly=$true; $rtbChat.Font=New-Object Drawing.Font('Consolas',10); $split.Panel1.Controls.Add($rtbChat)
$bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Bottom'; $bottom.Height=75; $split.Panel1.Controls.Add($bottom)
$txtChatMessage=New-Object Windows.Forms.TextBox; $txtChatMessage.Location=New-Object Drawing.Point(10,10); $txtChatMessage.Size=New-Object Drawing.Size(500,27); $bottom.Controls.Add($txtChatMessage)
$send=New-Object Windows.Forms.Button; $send.Text='ENVIAR COMO SERVIDOR'; $send.Location=New-Object Drawing.Point(515,8); $send.Size=New-Object Drawing.Size(125,32); $send.Add_Click({Send-ServerChat}); $bottom.Controls.Add($send)
$hist=New-Object Windows.Forms.Button; $hist.Text='ABRIR HISTORIAL'; $hist.Location=New-Object Drawing.Point(10,42); $hist.Size=New-Object Drawing.Size(150,28); $hist.Add_Click({if(-not(Test-Path $ChatHistoryFile)){New-Item -ItemType File -Path $ChatHistoryFile -Force|Out-Null};Start-Process notepad.exe $ChatHistoryFile}); $bottom.Controls.Add($hist)
$txtChatMessage.Add_KeyDown({if($_.KeyCode -eq [Windows.Forms.Keys]::Enter){$_.SuppressKeyPress=$true;Send-ServerChat}})
$rtbServerLog=New-Object Windows.Forms.RichTextBox; $rtbServerLog.Dock='Fill'; $rtbServerLog.ReadOnly=$true; $rtbServerLog.Font=New-Object Drawing.Font('Consolas',9); $rtbServerLog.BackColor=[Drawing.Color]::Black; $rtbServerLog.ForeColor=[Drawing.Color]::Gainsboro; $split.Panel2.Controls.Add($rtbServerLog)
$lblPlayersStatus=New-Object Windows.Forms.Label; $lblPlayersStatus.Text='Esperando consulta...'; $lblPlayersStatus.Location=New-Object Drawing.Point(15,15); $lblPlayersStatus.AutoSize=$true; $tabPlayers.Controls.Add($lblPlayersStatus)
$pr=New-Object Windows.Forms.Button; $pr.Text='ACTUALIZAR JUGADORES'; $pr.Location=New-Object Drawing.Point(820,10); $pr.Size=New-Object Drawing.Size(200,35); $pr.Add_Click({Start-PlayersJob}); $tabPlayers.Controls.Add($pr)
$listPlayers=New-Object Windows.Forms.ListView; $listPlayers.Location=New-Object Drawing.Point(15,60); $listPlayers.Size=New-Object Drawing.Size(1010,700); $listPlayers.View='Details'; $listPlayers.FullRowSelect=$true; $listPlayers.GridLines=$true; [void]$listPlayers.Columns.Add('Jugador',220); [void]$listPlayers.Columns.Add('Nivel',80); [void]$listPlayers.Columns.Add('Ping',80); [void]$listPlayers.Columns.Add('Cuenta',220); [void]$listPlayers.Columns.Add('User ID',360); $tabPlayers.Controls.Add($listPlayers)
$btnCopyUid=New-Object Windows.Forms.Button; $btnCopyUid.Text='COPIAR USER ID'; $btnCopyUid.Location=New-Object Drawing.Point(15,770); $btnCopyUid.Size=New-Object Drawing.Size(160,35); $btnCopyUid.Add_Click({Copy-SelectedPlayerUid}); $tabPlayers.Controls.Add($btnCopyUid)
$btnKickPlayer=New-Object Windows.Forms.Button; $btnKickPlayer.Text='EXPULSAR'; $btnKickPlayer.Location=New-Object Drawing.Point(190,770); $btnKickPlayer.Size=New-Object Drawing.Size(140,35); $btnKickPlayer.Add_Click({Kick-SelectedPlayer}); $tabPlayers.Controls.Add($btnKickPlayer)
$btnBanPlayer=New-Object Windows.Forms.Button; $btnBanPlayer.Text='BANEAR'; $btnBanPlayer.Location=New-Object Drawing.Point(345,770); $btnBanPlayer.Size=New-Object Drawing.Size(140,35); $btnBanPlayer.Add_Click({Ban-SelectedPlayer}); $tabPlayers.Controls.Add($btnBanPlayer)

$nb=New-Object Windows.Forms.Button; $nb.Text='CREAR BACKUP AHORA'; $nb.Location=New-Object Drawing.Point(15,15); $nb.Size=New-Object Drawing.Size(200,36); $nb.Add_Click({try{$b=Backup-World;Refresh-BackupsList;if($b){Show-Message "Backup creado:`n$b"}}catch{Show-Message $_.Exception.Message 'Backup' 'Error'}}); $tabBackups.Controls.Add($nb)
$ob=New-Object Windows.Forms.Button; $ob.Text='ABRIR CARPETA'; $ob.Location=New-Object Drawing.Point(230,15); $ob.Size=New-Object Drawing.Size(160,36); $ob.Add_Click({Start-Process explorer.exe $BackupDir}); $tabBackups.Controls.Add($ob)
$listBackups=New-Object Windows.Forms.ListView; $listBackups.Location=New-Object Drawing.Point(15,65); $listBackups.Size=New-Object Drawing.Size(1010,695); $listBackups.View='Details'; $listBackups.FullRowSelect=$true; $listBackups.GridLines=$true; [void]$listBackups.Columns.Add('Archivo',570); [void]$listBackups.Columns.Add('Fecha',230); [void]$listBackups.Columns.Add('Tamaño',150); $tabBackups.Controls.Add($listBackups)
$btnRestoreBackup=New-Object Windows.Forms.Button; $btnRestoreBackup.Text='RESTAURAR SELECCIONADO'; $btnRestoreBackup.Location=New-Object Drawing.Point(580,15); $btnRestoreBackup.Size=New-Object Drawing.Size(210,36); $btnRestoreBackup.Add_Click({Restore-SelectedBackup}); $tabBackups.Controls.Add($btnRestoreBackup)
$btnDeleteBackup=New-Object Windows.Forms.Button; $btnDeleteBackup.Text='ELIMINAR SELECCIONADO'; $btnDeleteBackup.Location=New-Object Drawing.Point(805,15); $btnDeleteBackup.Size=New-Object Drawing.Size(200,36); $btnDeleteBackup.Add_Click({Delete-SelectedBackup}); $tabBackups.Controls.Add($btnDeleteBackup)


# Automatizaciones
$autoGroup=New-Object Windows.Forms.GroupBox; $autoGroup.Text='Mensajes automáticos'; $autoGroup.Location=New-Object Drawing.Point(15,15); $autoGroup.Size=New-Object Drawing.Size(1015,230); $tabAutomation.Controls.Add($autoGroup)
$chkAutoMessages=New-Object Windows.Forms.CheckBox; $chkAutoMessages.Text='Activar mensajes automáticos'; $chkAutoMessages.Location=New-Object Drawing.Point(20,30); $chkAutoMessages.AutoSize=$true; $autoGroup.Controls.Add($chkAutoMessages)
$lblInterval=New-Object Windows.Forms.Label; $lblInterval.Text='Cada'; $lblInterval.Location=New-Object Drawing.Point(260,32); $lblInterval.AutoSize=$true; $autoGroup.Controls.Add($lblInterval)
$numMessageInterval=New-Object Windows.Forms.NumericUpDown; $numMessageInterval.Location=New-Object Drawing.Point(305,28); $numMessageInterval.Minimum=1; $numMessageInterval.Maximum=1440; $numMessageInterval.Value=30; $autoGroup.Controls.Add($numMessageInterval)
$lblMinutes=New-Object Windows.Forms.Label; $lblMinutes.Text='minutos'; $lblMinutes.Location=New-Object Drawing.Point(430,32); $lblMinutes.AutoSize=$true; $autoGroup.Controls.Add($lblMinutes)
$chkIncludeTips=New-Object Windows.Forms.CheckBox; $chkIncludeTips.Text='Consejos de Palworld'; $chkIncludeTips.Location=New-Object Drawing.Point(20,70); $chkIncludeTips.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeTips)
$chkIncludeCustom=New-Object Windows.Forms.CheckBox; $chkIncludeCustom.Text='Mensajes personalizados'; $chkIncludeCustom.Location=New-Object Drawing.Point(220,70); $chkIncludeCustom.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeCustom)
$chkIncludeTime=New-Object Windows.Forms.CheckBox; $chkIncludeTime.Text='Agregar hora actual'; $chkIncludeTime.Location=New-Object Drawing.Point(440,70); $chkIncludeTime.AutoSize=$true; $autoGroup.Controls.Add($chkIncludeTime)
$lblPrefix=New-Object Windows.Forms.Label; $lblPrefix.Text='Prefijo'; $lblPrefix.Location=New-Object Drawing.Point(20,110); $lblPrefix.AutoSize=$true; $autoGroup.Controls.Add($lblPrefix)
$txtMessagePrefix=New-Object Windows.Forms.TextBox; $txtMessagePrefix.Location=New-Object Drawing.Point(90,106); $txtMessagePrefix.Size=New-Object Drawing.Size(180,25); $autoGroup.Controls.Add($txtMessagePrefix)
$btnTestAuto=New-Object Windows.Forms.Button; $btnTestAuto.Text='ENVIAR PRUEBA'; $btnTestAuto.Location=New-Object Drawing.Point(300,102); $btnTestAuto.Size=New-Object Drawing.Size(150,34); $btnTestAuto.Add_Click({Send-AutomaticMessage -ManualTest $true}); $autoGroup.Controls.Add($btnTestAuto)
$btnEditTips=New-Object Windows.Forms.Button; $btnEditTips.Text='EDITAR CONSEJOS'; $btnEditTips.Location=New-Object Drawing.Point(465,102); $btnEditTips.Size=New-Object Drawing.Size(160,34); $btnEditTips.Add_Click({Ensure-AutomationFiles;Start-Process notepad.exe $TipsFile}); $autoGroup.Controls.Add($btnEditTips)
$btnEditCustom=New-Object Windows.Forms.Button; $btnEditCustom.Text='EDITAR PERSONALIZADOS'; $btnEditCustom.Location=New-Object Drawing.Point(640,102); $btnEditCustom.Size=New-Object Drawing.Size(200,34); $btnEditCustom.Add_Click({Ensure-AutomationFiles;Start-Process notepad.exe $CustomMessagesFile}); $autoGroup.Controls.Add($btnEditCustom)
$lblAutomationStatus=New-Object Windows.Forms.Label; $lblAutomationStatus.Text='Automatizaciones listas.'; $lblAutomationStatus.Location=New-Object Drawing.Point(20,165); $lblAutomationStatus.Size=New-Object Drawing.Size(950,45); $autoGroup.Controls.Add($lblAutomationStatus)

$geminiGroup=New-Object Windows.Forms.GroupBox; $geminiGroup.Text='Generación opcional de consejos con Gemini'; $geminiGroup.Location=New-Object Drawing.Point(15,260); $geminiGroup.Size=New-Object Drawing.Size(1015,140); $tabAutomation.Controls.Add($geminiGroup)
$lblGeminiKey=New-Object Windows.Forms.Label; $lblGeminiKey.Text='API key'; $lblGeminiKey.Location=New-Object Drawing.Point(20,35); $lblGeminiKey.AutoSize=$true; $geminiGroup.Controls.Add($lblGeminiKey)
$txtGeminiKey=New-Object Windows.Forms.TextBox; $txtGeminiKey.Location=New-Object Drawing.Point(90,31); $txtGeminiKey.Size=New-Object Drawing.Size(420,25); $txtGeminiKey.UseSystemPasswordChar=$true; $geminiGroup.Controls.Add($txtGeminiKey)
$lblGeminiModel=New-Object Windows.Forms.Label; $lblGeminiModel.Text='Modelo'; $lblGeminiModel.Location=New-Object Drawing.Point(535,35); $lblGeminiModel.AutoSize=$true; $geminiGroup.Controls.Add($lblGeminiModel)
$txtGeminiModel=New-Object Windows.Forms.TextBox; $txtGeminiModel.Location=New-Object Drawing.Point(600,31); $txtGeminiModel.Size=New-Object Drawing.Size(210,25); $geminiGroup.Controls.Add($txtGeminiModel)
$btnGenerateTips=New-Object Windows.Forms.Button; $btnGenerateTips.Text='GENERAR 40 CONSEJOS'; $btnGenerateTips.Location=New-Object Drawing.Point(825,27); $btnGenerateTips.Size=New-Object Drawing.Size(170,34); $btnGenerateTips.Add_Click({Generate-GeminiTips}); $geminiGroup.Controls.Add($btnGenerateTips)
$lblGeminiNote=New-Object Windows.Forms.Label; $lblGeminiNote.Text='La clave se protege con Windows para el usuario actual. La IA solo se usa al presionar Generar.'; $lblGeminiNote.Location=New-Object Drawing.Point(20,85); $lblGeminiNote.Size=New-Object Drawing.Size(950,30); $geminiGroup.Controls.Add($lblGeminiNote)

$smartGroup=New-Object Windows.Forms.GroupBox; $smartGroup.Text='Reinicios inteligentes y backups'; $smartGroup.Location=New-Object Drawing.Point(15,415); $smartGroup.Size=New-Object Drawing.Size(1015,160); $tabAutomation.Controls.Add($smartGroup)
$chkRestartOnlyEmpty=New-Object Windows.Forms.CheckBox; $chkRestartOnlyEmpty.Text='Reiniciar automáticamente solo cuando no haya jugadores'; $chkRestartOnlyEmpty.Location=New-Object Drawing.Point(20,32); $chkRestartOnlyEmpty.AutoSize=$true; $smartGroup.Controls.Add($chkRestartOnlyEmpty)
$chkRestartLowFps=New-Object Windows.Forms.CheckBox; $chkRestartLowFps.Text='Reiniciar por FPS bajos'; $chkRestartLowFps.Location=New-Object Drawing.Point(20,70); $chkRestartLowFps.AutoSize=$true; $smartGroup.Controls.Add($chkRestartLowFps)
$lblLowFps=New-Object Windows.Forms.Label; $lblLowFps.Text='Menos de'; $lblLowFps.Location=New-Object Drawing.Point(230,73); $lblLowFps.AutoSize=$true; $smartGroup.Controls.Add($lblLowFps)
$numLowFps=New-Object Windows.Forms.NumericUpDown; $numLowFps.Location=New-Object Drawing.Point(300,69); $numLowFps.Minimum=5; $numLowFps.Maximum=60; $numLowFps.Value=25; $smartGroup.Controls.Add($numLowFps)
$lblDuring=New-Object Windows.Forms.Label; $lblDuring.Text='FPS durante'; $lblDuring.Location=New-Object Drawing.Point(430,73); $lblDuring.AutoSize=$true; $smartGroup.Controls.Add($lblDuring)
$numLowFpsMinutes=New-Object Windows.Forms.NumericUpDown; $numLowFpsMinutes.Location=New-Object Drawing.Point(520,69); $numLowFpsMinutes.Minimum=1; $numLowFpsMinutes.Maximum=120; $numLowFpsMinutes.Value=10; $smartGroup.Controls.Add($numLowFpsMinutes)
$lblLowMinutes=New-Object Windows.Forms.Label; $lblLowMinutes.Text='minutos'; $lblLowMinutes.Location=New-Object Drawing.Point(650,73); $lblLowMinutes.AutoSize=$true; $smartGroup.Controls.Add($lblLowMinutes)
$lblRetention=New-Object Windows.Forms.Label; $lblRetention.Text='Conservar últimos'; $lblRetention.Location=New-Object Drawing.Point(20,112); $lblRetention.AutoSize=$true; $smartGroup.Controls.Add($lblRetention)
$numBackupRetention=New-Object Windows.Forms.NumericUpDown; $numBackupRetention.Location=New-Object Drawing.Point(140,108); $numBackupRetention.Minimum=1; $numBackupRetention.Maximum=500; $numBackupRetention.Value=20; $smartGroup.Controls.Add($numBackupRetention)
$lblRetentionSuffix=New-Object Windows.Forms.Label; $lblRetentionSuffix.Text='backups'; $lblRetentionSuffix.Location=New-Object Drawing.Point(270,112); $lblRetentionSuffix.AutoSize=$true; $smartGroup.Controls.Add($lblRetentionSuffix)
$chkJoinLeave=New-Object Windows.Forms.CheckBox; $chkJoinLeave.Text='Registrar entradas y salidas en actividad'; $chkJoinLeave.Location=New-Object Drawing.Point(390,110); $chkJoinLeave.AutoSize=$true; $smartGroup.Controls.Add($chkJoinLeave)
$btnSaveAutomation=New-Object Windows.Forms.Button; $btnSaveAutomation.Text='GUARDAR AUTOMATIZACIONES'; $btnSaveAutomation.Location=New-Object Drawing.Point(760,103); $btnSaveAutomation.Size=New-Object Drawing.Size(235,38); $btnSaveAutomation.Add_Click({Save-AutomationSettings}); $smartGroup.Controls.Add($btnSaveAutomation)

$activityGroup=New-Object Windows.Forms.GroupBox; $activityGroup.Text='Registro de actividad'; $activityGroup.Location=New-Object Drawing.Point(15,590); $activityGroup.Size=New-Object Drawing.Size(1015,210); $tabAutomation.Controls.Add($activityGroup)
$rtbActivity=New-Object Windows.Forms.RichTextBox; $rtbActivity.Location=New-Object Drawing.Point(15,28); $rtbActivity.Size=New-Object Drawing.Size(980,140); $rtbActivity.ReadOnly=$true; $rtbActivity.Font=New-Object Drawing.Font('Consolas',9); $activityGroup.Controls.Add($rtbActivity)
$btnOpenActivity=New-Object Windows.Forms.Button; $btnOpenActivity.Text='ABRIR REGISTRO'; $btnOpenActivity.Location=New-Object Drawing.Point(15,172); $btnOpenActivity.Size=New-Object Drawing.Size(160,30); $btnOpenActivity.Add_Click({if(-not(Test-Path $ActivityLogFile)){New-Item -ItemType File -Path $ActivityLogFile -Force|Out-Null};Start-Process notepad.exe $ActivityLogFile}); $activityGroup.Controls.Add($btnOpenActivity)

$tabs.Add_SelectedIndexChanged({if($tabs.SelectedTab -eq $tabPlayers){Start-PlayersJob}elseif($tabs.SelectedTab -eq $tabBackups){Refresh-BackupsList}})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $lblClock.Text = "Hora: " + (Get-Date -Format "HH:mm:ss")
        Update-AutomaticMessages
        Update-SmartRestart
        Update-Status
        Update-RestartSchedule
    }
    catch {
        $lblAction.Text = "Error de actualización: " + $_.Exception.Message
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
        $lblAction.Text = "Error al consultar métricas: " + $_.Exception.Message
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
