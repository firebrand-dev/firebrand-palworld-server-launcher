// ============================================================
// Launcher.cs - Stub nativo del Firebrand Palworld Server Launcher
//
// Unico proposito: ser un .exe real (icono, version, acceso directo,
// barra de tareas) que lanza el launcher PowerShell. NO usa PS2EXE
// a proposito: los wrappers de scripts disparan falsos positivos de
// antivirus y rompen Start-Job; un Process.Start plano no.
//
// Se compila con el csc.exe de .NET Framework incluido en Windows
// (ver tools\build_installer.ps1): no requiere SDK.
// ============================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main()
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(baseDir, "launcher", "FirebrandPalworldLauncher.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show(
                "File not found / No se encontró:\r\n" + script,
                "Firebrand Palworld Server Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = baseDir
        };

        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Could not start PowerShell / No se pudo iniciar PowerShell:\r\n" + ex.Message,
                "Firebrand Palworld Server Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
