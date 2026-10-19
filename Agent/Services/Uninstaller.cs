using Microsoft.Win32;
using Remotely.Shared.Utilities;
using System;
using System.Diagnostics;
using System.IO;

namespace Remotely.Agent.Services
{
    public class Uninstaller
    {
        public void UninstallAgent()
        {
            if (EnvironmentHelper.IsWindows)
            {
                Process.Start("cmd.exe", "/c sc delete Remotely_Service");

                var view = Environment.Is64BitOperatingSystem ?
                    "/reg:64" :
                    "/reg:32";

                Process.Start("cmd.exe", @$"/c REG DELETE HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Remotely /f {view}");

                var currentDir = Path.GetDirectoryName(typeof(Uninstaller).Assembly.Location);
                Process.Start("cmd.exe", $"/c timeout 5 & rd /s /q \"{currentDir}\"");
            }
            else if (EnvironmentHelper.IsLinux)
            {
                Process.Start("sudo", "systemctl stop remotely-agent").WaitForExit();
                foreach (var dir in new[] { "/usr/local/bin/SecureDesk", "/usr/local/bin/Remotely" })
                {
                    if (Directory.Exists(dir))
                    {
                        Directory.Delete(dir, true);
                    }
                }
                File.Delete("/etc/systemd/system/remotely-agent.service");
                Process.Start("sudo", "systemctl daemon-reload").WaitForExit();
            }
            Environment.Exit(0);
        }
    }
}
