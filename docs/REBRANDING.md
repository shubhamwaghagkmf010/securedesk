# What was changed from upstream Remotely

Base: Remotely v2022.08.02.0428 (GNU GPL v3).

## Branding (user visible)
* Name, logo and images (`Server/wwwroot/images/SecureDesk_*`), page titles, navigation, About page (with attribution), manifests, e-mail texts, Swagger title.
* Default product name `SecureDesk` (`Shared/Utilities/AppConstants.cs`, `Shared/Models/BrandingInfo.cs`).
* Download names: `SecureDesk_Desktop-[code].exe`, `SecureDesk_Install-[code].exe` (`Server/API/ClientDownloadsController.cs`).
* Downloads page examples show the logged-in organization's real ID and this server's URL (upstream printed a fixed sample ID that people copied by mistake).

## Windows clients
* New dark-glass theme with embedded fonts for the installer and the session client (`Agent.Installer.Win`, `Desktop.Win`).
* Folders: `Program Files\SecureDesk`, `%APPDATA%\SecureDesk`, `ProgramData\SecureDesk`; firewall rule `SecureDesk Desktop Unattended`; logs `SecureDesk_*.log`.
  Older installations in `Program Files\Remotely` are migrated (device ID kept, service recreated, old folder removed).
* Optional server URL built into the clients: `Shared/Models/EmbeddedServer.cs`, set by `build/Build-WindowsClients.ps1 -ServerUrl`.
* The installer also builds as an SDK-style project (`SecureDesk.Installer.csproj`); the desktop-shortcut COM reference was replaced by the same Windows Script Host object through late binding.

## Docker
* `docker/Dockerfile`, `docker/entrypoint.sh` (creates the first administrator), `docker-compose.yml` + `Caddyfile` (HTTPS).

## Intentionally unchanged (internal names)
Namespaces, database tables, `Remotely_Agent.exe`, `Remotely_Desktop.exe`, `Remotely_Installer.exe`, service `Remotely_Service`,
registry key `...\Uninstall\Remotely`, agent zip file names. Renaming them would break updates, uninstall and server commands.

## Not rebuilt
The agent packages (`Remotely-Win10-*.zip`, Linux, macOS) are the stock upstream ones.
