# ============================================================
# test_processes.ps1 - Verifica que el launcher NO toca procesos
# PalServer ajenos (de otra carpeta/instalacion).
#
# Extrae las funciones REALES (Test-OwnServerProcess, Get-ServerProcess)
# del monolito via AST -- se testea el codigo que corre en produccion,
# no una copia. Lanza procesos señuelo (cmd.exe renombrado a PalServer.exe)
# desde una carpeta "ajena" y una "propia" y verifica el filtrado por ruta.
#
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_processes.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$launcherFile = Join-Path $root "launcher\FirebrandPalworldLauncher.ps1"

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

# --- Extraer las funciones reales del monolito ---
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherFile, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "El launcher no parsea; corre tools\validate.ps1 primero." }

$wanted = @("Test-OwnServerProcess", "Get-ServerProcess")
$found = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $wanted -contains $node.Name
}, $true)

Assert "AST: se encontraron las 2 funciones en el launcher" ($found.Count -eq 2)

foreach ($functionAst in $found) {
    Invoke-Expression $functionAst.Extent.Text
}

# --- Sandbox con proceso "propio" y proceso "ajeno" ---
$tmp = Join-Path $env:TEMP ("fbpl_proc_" + [guid]::NewGuid().ToString("N"))
$ownServerDir = Join-Path $tmp "propia\server"
$foreignDir = Join-Path $tmp "ajena\server"
New-Item -ItemType Directory -Path $ownServerDir, $foreignDir -Force | Out-Null

$cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
Copy-Item $cmdExe (Join-Path $ownServerDir "PalServer.exe")
Copy-Item $cmdExe (Join-Path $foreignDir "PalServer.exe")

$ownProc = $null
$foreignProc = $null

try {
    $foreignProc = Start-Process -FilePath (Join-Path $foreignDir "PalServer.exe") `
        -ArgumentList "/c", "ping -n 60 127.0.0.1 > nul" -PassThru -WindowStyle Hidden
    $ownProc = Start-Process -FilePath (Join-Path $ownServerDir "PalServer.exe") `
        -ArgumentList "/c", "ping -n 60 127.0.0.1 > nul" -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800

    # Contexto que las funciones reales esperan del monolito:
    $ServerDir = $ownServerDir
    $script:ServerPid = $null

    # 1) Test-OwnServerProcess distingue propio de ajeno
    Assert "filtro: el proceso propio ES reconocido" (Test-OwnServerProcess (Get-Process -Id $ownProc.Id))
    Assert "filtro: el proceso ajeno NO es reconocido" (-not (Test-OwnServerProcess (Get-Process -Id $foreignProc.Id)))
    Assert "filtro: null no es propio" (-not (Test-OwnServerProcess $null))

    # 2) Get-ServerProcess devuelve SOLO el propio
    $detected = Get-ServerProcess
    Assert "deteccion: encuentra el proceso propio" ($detected -and $detected.Id -eq $ownProc.Id)
    Assert "deteccion: cachea el PID propio" ($script:ServerPid -eq $ownProc.Id)

    # 3) Con SOLO el ajeno corriendo, no detecta nada (antes v9 lo agarraba por nombre)
    Stop-Process -Id $ownProc.Id -Force
    Start-Sleep -Milliseconds 500
    $script:ServerPid = $null
    $detectedForeign = Get-ServerProcess
    Assert "deteccion: con solo un PalServer ajeno vivo, devuelve null" ($null -eq $detectedForeign)

    # 4) La barrida de Stop-Server (mismo filtro) no mata al ajeno
    Get-Process -Name "PalServer", "PalServer-Win64-Test", "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue |
        Where-Object { Test-OwnServerProcess $_ } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $foreignAlive = Get-Process -Id $foreignProc.Id -ErrorAction SilentlyContinue
    Assert "barrida: el PalServer ajeno sigue vivo despues del filtro de Stop-Server" ($null -ne $foreignAlive)

    # 5) El PID cacheado no engancha un proceso equivocado
    $script:ServerPid = $foreignProc.Id
    $detectedByPid = Get-ServerProcess
    Assert "pid cacheado: un PID ajeno cacheado NO se devuelve como propio" ($null -eq $detectedByPid)
}
finally {
    foreach ($p in @($ownProc, $foreignProc)) {
        if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 300
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
