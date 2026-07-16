# ============================================================
# validate.ps1 - Validacion estatica del launcher (correr tras CADA cambio)
# Parsea todos los .ps1 del proyecto con el motor local (PowerShell 5.1 en
# el server objetivo) y falla si hay errores de sintaxis.
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\validate.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$files = @(
    (Join-Path $root "launcher\PalworldLauncher.ps1"),
    (Join-Path $root "launcher\lib\Paths.ps1"),
    (Join-Path $root "scripts\Install-PalworldServer.ps1"),
    (Join-Path $root "tools\test_paths.ps1")
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

if ($failed) {
    Write-Host "VALIDACION: FALLO" -ForegroundColor Red
    exit 1
}

Write-Host "VALIDACION: OK"
exit 0
