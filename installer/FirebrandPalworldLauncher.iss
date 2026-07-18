; ============================================================
; FirebrandPalworldLauncher.iss - Instalador del producto
;
; Compilar via tools\build_installer.ps1 (pasa /DMyAppVersion=X.Y.Z).
; Politica: instalacion per-user por defecto (sin UAC); el usuario
; puede elevar a "todos los usuarios" desde el dialogo de Inno.
; El desinstalador JAMAS toca mundos/backups del servidor (viven fuera
; de {app}); la config del launcher en LOCALAPPDATA solo se borra si
; el usuario lo confirma expresamente (y nunca en desinstalacion
; silenciosa).
; ============================================================

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "Firebrand Palworld Server Launcher"
#define MyAppPublisher "Firebrand Software"
#define MyAppURL "https://github.com/firebrand-dev/firebrand-palworld-server-launcher"
#define MyAppExeName "FirebrandPalworldLauncher.exe"

[Setup]
AppId={{6F1B7A9E-4C1D-4E2A-9A64-FB9D51A0C7E3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Firebrand Software\Palworld Launcher
DefaultGroupName=Firebrand Software
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\dist
OutputBaseFilename=FirebrandPalworldLauncherSetup-{#MyAppVersion}
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=auto
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
english.AutoStartTask=Start the launcher when Windows starts (if "start the server when the launcher opens" is enabled, the server starts too)
spanish.AutoStartTask=Iniciar el launcher al iniciar Windows (si activaste "iniciar el servidor al abrir el launcher", el server también arranca)
brazilianportuguese.AutoStartTask=Iniciar o launcher junto com o Windows (se "iniciar o servidor ao abrir o launcher" estiver ativo, o servidor também inicia)
german.AutoStartTask=Launcher beim Windows-Start ausführen (wenn "Server beim Öffnen des Launchers starten" aktiv ist, startet auch der Server)
japanese.AutoStartTask=Windows起動時にランチャーを起動する（「ランチャーを開いたらサーバーを起動」が有効なら、サーバーも起動します）
french.AutoStartTask=Lancer le launcher au démarrage de Windows (si « démarrer le serveur à l'ouverture du launcher » est activé, le serveur démarre aussi)
italian.AutoStartTask=Avvia il launcher all'avvio di Windows (se "avvia il server all'apertura del launcher" è attivo, parte anche il server)
english.RemoveUserData=Do you also want to delete the launcher settings (language, options, logs)?%nYour Palworld SERVER, its worlds and backups will NOT be touched.
spanish.RemoveUserData=¿Querés borrar también la configuración del launcher (idioma, opciones, logs)?%nTu SERVIDOR de Palworld, sus mundos y backups NO se tocan.
brazilianportuguese.RemoveUserData=Quer excluir também as configurações do launcher (idioma, opções, logs)?%nSeu SERVIDOR de Palworld, seus mundos e backups NÃO serão tocados.
german.RemoveUserData=Möchtest du auch die Launcher-Einstellungen löschen (Sprache, Optionen, Logs)?%nDein Palworld-SERVER, seine Welten und Backups werden NICHT angetastet.
japanese.RemoveUserData=ランチャーの設定（言語・オプション・ログ）も削除しますか？%nPalworldサーバー本体、ワールド、バックアップには一切触れません。
french.RemoveUserData=Veux-tu aussi supprimer les réglages du launcher (langue, options, logs) ?%nTon SERVEUR Palworld, ses mondes et ses backups ne seront PAS touchés.
italian.RemoveUserData=Vuoi eliminare anche le impostazioni del launcher (lingua, opzioni, log)?%nIl tuo SERVER di Palworld, i suoi mondi e i backup NON verranno toccati.

[Files]
Source: "..\build\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\launcher\FirebrandPalworldLauncher.ps1"; DestDir: "{app}\launcher"; Flags: ignoreversion
Source: "..\launcher\lib\*.ps1"; DestDir: "{app}\launcher\lib"; Flags: ignoreversion
Source: "..\locales\*.json"; DestDir: "{app}\locales"; Flags: ignoreversion
Source: "..\config\app_links.json"; DestDir: "{app}\config"; Flags: ignoreversion
Source: "..\build\version.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "{cm:AutoStartTask}"; Flags: unchecked

[Registry]
; Autostart per-user (HKCU: sin permisos de admin). Se elimina al desinstalar.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "FirebrandPalworldLauncher"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: string;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { Nunca en silencioso: sin confirmacion explicita no se borra nada }
    if not UninstallSilent then
    begin
      DataDir := ExpandConstant('{localappdata}\FirebrandSoftware\PalworldLauncher');
      if DirExists(DataDir) then
      begin
        if MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
          DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
