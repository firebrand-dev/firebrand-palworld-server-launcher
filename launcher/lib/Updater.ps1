# ============================================================
# Updater.ps1 - Actualizaciones del launcher
#
# Usuario final: chequeo MANUAL (boton) contra GitHub Releases del
# repo configurado en config\app_links.json; muestra el changelog,
# pide confirmacion, descarga el Setup y lo ejecuta (Inno hace el
# upgrade in-place). Jamas toca mundos/backups/configuracion: viven
# fuera de la carpeta del programa por diseno (Fase 1).
#
# Desarrollador: si la carpeta del launcher es un repo git, aparece
# un boton extra que hace git pull.
#
# Las funciones puras (comparacion de versiones, seleccion de asset)
# son testeables headless (tools\test_updater.ps1).
# Compatible con Windows PowerShell 5.1.
# ============================================================

# Compara dos versiones estilo semver ("0.9.0", "v1.2.10", "1.0.0-beta").
# Devuelve -1 si A < B, 0 si son iguales, 1 si A > B.
# El sufijo de prerelease se ignora para la parte numerica, pero a
# numeros iguales una prerelease cuenta como MENOR que la version plena.
function Compare-ProductVersions {
    param(
        [Parameter(Mandatory=$true)][string]$A,
        [Parameter(Mandatory=$true)][string]$B
    )

    $mainA = ($A.Trim() -replace '^[vV]', '') -replace '[-+].*$', ''
    $mainB = ($B.Trim() -replace '^[vV]', '') -replace '[-+].*$', ''
    $partsA = @($mainA -split '\.')
    $partsB = @($mainB -split '\.')

    for ($i = 0; $i -lt [Math]::Max($partsA.Count, $partsB.Count); $i++) {
        $numA = 0
        $numB = 0
        if ($i -lt $partsA.Count) { [int]::TryParse($partsA[$i], [ref]$numA) | Out-Null }
        if ($i -lt $partsB.Count) { [int]::TryParse($partsB[$i], [ref]$numB) | Out-Null }
        if ($numA -lt $numB) { return -1 }
        if ($numA -gt $numB) { return 1 }
    }

    $preA = $A -match '-'
    $preB = $B -match '-'
    if ($preA -and -not $preB) { return -1 }
    if ($preB -and -not $preA) { return 1 }
    return 0
}

# Elige el asset instalador dentro de un objeto release de la API de GitHub.
function Get-UpdateAssetFromRelease {
    param([Parameter(Mandatory=$true)]$Release)

    foreach ($asset in @($Release.assets)) {
        if ([string]$asset.name -like "FirebrandPalworldLauncherSetup-*.exe") {
            return $asset
        }
    }
    return $null
}

# Consulta el ultimo release publicado. Nunca lanza: devuelve Ok/Error.
function Get-LatestReleaseInfo {
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][string]$Repo
    )

    $result = @{ Ok = $false; Version = ""; TagName = ""; Body = ""; HtmlUrl = ""; AssetName = ""; AssetUrl = ""; Error = "" }

    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" `
            -Headers @{ "User-Agent" = "FirebrandPalworldLauncher"; "Accept" = "application/vnd.github+json" } `
            -TimeoutSec 20 `
            -UseBasicParsing

        $result.Ok = $true
        $result.TagName = [string]$release.tag_name
        $result.Version = ($result.TagName -replace '^[vV]', '')
        $result.Body = [string]$release.body
        $result.HtmlUrl = [string]$release.html_url

        $asset = Get-UpdateAssetFromRelease -Release $release
        if ($asset) {
            $result.AssetName = [string]$asset.name
            $result.AssetUrl = [string]$asset.browser_download_url
        }
    }
    catch {
        # 404 tipico: el repo todavia no publico ningun release
        $result.Error = $_.Exception.Message
    }

    return $result
}

