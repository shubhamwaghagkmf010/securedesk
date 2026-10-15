Put the output of build\Build-WindowsClients.ps1 here (Content\Win-x64, Content\Win-x86, Content\Remotely_Installer.exe).
The Dockerfile copies this folder into wwwroot. If it is empty the image uses the stock clients of the upstream release.
