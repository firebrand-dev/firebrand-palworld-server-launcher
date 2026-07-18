# ============================================================
# test_updater.ps1 - Tests headless del updater (lib\Updater.ps1)
# Funciones puras + una consulta REAL a la API de GitHub (se salta
# con aviso si no hay red).
# Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_updater.ps1
# ============================================================

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "launcher\lib\Updater.ps1")

$script:passed = 0
$script:failed = 0
function Assert([string]$Name, $Condition) {
    if ($Condition) { $script:passed++; Write-Host "[OK] $Name" }
    else { $script:failed++; Write-Host "[X]  $Name" -ForegroundColor Red }
}

# ---------- Compare-ProductVersions ----------
Assert "cmp: iguales" ((Compare-ProductVersions "0.9.0" "0.9.0") -eq 0)
Assert "cmp: menor por patch" ((Compare-ProductVersions "0.9.0" "0.9.1") -eq -1)
Assert "cmp: mayor por minor" ((Compare-ProductVersions "1.2.0" "1.1.9") -eq 1)
Assert "cmp: mayor por major" ((Compare-ProductVersions "2.0.0" "1.99.99") -eq 1)
Assert "cmp: prefijo v ignorado" ((Compare-ProductVersions "v1.0.0" "1.0.0") -eq 0)
Assert "cmp: largos distintos 1.0 == 1.0.0" ((Compare-ProductVersions "1.0" "1.0.0") -eq 0)
Assert "cmp: largos distintos 1.0 < 1.0.1" ((Compare-ProductVersions "1.0" "1.0.1") -eq -1)
Assert "cmp: numeros de dos digitos (0.9.0 < 0.10.0)" ((Compare-ProductVersions "0.9.0" "0.10.0") -eq -1)
Assert "cmp: prerelease menor que la plena" ((Compare-ProductVersions "1.0.0-beta" "1.0.0") -eq -1)
Assert "cmp: plena mayor que prerelease" ((Compare-ProductVersions "1.0.0" "1.0.0-rc1") -eq 1)
Assert "cmp: prerelease vs prerelease igual base" ((Compare-ProductVersions "1.0.0-a" "1.0.0-b") -eq 0)

# ---------- Get-UpdateAssetFromRelease ----------
$releaseMock = [pscustomobject]@{
    tag_name = "v1.2.3"
    assets = @(
        [pscustomobject]@{ name = "Source code.zip"; browser_download_url = "http://x/src.zip" },
        [pscustomobject]@{ name = "FirebrandPalworldLauncherSetup-1.2.3.exe"; browser_download_url = "http://x/setup.exe" }
    )
}
$asset = Get-UpdateAssetFromRelease -Release $releaseMock
Assert "asset: encuentra el Setup correcto" ($asset -and $asset.name -eq "FirebrandPalworldLauncherSetup-1.2.3.exe")

$releaseNoAsset = [pscustomobject]@{ tag_name = "v1.0.0"; assets = @([pscustomobject]@{ name = "otro.zip"; browser_download_url = "http://x/o.zip" }) }
Assert "asset: sin instalador devuelve null" ($null -eq (Get-UpdateAssetFromRelease -Release $releaseNoAsset))

$releaseEmpty = [pscustomobject]@{ tag_name = "v1.0.0"; assets = @() }
Assert "asset: release sin assets devuelve null" ($null -eq (Get-UpdateAssetFromRelease -Release $releaseEmpty))

# ---------- Get-LatestReleaseInfo (vivo, con salto por falta de red) ----------
$live = Get-LatestReleaseInfo -Owner "jrsoftware" -Repo "issrc"
if (-not $live.Ok -and $live.Error -match "conect|connect|resolver|resolve|tiempo|timeout|red|network") {
    Write-Host "[warn] sin red: se saltan los tests vivos de la API" -ForegroundColor Yellow
}
else {
    Assert "vivo: repo con releases responde Ok" $live.Ok
    Assert "vivo: version no vacia" (-not [string]::IsNullOrWhiteSpace($live.Version))

    # Nuestro repo: puede no tener releases todavia -> error manejado, sin excepcion
    $ours = Get-LatestReleaseInfo -Owner "firebrand-dev" -Repo "firebrand-palworld-server-launcher"
    Assert "vivo: nuestro repo no lanza excepcion (Ok o error manejado)" (($ours.Ok) -or (-not [string]::IsNullOrWhiteSpace($ours.Error)))
}

Write-Host ""
Write-Host ("RESULTADO: {0} OK, {1} FALLAS" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
