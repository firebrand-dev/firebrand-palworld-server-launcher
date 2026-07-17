# ============================================================
# Wizard.ps1 - Asistente de primera instalacion del servidor
#
# Tres caminos:
#   1) Instalar un servidor NUEVO con SteamCMD en una carpeta elegida
#      (se NIEGA a instalar encima de un server existente).
#   2) Adoptar un servidor YA instalado (no reinstala ni toca nada:
#      solo apunta el launcher a esa carpeta).
#   3) "Ahora no": no vuelve a preguntar (wizard-declined.flag).
#
# Se dot-source-a desde el launcher principal: usa T(), Show-Message,
# Install-SteamCmd, Save-LauncherOptions, Set-LauncherPathVariables,
# Load-Settings y las variables de rutas del script principal.
# Compatible con Windows PowerShell 5.1.
# ============================================================

function Show-FirstRunWizard {
    $wiz = New-Object Windows.Forms.Form
    $wiz.Text = T "wizard.title"
    $wiz.Size = New-Object Drawing.Size(680, 560)
    $wiz.StartPosition = "CenterScreen"
    $wiz.FormBorderStyle = "FixedDialog"
    $wiz.MaximizeBox = $false
    $wiz.MinimizeBox = $false
    $wiz.Font = New-Object Drawing.Font("Segoe UI", 10)

    $header = New-Object Windows.Forms.Label
    $header.Text = $ProductInfo.product
    $header.Font = New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)
    $header.AutoSize = $true
    $header.Location = New-Object Drawing.Point(20, 15)
    $wiz.Controls.Add($header)

    # ---------------- Pagina 1: eleccion ----------------
    $pageChoice = New-Object Windows.Forms.Panel
    $pageChoice.Location = New-Object Drawing.Point(10, 55)
    $pageChoice.Size = New-Object Drawing.Size(650, 455)
    $wiz.Controls.Add($pageChoice)

    $welcome = New-Object Windows.Forms.Label
    $welcome.Text = T "wizard.welcome"
    $welcome.Location = New-Object Drawing.Point(12, 10)
    $welcome.Size = New-Object Drawing.Size(620, 40)
    $pageChoice.Controls.Add($welcome)

    $rbNew = New-Object Windows.Forms.RadioButton
    $rbNew.Text = T "wizard.opt_new"
    $rbNew.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $rbNew.Location = New-Object Drawing.Point(20, 60)
    $rbNew.Size = New-Object Drawing.Size(610, 26)
    $rbNew.Checked = $true
    $pageChoice.Controls.Add($rbNew)

    $lblNewDesc = New-Object Windows.Forms.Label
    $lblNewDesc.Text = T "wizard.opt_new_desc"
    $lblNewDesc.Location = New-Object Drawing.Point(42, 88)
    $lblNewDesc.Size = New-Object Drawing.Size(580, 42)
    $pageChoice.Controls.Add($lblNewDesc)

    $rbExisting = New-Object Windows.Forms.RadioButton
    $rbExisting.Text = T "wizard.opt_existing"
    $rbExisting.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $rbExisting.Location = New-Object Drawing.Point(20, 140)
    $rbExisting.Size = New-Object Drawing.Size(610, 26)
    $pageChoice.Controls.Add($rbExisting)

    $lblExistingDesc = New-Object Windows.Forms.Label
    $lblExistingDesc.Text = T "wizard.opt_existing_desc"
    $lblExistingDesc.Location = New-Object Drawing.Point(42, 168)
    $lblExistingDesc.Size = New-Object Drawing.Size(580, 42)
    $pageChoice.Controls.Add($lblExistingDesc)

    $btnNext = New-Object Windows.Forms.Button
    $btnNext.Text = T "wizard.btn_next"
    $btnNext.Location = New-Object Drawing.Point(460, 400)
    $btnNext.Size = New-Object Drawing.Size(170, 38)
    $pageChoice.Controls.Add($btnNext)

    $btnLater = New-Object Windows.Forms.Button
    $btnLater.Text = T "wizard.opt_later"
    $btnLater.Location = New-Object Drawing.Point(20, 400)
    $btnLater.Size = New-Object Drawing.Size(150, 38)
    $pageChoice.Controls.Add($btnLater)

    # ---------------- Pagina 2: nuevo o existente ----------------
    $pageSetup = New-Object Windows.Forms.Panel
    $pageSetup.Location = New-Object Drawing.Point(10, 55)
    $pageSetup.Size = New-Object Drawing.Size(650, 455)
    $pageSetup.Visible = $false
    $wiz.Controls.Add($pageSetup)

    $lblFolder = New-Object Windows.Forms.Label
    $lblFolder.Location = New-Object Drawing.Point(12, 10)
    $lblFolder.Size = New-Object Drawing.Size(620, 22)
    $pageSetup.Controls.Add($lblFolder)

    $txtFolder = New-Object Windows.Forms.TextBox
    $txtFolder.Location = New-Object Drawing.Point(12, 36)
    $txtFolder.Size = New-Object Drawing.Size(450, 25)
    $pageSetup.Controls.Add($txtFolder)

    $btnBrowse = New-Object Windows.Forms.Button
    $btnBrowse.Text = T "wizard.btn_browse"
    $btnBrowse.Location = New-Object Drawing.Point(472, 33)
    $btnBrowse.Size = New-Object Drawing.Size(160, 30)
    $btnBrowse.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) {
            $dialog.SelectedPath = $txtFolder.Text
        }
        if ($dialog.ShowDialog($wiz) -eq [Windows.Forms.DialogResult]::OK) {
            $txtFolder.Text = $dialog.SelectedPath
        }
    })
    $pageSetup.Controls.Add($btnBrowse)

    $lblFolderStatus = New-Object Windows.Forms.Label
    $lblFolderStatus.Location = New-Object Drawing.Point(12, 68)
    $lblFolderStatus.Size = New-Object Drawing.Size(620, 40)
    $pageSetup.Controls.Add($lblFolderStatus)

    # Config inicial (solo para server nuevo)
    $configPanel = New-Object Windows.Forms.Panel
    $configPanel.Location = New-Object Drawing.Point(0, 112)
    $configPanel.Size = New-Object Drawing.Size(650, 180)
    $pageSetup.Controls.Add($configPanel)

    $lblCfgTitle = New-Object Windows.Forms.Label
    $lblCfgTitle.Text = T "wizard.config_title"
    $lblCfgTitle.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $lblCfgTitle.Location = New-Object Drawing.Point(12, 4)
    $lblCfgTitle.AutoSize = $true
    $configPanel.Controls.Add($lblCfgTitle)

    $lblCfgName = New-Object Windows.Forms.Label
    $lblCfgName.Text = T "wizard.config_name"
    $lblCfgName.Location = New-Object Drawing.Point(12, 36)
    $lblCfgName.AutoSize = $true
    $configPanel.Controls.Add($lblCfgName)

    $txtCfgName = New-Object Windows.Forms.TextBox
    $txtCfgName.Location = New-Object Drawing.Point(12, 58)
    $txtCfgName.Size = New-Object Drawing.Size(400, 25)
    $txtCfgName.Text = T "default.server_name"
    $configPanel.Controls.Add($txtCfgName)

    $lblCfgAdmin = New-Object Windows.Forms.Label
    $lblCfgAdmin.Text = T "wizard.config_admin"
    $lblCfgAdmin.Location = New-Object Drawing.Point(12, 92)
    $lblCfgAdmin.AutoSize = $true
    $configPanel.Controls.Add($lblCfgAdmin)

    $txtCfgAdmin = New-Object Windows.Forms.TextBox
    $txtCfgAdmin.Location = New-Object Drawing.Point(12, 114)
    $txtCfgAdmin.Size = New-Object Drawing.Size(400, 25)
    $txtCfgAdmin.UseSystemPasswordChar = $true
    $configPanel.Controls.Add($txtCfgAdmin)

    $lblCfgPort = New-Object Windows.Forms.Label
    $lblCfgPort.Text = T "wizard.config_port"
    $lblCfgPort.Location = New-Object Drawing.Point(440, 92)
    $lblCfgPort.AutoSize = $true
    $configPanel.Controls.Add($lblCfgPort)

    $numCfgPort = New-Object Windows.Forms.NumericUpDown
    $numCfgPort.Location = New-Object Drawing.Point(440, 114)
    $numCfgPort.Size = New-Object Drawing.Size(120, 25)
    $numCfgPort.Minimum = 1
    $numCfgPort.Maximum = 65535
    $numCfgPort.Value = 8211
    $configPanel.Controls.Add($numCfgPort)

    $chkFirewall = New-Object Windows.Forms.CheckBox
    $chkFirewall.Text = T "wizard.firewall"
    $chkFirewall.Location = New-Object Drawing.Point(12, 300)
    $chkFirewall.Size = New-Object Drawing.Size(620, 40)
    $pageSetup.Controls.Add($chkFirewall)

    $lblProgress = New-Object Windows.Forms.Label
    $lblProgress.Location = New-Object Drawing.Point(12, 345)
    $lblProgress.Size = New-Object Drawing.Size(620, 50)
    $lblProgress.ForeColor = [Drawing.Color]::DarkBlue
    $pageSetup.Controls.Add($lblProgress)

    $btnAction = New-Object Windows.Forms.Button
    $btnAction.Location = New-Object Drawing.Point(460, 400)
    $btnAction.Size = New-Object Drawing.Size(170, 38)
    $pageSetup.Controls.Add($btnAction)

    $btnBack = New-Object Windows.Forms.Button
    $btnBack.Text = T "wizard.btn_back"
    $btnBack.Location = New-Object Drawing.Point(20, 400)
    $btnBack.Size = New-Object Drawing.Size(150, 38)
    $btnBack.Add_Click({
        $pageSetup.Visible = $false
        $pageChoice.Visible = $true
    })
    $pageSetup.Controls.Add($btnBack)

    $script:WizardMode = "new"
    $script:WizardBusy = $false

    $showSetupPage = {
        param([string]$Mode)
        $script:WizardMode = $Mode
        $lblProgress.Text = ""
        $lblFolderStatus.Text = ""
        if ($Mode -eq "new") {
            $lblFolder.Text = T "wizard.new_folder_label"
            if (-not $txtFolder.Text) { $txtFolder.Text = "C:\PalworldServer" }
            $configPanel.Visible = $true
            $btnAction.Text = T "wizard.btn_install"
        }
        else {
            $lblFolder.Text = T "wizard.existing_folder_label"
            $txtFolder.Text = ""
            $configPanel.Visible = $false
            $btnAction.Text = T "wizard.btn_finish"
        }
        $pageChoice.Visible = $false
        $pageSetup.Visible = $true
    }

    $btnNext.Add_Click({
        if ($rbNew.Checked) { & $showSetupPage "new" } else { & $showSetupPage "existing" }
    })

    $btnLater.Add_Click({
        try {
            New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $DataRoot "wizard-declined.flag") `
                -Value "Borra este archivo para que el asistente vuelva a ofrecerse al iniciar." -Encoding UTF8
        }
        catch {}
        $wiz.Close()
    })

    # Aplica el resultado del wizard al launcher: persiste rutas, re-resuelve y refresca.
    # OJO: $PSScriptRoot aca seria launcher\lib; usar $LauncherScriptDir del principal.
    $applyServerSelection = {
        param([string]$NewServerRoot, [string]$NewServerDir)
        $script:ServerRoot = $NewServerRoot
        $script:ServerDir = $NewServerDir
        Save-LauncherOptions
        Set-LauncherPathVariables (Get-LauncherPaths -ScriptDir $script:LauncherScriptDir)
    }

    $createFirewallRule = {
        param([int]$Port)
        try {
            $ruleCommand = "New-NetFirewallRule -DisplayName 'Palworld Dedicated Server UDP $Port' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $Port"
            Start-Process powershell.exe -Verb RunAs -Wait `
                -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-Command", $ruleCommand
        }
        catch {
            Show-Message (T "wizard.firewall_failed") (T "wizard.title") "Warning"
        }
    }

    $btnAction.Add_Click({
        if ($script:WizardBusy) { return }
        $folder = $txtFolder.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($folder)) { return }

        if ($script:WizardMode -eq "existing") {
            # ---- Adoptar server existente: NO se toca nada, solo se apunta ----
            $selection = Resolve-ExistingServerSelection -Folder $folder
            if (-not $selection.Found) {
                $lblFolderStatus.Text = T "wizard.existing_not_found"
                $lblFolderStatus.ForeColor = [Drawing.Color]::DarkRed
                return
            }

            & $applyServerSelection $selection.ServerRoot $selection.ServerDir
            if ($chkFirewall.Checked) { & $createFirewallRule ([int]$numCfgPort.Value) }
            Load-Settings
            Update-Status
            Show-Message (T "wizard.existing_found" @($selection.ServerExe)) (T "wizard.title")
            $wiz.Close()
            return
        }

        # ---- Instalar server NUEVO ----
        $existingCheck = Resolve-ExistingServerSelection -Folder $folder
        if ($existingCheck.Found) {
            # Jamas instalar encima de un server que ya existe: ofrecer adoptarlo.
            $adopt = [Windows.Forms.MessageBox]::Show(
                (T "wizard.folder_has_server"),
                (T "wizard.title"),
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($adopt -eq [Windows.Forms.DialogResult]::Yes) {
                & $applyServerSelection $existingCheck.ServerRoot $existingCheck.ServerDir
                Load-Settings
                Update-Status
                Show-Message (T "wizard.existing_found" @($existingCheck.ServerExe)) (T "wizard.title")
                $wiz.Close()
            }
            return
        }

        if ([string]::IsNullOrWhiteSpace($txtCfgAdmin.Text)) {
            $lblFolderStatus.Text = T "wizard.admin_required"
            $lblFolderStatus.ForeColor = [Drawing.Color]::DarkRed
            return
        }

        # Verificar que la carpeta sea escribible
        try {
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $probe = Join-Path $folder (".fbpl_probe_" + [guid]::NewGuid().ToString("N"))
            Set-Content -LiteralPath $probe -Value "ok" -Encoding UTF8
            Remove-Item -LiteralPath $probe -Force
        }
        catch {
            $lblFolderStatus.Text = T "wizard.folder_not_writable" @($_.Exception.Message)
            $lblFolderStatus.ForeColor = [Drawing.Color]::DarkRed
            return
        }

        $script:WizardBusy = $true
        $btnAction.Enabled = $false
        $btnBack.Enabled = $false
        $lblFolderStatus.Text = ""

        try {
            # 1) SteamCMD (si falta)
            $wizardSteamCmdDir = Join-Path $folder "steamcmd"
            $wizardSteamCmdExe = Join-Path $wizardSteamCmdDir "steamcmd.exe"
            if (-not (Test-Path -LiteralPath $wizardSteamCmdExe)) {
                Install-SteamCmd -TargetDir $wizardSteamCmdDir -OnStatus { param($s) $lblProgress.Text = $s; $wiz.Refresh() }
            }

            # 2) Instalar el server con consola de SteamCMD visible
            $lblProgress.Text = T "wizard.installing"
            $wiz.Refresh()
            $targetServerDir = Join-Path $folder "server"
            $steamArgs = "+force_install_dir `"$targetServerDir`" +login anonymous +app_update 2394010 validate +quit"
            $steamProc = Start-Process -FilePath $wizardSteamCmdExe -ArgumentList $steamArgs -PassThru -WindowStyle Normal

            while (-not $steamProc.HasExited) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 300
            }

            # Criterio de exito real: que el binario exista (SteamCMD devuelve
            # codigos raros como 7 al auto-actualizarse).
            if (-not (Test-Path -LiteralPath (Join-Path $targetServerDir "PalServer.exe"))) {
                throw (T "wizard.steamcmd_exit" @($steamProc.ExitCode))
            }

            # 3) Apuntar el launcher y escribir la config inicial
            & $applyServerSelection $folder $targetServerDir

            $iniText = Get-IniText
            $iniText = Set-IniValue -Text $iniText -Key "ServerName" -Value $txtCfgName.Text -Quoted $true
            $iniText = Set-IniValue -Text $iniText -Key "AdminPassword" -Value $txtCfgAdmin.Text -Quoted $true
            $iniText = Set-IniValue -Text $iniText -Key "PublicPort" -Value ([int]$numCfgPort.Value).ToString() -Quoted $false
            $iniText = Set-IniValue -Text $iniText -Key "RESTAPIEnabled" -Value "True" -Quoted $false
            [IO.File]::WriteAllText($ConfigFile, $iniText, [Text.UTF8Encoding]::new($false))

            # 4) Firewall opcional (UAC)
            if ($chkFirewall.Checked) { & $createFirewallRule ([int]$numCfgPort.Value) }

            Load-Settings
            Update-Status
            Write-Activity (T "wizard.installed_activity" @($targetServerDir))

            Show-Message ((T "wizard.install_ok") + "`n`n" + (T "wizard.summary" @($ServerDir, $BackupDir, $LauncherPaths.SteamCmdDir))) (T "wizard.title")
            $wiz.Close()
        }
        catch {
            $lblProgress.Text = ""
            Show-Message (T "wizard.install_failed" @($_.Exception.Message)) (T "wizard.title") "Error"
        }
        finally {
            $script:WizardBusy = $false
            $btnAction.Enabled = $true
            $btnBack.Enabled = $true
        }
    })

    $wiz.Add_FormClosing({
        if ($script:WizardBusy) { $_.Cancel = $true }
    })

    [void]$wiz.ShowDialog($form)
    $wiz.Dispose()
}
