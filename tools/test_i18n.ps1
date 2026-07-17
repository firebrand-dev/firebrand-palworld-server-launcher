# ============================================================
# test_i18n.ps1 - Tests headless del motor de idiomas (lib\I18n.ps1)
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_i18n.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "launcher\lib\I18n.ps1")

$script:passed = 0
$script:failed = 0

function Assert([string]$Name, $Condition) {
    if ($Condition) { $script:passed++; Write-Host "[OK] $Name" }
    else { $script:failed++; Write-Host "[X]  $Name" -ForegroundColor Red }
}

$realLocales = Join-Path $root "locales"

# ---------- Con los locales reales del producto ----------
Initialize-I18n -LocalesDir $realLocales -UILanguage "es"
Assert "es: clave de boton" ((T "panel.btn_start") -eq "INICIAR")
Assert "es: formateo {0}" ((T "panel.status_online" @(1234)) -like "*1234*")
Assert "clave inexistente devuelve la clave" ((T "no.existe.esta.clave") -eq "no.existe.esta.clave")
Assert "TS por defecto = idioma UI" ((TS "game.restart_now").Length -gt 0)

# ---------- Sandbox: fallback y idiomas separados ----------
$tmp = Join-Path $env:TEMP ("fbpl_i18n_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
'{"a.uno":"UNO es","a.dos":"DOS es"}' | Set-Content -Path (Join-Path $tmp "es.json") -Encoding UTF8
'{"a.uno":"ONE en"}' | Set-Content -Path (Join-Path $tmp "en.json") -Encoding UTF8

Initialize-I18n -LocalesDir $tmp -UILanguage "en" -ServerLanguage "es"
Assert "en: clave traducida" ((T "a.uno") -eq "ONE en")
Assert "en: clave faltante cae a es" ((T "a.dos") -eq "DOS es")
Assert "TS usa idioma del server (es) aunque la UI este en en" ((TS "a.uno") -eq "UNO es")

$locales = @(Get-AvailableLocales -LocalesDir $tmp)
Assert "lista de locales disponibles" (($locales.Count -eq 2) -and ($locales -contains "es") -and ($locales -contains "en"))
Assert "Import de archivo inexistente = tabla vacia" ((Import-LocaleFile -Path (Join-Path $tmp "xx.json")).Count -eq 0)

# ---------- Get-InitialLanguages ----------
$dataRoot = Join-Path $tmp "data"
$installRoot = Join-Path $tmp "install"
New-Item -ItemType Directory -Path $dataRoot, $installRoot -Force | Out-Null

$langs = Get-InitialLanguages -DataRoot $dataRoot -InstallRoot $installRoot -LocalesDir $tmp -OsLanguage "es"
Assert "sin settings: usa idioma del SO si existe locale" ($langs.UI -eq "es")

$langs2 = Get-InitialLanguages -DataRoot $dataRoot -InstallRoot $installRoot -LocalesDir $tmp -OsLanguage "de"
Assert "sin settings ni locale del SO: cae a en" ($langs2.UI -eq "en")

'{"Language":"en","ServerMessageLanguage":"es"}' | Set-Content -Path (Join-Path $dataRoot "launcher-settings.json") -Encoding UTF8
$langs3 = Get-InitialLanguages -DataRoot $dataRoot -InstallRoot $installRoot -LocalesDir $tmp -OsLanguage "es"
Assert "settings de DataRoot: UI persistida" ($langs3.UI -eq "en")
Assert "settings de DataRoot: idioma de server separado" ($langs3.Server -eq "es")

Remove-Item (Join-Path $dataRoot "launcher-settings.json") -Force
'{"Language":"en"}' | Set-Content -Path (Join-Path $installRoot "launcher-settings.json") -Encoding UTF8
$langs4 = Get-InitialLanguages -DataRoot $dataRoot -InstallRoot $installRoot -LocalesDir $tmp -OsLanguage "es"
Assert "settings viejos junto al launcher (pre-migracion) tambien valen" ($langs4.UI -eq "en")
Assert "sin idioma de server persistido: sigue al de la UI" ($langs4.Server -eq "en")

# ---------- Nombres para mostrar ----------
Assert "display: es" ((Get-LocaleDisplayName "es") -eq "Español")
Assert "display: ja" ((Get-LocaleDisplayName "ja") -eq "日本語")
Assert "display: desconocido devuelve el codigo" ((Get-LocaleDisplayName "xx") -eq "xx")

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