# Dialogo de changelog: devuelve 'install' | 'github' | 'cancel'.
function Show-UpdateChangelogDialog {
    param(
        [string]$NewVersion,
        [string]$CurrentVersion,
        [string]$Changelog
    )

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = T "updater.changelog_title" @($NewVersion)
    $dialog.Size = New-Object Drawing.Size(600, 460)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object Drawing.Font("Segoe UI", 10)

    $headerLabel = New-Object Windows.Forms.Label
    $headerLabel.Text = T "updater.available" @($NewVersion, $CurrentVersion)
    $headerLabel.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $headerLabel.Location = New-Object Drawing.Point(15, 15)
    $headerLabel.Size = New-Object Drawing.Size(555, 40)
    $dialog.Controls.Add($headerLabel)

    $changelogBox = New-Object Windows.Forms.TextBox
    $changelogBox.Multiline = $true
    $changelogBox.ReadOnly = $true
    $changelogBox.ScrollBars = "Vertical"
    $changelogBox.Font = New-Object Drawing.Font("Consolas", 9)
    $changelogBox.Location = New-Object Drawing.Point(15, 60)
    $changelogBox.Size = New-Object Drawing.Size(555, 290)
    $changelogBox.Text = $(if ([string]::IsNullOrWhiteSpace($Changelog)) { T "updater.no_changelog" } else { $Changelog -replace "(?<!`r)`n", "`r`n" })
    $dialog.Controls.Add($changelogBox)

    $script:UpdateDialogChoice = "cancel"

    $installButton = New-Object Windows.Forms.Button
    $installButton.Text = T "updater.btn_install_update"
    $installButton.Location = New-Object Drawing.Point(15, 365)
    $installButton.Size = New-Object Drawing.Size(230, 38)
    $installButton.Add_Click({ $script:UpdateDialogChoice = "install"; $dialog.Close() })
    $dialog.Controls.Add($installButton)

    $githubButton = New-Object Windows.Forms.Button
    $githubButton.Text = T "updater.btn_view_github"
    $githubButton.Location = New-Object Drawing.Point(260, 365)
    $githubButton.Size = New-Object Drawing.Size(170, 38)
    $githubButton.Add_Click({ $script:UpdateDialogChoice = "github"; $dialog.Close() })
    $dialog.Controls.Add($githubButton)

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Text = T "updater.btn_cancel"
    $cancelButton.Location = New-Object Drawing.Point(445, 365)
    $cancelButton.Size = New-Object Drawing.Size(125, 38)
    $cancelButton.Add_Click({ $script:UpdateDialogChoice = "cancel"; $dialog.Close() })
    $dialog.Controls.Add($cancelButton)

    $dialog.AcceptButton = $installButton
    $dialog.CancelButton = $cancelButton
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()

    return $script:UpdateDialogChoice
}

# Flujo completo del boton "Buscar actualizaciones".
function Invoke-LauncherUpdateCheck {
    $lblUpdateStatus.Text = T "updater.checking"
    $form.Refresh()

    $info = Get-LatestReleaseInfo -Owner $AppLinks.github_owner -Repo $AppLinks.github_repo

    if (-not $info.Ok) {
        $lblUpdateStatus.Text = ""
        Show-Message (T "updater.error" @($info.Error)) (T "updater.group") "Warning"
        return
    }

    if ((Compare-ProductVersions $ProductInfo.version $info.Version) -ge 0) {
        $lblUpdateStatus.Text = T "updater.status_uptodate" @($ProductInfo.version)
        Show-Message (T "updater.uptodate" @($ProductInfo.version)) (T "updater.group")
        return
    }

    $choice = Show-UpdateChangelogDialog -NewVersion $info.Version -CurrentVersion $ProductInfo.version -Changelog $info.Body

    if ($choice -eq "github") {
        if ($info.HtmlUrl) { Start-Process $info.HtmlUrl }
        $lblUpdateStatus.Text = ""
        return
    }
    if ($choice -ne "install") {
        $lblUpdateStatus.Text = ""
        return
    }

    if (-not $info.AssetUrl) {
        Show-Message (T "updater.no_asset" @($info.Version)) (T "updater.group") "Warning"
        if ($info.HtmlUrl) { Start-Process $info.HtmlUrl }
        $lblUpdateStatus.Text = ""
        return
    }

    $lblUpdateStatus.Text = T "updater.downloading" @($info.AssetName)
    $form.Refresh()

    $target = Join-Path $env:TEMP $info.AssetName
    $previousProgress = $ProgressPreference
    try {
        $ProgressPreference = "SilentlyContinue"
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $info.AssetUrl -OutFile $target -UseBasicParsing -TimeoutSec 600
    }
    catch {
        $lblUpdateStatus.Text = ""
        Show-Message (T "updater.download_failed" @($_.Exception.Message)) (T "updater.group") "Error"
        return
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    Show-Message (T "updater.starting_install") (T "updater.group")
    Start-Process $target
    $form.Close()
}

# Modo desarrollador: git pull sobre la carpeta del launcher.
function Invoke-GitUpdate {
    $gitDir = Join-Path $InstallRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir)) { return }

    $confirm = [Windows.Forms.MessageBox]::Show(
        (T "updater.git_confirm" @($InstallRoot)),
        (T "updater.group"),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [Windows.Forms.DialogResult]::Yes) { return }

    # cmd /c con redireccion propia: en PS 5.1 con EAP=Stop, capturar el
    # stderr de un exe nativo directamente lanzaria NativeCommandError.
    $output = & cmd /c "git -C ""$InstallRoot"" pull 2>&1"
    $text = ($output | Out-String).Trim()

    if ($LASTEXITCODE -eq 0) {
        Show-Message (T "updater.git_done" @($text)) (T "updater.group")
    }
    else {
        Show-Message (T "updater.git_failed" @($text)) (T "updater.group") "Error"
    }
}
