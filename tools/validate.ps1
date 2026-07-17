# ============================================================
# validate.ps1 - Validacion estatica del launcher (correr tras CADA cambio)
# Parsea todos los .ps1 del proyecto con el motor local (PowerShell 5.1 en
# el server objetivo) y falla si hay errores de sintaxis.
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\validate.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$files = @(
    (Join-Path $root "launcher\FirebrandPalworldLauncher.ps1"),
    (Join-Path $root "launcher\lib\Paths.ps1"),
    (Join-Path $root "launcher\lib\I18n.ps1"),
    (Join-Path $root "scripts\Install-PalworldServer.ps1"),
    (Join-Path $root "tools\test_paths.ps1"),
    (Join-Path $root "tools\test_i18n.ps1"),
    (Join-Path $root "tools\test_processes.ps1"),
    (Join-Path $root "tools\test_smoke_gui.ps1")
)

$failed = $false

foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "[X] NO EXISTE: $file" -ForegroundColor Red
        $failed = $true
        continue
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "[X] $file" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("    Linea {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    }
    else {
        Write-Host "[OK] $file"
    }
}

# ---- Locales: JSON valido, paridad de claves y placeholders vs es.json ----
function Get-PlaceholderSet([string]$Text) {
    return @([regex]::Matches($Text, '\{\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

$localesDir = Join-Path $root "locales"
$esFile = Join-Path $localesDir "es.json"

if (Test-Path -LiteralPath $esFile) {
    try {
        $es = Get-Content -LiteralPath $esFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $esKeys = @($es.PSObject.Properties.Name)
        Write-Host ("[OK] locales\es.json ({0} claves)" -f $esKeys.Count)

        foreach ($localeFile in (Get-ChildItem -LiteralPath $localesDir -Filter "*.json" -File | Where-Object { $_.Name -ne "es.json" })) {
            try {
                $other = Get-Content -LiteralPath $localeFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $otherKeys = @($other.PSObject.Properties.Name)
                $missing = @($esKeys | Where-Object { $otherKeys -notcontains $_ })
                $extra = @($otherKeys | Where-Object { $esKeys -notcontains $_ })

                $badPlaceholders = @()
                foreach ($key in $esKeys) {
                    if ($otherKeys -contains $key) {
                        $expected = @(Get-PlaceholderSet ([string]$es.$key))
                        $actual = @(Get-PlaceholderSet ([string]$other.$key))
                        # Compare-Object de PS 5.1 lanza con arrays vacios: manejar aparte
                        $placeholdersDiffer = $false
                        if ($expected.Count -eq 0 -and $actual.Count -eq 0) {
                            $placeholdersDiffer = $false
                        }
                        elseif ($expected.Count -eq 0 -or $actual.Count -eq 0) {
                            $placeholdersDiffer = $true
                        }
                        elseif (Compare-Object -ReferenceObject $expected -DifferenceObject $actual) {
                            $placeholdersDiffer = $true
                        }
                        if ($placeholdersDiffer) {
                            $badPlaceholders += $key
                        }
                    }
                }

                if ($missing.Count -gt 0 -or $extra.Count -gt 0 -or $badPlaceholders.Count -gt 0) {
                    $failed = $true
                    Write-Host ("[X] locales\{0}: faltan {1}, sobran {2}, placeholders rotos {3}" -f $localeFile.Name, $missing.Count, $extra.Count, $badPlaceholders.Count) -ForegroundColor Red
                    $missing | Select-Object -First 8 | ForEach-Object { Write-Host ("    falta: " + $_) }
                    $extra | Select-Object -First 8 | ForEach-Object { Write-Host ("    sobra: " + $_) }
                    $badPlaceholders | Select-Object -First 8 | ForEach-Object { Write-Host ("    placeholders: " + $_) }
                }
                else {
                    Write-Host ("[OK] locales\" + $localeFile.Name)
                }
            }
            catch {
                $failed = $true
                Write-Host ("[X] locales\{0}: JSON invalido" -f $localeFile.Name) -ForegroundColor Red
            }
        }
    }
    catch {
        $failed = $true
        Write-Host "[X] locales\es.json invalido" -ForegroundColor Red
    }
}

if ($failed) {
    Write-Host "VALIDACION: FALLO" -ForegroundColor Red
    exit 1
}

Write-Host "VALIDACION: OK"
exit 0
