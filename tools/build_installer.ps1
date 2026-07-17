# ============================================================
# build_installer.ps1 - Build completo del producto instalable
#
# 1. Genera el icono si falta (tools\make_icon.ps1)
# 2. Estampa build\version.json (fecha + commit git si hay repo)
# 3. Compila el stub .exe con el csc.exe de .NET Framework INCLUIDO
#    en Windows (sin SDK): icono + recursos de version + manifest
# 4. Compila el instalador con Inno Setup 6 (ISCC.exe)
#
# Salida: dist\FirebrandPalworldLauncherSetup-<version>.exe
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_installer.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $root "build"
$distDir = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $buildDir, $distDir | Out-Null

# ---- 1. Icono ----
$icon = Join-Path $root "assets\icon.ico"
if (-not (Test-Path -LiteralPath $icon)) {
    Write-Host "Generando icono..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\make_icon.ps1")
    if ($LASTEXITCODE -ne 0) { throw "make_icon.ps1 fallo" }
}

# ---- 2. version.json estampado ----
$versionInfo = Get-Content -LiteralPath (Join-Path $root "version.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$versionInfo.version
$versionInfo.build_date = (Get-Date -Format "yyyy-MM-dd")
$gitCommit = ""
try {
    $gitCommit = (& git -C $root rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $gitCommit = "" }
}
catch { $gitCommit = "" }
$versionInfo.git_commit = [string]$gitCommit
$versionInfo | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildDir "version.json") -Encoding UTF8
Write-Host ("Version: {0}  (commit {1})" -f $version, $(if ($gitCommit) { $gitCommit } else { "n/a" }))

# ---- 3. Stub .exe ----
$csc = Join-Path $env:windir "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:windir "Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $csc)) { throw "No se encontro csc.exe de .NET Framework" }

# La version de ensamblado necesita 4 numeros
$assemblyVersion = $version
if (($assemblyVersion -split '\.').Count -eq 3) { $assemblyVersion = "$assemblyVersion.0" }

$assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("Firebrand Palworld Server Launcher")]
[assembly: AssemblyDescription("Install, update and manage a Palworld dedicated server without touching SteamCMD.")]
[assembly: AssemblyCompany("Firebrand Software")]
[assembly: AssemblyProduct("Firebrand Palworld Server Launcher")]
[assembly: AssemblyCopyright("(c) Firebrand Software - MIT License")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
"@
$assemblyInfoPath = Join-Path $buildDir "AssemblyInfo.cs"
Set-Content -LiteralPath $assemblyInfoPath -Value $assemblyInfo -Encoding UTF8

$stubExe = Join-Path $buildDir "FirebrandPalworldLauncher.exe"
Write-Host "Compilando stub con csc..."
& $csc /nologo /target:winexe `
    /out:"$stubExe" `
    /win32icon:"$icon" `
    /win32manifest:"$(Join-Path $root 'launcher\stub\app.manifest')" `
    /reference:System.Windows.Forms.dll `
    "$(Join-Path $root 'launcher\stub\Launcher.cs')" `
    "$assemblyInfoPath"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stubExe)) { throw "csc fallo (codigo $LASTEXITCODE)" }
Write-Host ("Stub: {0} ({1:N0} bytes)" -f $stubExe, (Get-Item $stubExe).Length)

# ---- 4. Instalador ----
$iscc = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 no esta instalado (ISCC.exe no encontrado)" }

Write-Host "Compilando instalador con Inno Setup..."
& $iscc /Qp "/DMyAppVersion=$version" (Join-Path $root "installer\FirebrandPalworldLauncher.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC fallo (codigo $LASTEXITCODE)" }

$setup = Join-Path $distDir "FirebrandPalworldLauncherSetup-$version.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "No aparecio el instalador esperado: $setup" }
Write-Host ("LISTO: {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB))
exit 0
