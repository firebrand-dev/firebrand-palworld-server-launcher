# ============================================================
# I18n.ps1 - Motor de idiomas del Firebrand Palworld Server Launcher
#
# Dos idiomas independientes:
#   - Idioma de la UI (T):  lo que ve el ADMIN en el launcher.
#   - Idioma del server (TS): los mensajes in-game que ven los JUGADORES
#     (avisos de reinicio, kick, mantenimiento). Un admin puede usar la UI
#     en espanol con jugadores anglo, o al reves.
#
# Formato de locales: locales\<codigo>.json plano (clave -> texto), UTF-8
# con BOM. locales\es.json es la FUENTE DE VERDAD: toda clave nueva nace
# ahi y validate.ps1 exige paridad de claves en el resto de los idiomas.
#
# Fallback: idioma pedido -> es -> la clave misma (visible, para detectar
# strings sin traducir en vez de romperse).
#
# Sin UI y sin estado externo salvo $script: -- testeable headless.
# Compatible con Windows PowerShell 5.1.
# ============================================================

$script:I18nUIStrings = @{}
$script:I18nServerStrings = @{}
$script:I18nFallbackStrings = @{}
$script:I18nUILanguage = "es"
$script:I18nServerLanguage = "es"

function Import-LocaleFile {
    param([Parameter(Mandatory=$true)][string]$Path)

    $table = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $table
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $json.PSObject.Properties) {
            $table[$property.Name] = [string]$property.Value
        }
    }
    catch {}

    return $table
}

# Codigos de idioma disponibles segun los .json presentes en locales\.
function Get-AvailableLocales {
    param([Parameter(Mandatory=$true)][string]$LocalesDir)

    $codes = @()
    if (Test-Path -LiteralPath $LocalesDir) {
        $codes = @(
            Get-ChildItem -LiteralPath $LocalesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } |
                Sort-Object
        )
    }
    return $codes
}

# Nombre para mostrar de cada idioma (en su propio idioma, estandar de la industria).
function Get-LocaleDisplayName {
    param([Parameter(Mandatory=$true)][string]$Code)

    switch ($Code) {
        "es" { return "Español" }
        "en" { return "English" }
        "pt" { return "Português" }
        "de" { return "Deutsch" }
        "ja" { return "日本語" }
        "fr" { return "Français" }
        "it" { return "Italiano" }
    }
    return $Code
}

function Initialize-I18n {
    param(
        [Parameter(Mandatory=$true)][string]$LocalesDir,
        [string]$UILanguage = "es",
        [string]$ServerLanguage = ""
    )

    if ([string]::IsNullOrWhiteSpace($ServerLanguage)) {
        $ServerLanguage = $UILanguage
    }

    $script:I18nUILanguage = $UILanguage
    $script:I18nServerLanguage = $ServerLanguage

    $script:I18nFallbackStrings = Import-LocaleFile -Path (Join-Path $LocalesDir "es.json")

    if ($UILanguage -eq "es") {
        $script:I18nUIStrings = $script:I18nFallbackStrings
    }
    else {
        $script:I18nUIStrings = Import-LocaleFile -Path (Join-Path $LocalesDir "$UILanguage.json")
    }

    if ($ServerLanguage -eq "es") {
        $script:I18nServerStrings = $script:I18nFallbackStrings
    }
    else {
        $script:I18nServerStrings = Import-LocaleFile -Path (Join-Path $LocalesDir "$ServerLanguage.json")
    }
}

function Get-I18nString {
    param(
        [hashtable]$Primary,
        [string]$Key,
        [object[]]$Fmt
    )

    $text = $null
    if ($Primary -and $Primary.ContainsKey($Key)) {
        $text = $Primary[$Key]
    }
    elseif ($script:I18nFallbackStrings -and $script:I18nFallbackStrings.ContainsKey($Key)) {
        $text = $script:I18nFallbackStrings[$Key]
    }
    else {
        # Clave visible: mejor un "panel.start" en pantalla que una excepcion.
        return $Key
    }

    if ($null -ne $Fmt -and $Fmt.Count -gt 0) {
        try {
            return ($text -f $Fmt)
        }
        catch {
            return $text
        }
    }

    return $text
}

# Texto de UI en el idioma del launcher.
function T {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [object[]]$Fmt = $null
    )
    return Get-I18nString -Primary $script:I18nUIStrings -Key $Key -Fmt $Fmt
}

# Texto in-game en el idioma configurado para los JUGADORES del server.
function TS {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [object[]]$Fmt = $null
    )
    return Get-I18nString -Primary $script:I18nServerStrings -Key $Key -Fmt $Fmt
}

# Idiomas iniciales ANTES de que exista la UI. Cadena de resolucion:
# settings de DataRoot -> settings viejos junto al launcher (pre-migracion)
# -> idioma de Windows si hay locale -> "en".
function Get-InitialLanguages {
    param(
        [Parameter(Mandatory=$true)][string]$DataRoot,
        [Parameter(Mandatory=$true)][string]$InstallRoot,
        [Parameter(Mandatory=$true)][string]$LocalesDir,
        [string]$OsLanguage = ""
    )

    if ([string]::IsNullOrWhiteSpace($OsLanguage)) {
        try { $OsLanguage = (Get-Culture).TwoLetterISOLanguageName } catch { $OsLanguage = "en" }
    }

    $available = @(Get-AvailableLocales -LocalesDir $LocalesDir)
    $ui = $null
    $server = $null

    foreach ($settingsPath in @((Join-Path $DataRoot "launcher-settings.json"), (Join-Path $InstallRoot "launcher-settings.json"))) {
        if ($ui) { break }
        if (Test-Path -LiteralPath $settingsPath) {
            try {
                $config = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($config.Language -and ($available -contains [string]$config.Language)) {
                    $ui = [string]$config.Language
                }
                if ($config.ServerMessageLanguage -and ($available -contains [string]$config.ServerMessageLanguage)) {
                    $server = [string]$config.ServerMessageLanguage
                }
            }
            catch {}
        }
    }

    if (-not $ui) {
        if ($available -contains $OsLanguage) { $ui = $OsLanguage }
        elseif ($available -contains "en") { $ui = "en" }
        elseif ($available.Count -gt 0) { $ui = $available[0] }
        else { $ui = "es" }
    }

    if (-not $server) { $server = $ui }

    return @{ UI = $ui; Server = $server }
}
