# SecureDesk rebranding notes

SecureDesk is a rebranded build of **Remotely v2022.08.02.0428** (MIT License, (c) Translucency Software / Immense Networks).
The upstream LICENSE file is kept unchanged, as the MIT License requires.

## What was changed (user-facing only)
- Page titles, header/nav, home page, About/Credits, remote-control page title and header, PWA manifests,
  remote-session browser tab title, Swagger API title, email subjects/bodies, chat/script "server" user label,
  example URLs in UI hints, README.
- Default product name (`AppConstants.DefaultProductName`, `BrandingInfo.Product`) -> `SecureDesk`.
- Images: `SecureDesk_Logo.png` (276x88), `SecureDesk_Desktop.png` (360x344). Old names `Remotely_Logo.png` / `Remotely_Desktop.png`
  now contain the same SecureDesk artwork so cached emails/links do not break.
- Existing databases: a stored `BrandingInfo.Product = "Remotely"` row must be updated to `SecureDesk` (done on this deployment).

## Intentionally NOT changed (internal / compatibility)
| Reference | Why |
|---|---|
| C# namespaces `Remotely.*`, types `RemotelyUser`, etc. | internal identifiers; renaming risks breaking EF model, DI, Razor |
| DB tables/columns (`RemotelyUsers`, `DeviceGroupRemotelyUser`), `Migrations/*`, `Remotely.db` | schema/data compatibility; renaming would require a migration and break existing DBs |
| `Remotely_Server.dll`, `Remotely_Shared.dll`, `/DockerMain.sh` entrypoint, About-page version lookup | file/assembly names used by entrypoint and by code |
| `Remotely_Installer.exe`, `Remotely_Agent(.exe)`, `Remotely_Desktop(.exe)`, `Remotely-*.zip`, service name `Remotely_Service`, `Remotely_Logs.log` | prebuilt client binaries/paths; agents download these by name and self-update |
| CSS class `remotely-header`, `Remotely_Server.styles.css`, `Remotely_Icon*.png` (no text in artwork) | internal asset names; icon mark contains no brand text |
| SQL Server connection string DB name in `appsettings.json` | configuration value |
| GitHub URL in `UpgradeService` and About-page attribution link | upstream project reference / MIT attribution |

## Not rebuilt (needs Windows/macOS build agents) - still show "Remotely" inside the binaries
Prebuilt, unmodified: Windows agent + installer (`Remotely_Installer.exe`), Windows/Linux/macOS desktop (remote control) clients,
agent zips. Their window titles/installer text come from compiled resources. Desktop clients fetch the product name from the server
branding API (now `SecureDesk`), but compiled-in strings (e.g. installer UI, service display name) remain until rebuilt from source
(`Agent.Installer.Win`, `Desktop.Win`, `Desktop.XPlat`, `Agent`) with a Windows build host.

## Build notes
`dotnet publish Server/Server.csproj -c Release -r linux-x64 --self-contained false -p:Version=2022.08.02.0428 -p:FileVersion=2022.08.02.0428 -p:LibraryRestore=false -p:TypeScriptCompileBlocked=true`
(Version must be stamped or the server reports 1.0.0.0; LibMan/TypeScript steps are skipped because compiled JS/libs are committed.)
Image = original image + overlay of `Remotely_Server.dll`, `Remotely_Shared.dll`, manifests, images, patched `DtoMessageHandler.js`.

**Scoped CSS:** Blazor scoped-CSS ids (`b-xxxxxxxxxx`) are generated per build. `Remotely_Server.styles.css` MUST come from the same build as `Remotely_Server.dll`,
otherwise the layout CSS does not match and the UI falls back to the collapsed (mobile) layout on desktop. The overlay image includes the build-matching file.
