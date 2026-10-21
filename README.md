# SecureDesk

SecureDesk is a self-hosted remote support and remote control platform: unattended access, remote scripting, a web terminal,
file transfer and browser-based remote desktop, with HTTPS out of the box.

SecureDesk has its own interface (Aurora Glass themes, colour themes, custom backgrounds, redesigned remote control screen and Windows clients),
a ready-to-run Docker setup and HTTPS. It builds on the open-source **[Remotely](https://github.com/immense/Remotely)** remote-control engine
(GNU GPL v3, version 2022.08.02.0428), and keeps that project's license and credits. See [NOTICE](NOTICE) for the credits and
[docs/CHANGES.md](docs/CHANGES.md) for what SecureDesk adds.

---

## Default login

| | |
|---|---|
| **URL** | `https://localhost` (or the host you set in `.env`) |
| **Email** | `admin@securedesk.local` |
| **Password** | `SecureDesk@123` |

The account is created automatically the first time the container starts with an empty database.
**Change the password after your first login** (Account menu), or set your own before the first start:

```
SECUREDESK_ADMIN_EMAIL=you@example.com
SECUREDESK_ADMIN_PASSWORD=a-strong-password
```

Do not expose an instance that still uses the default password to the internet.
Set `SECUREDESK_SEED_ADMIN=false` if you prefer to create the first account yourself with the *Register* button.

---

## Install on a new server (one script)

```bash
git clone https://github.com/shubhamwaghagkmf010/securedesk.git
cd securedesk
sudo bash SecureDesk-Installation.sh
```

The script does everything for you and prints each step with a time stamp (the same log is saved as `install.log` in the install folder):

* asks where to install: `/appdata/securedesk`, the current folder, or any other folder (shows the free space of each)
* installs Docker and Docker Compose if they are missing
* checks the HTTP and HTTPS ports (80 / 443); if one is busy it shows which program uses it and moves to a free port (8080, 5443, ...). Nothing that is running is stopped
* downloads the compose files, pulls the image, starts SecureDesk and checks that the login page answers
* ends with a summary: URL (with the chosen port), default login, folder, ports and log path

Running it again later is safe: your `.env` and data are kept, and the image is updated. Options: `--dir PATH`, `--http-port N`, `--https-port N`, `--host NAME_OR_IP`, `--yes` (no questions), `--help`.

---

## Quick start (Docker, with HTTPS)

```bash
git clone https://github.com/shubhamwaghagkmf010/securedesk.git
cd securedesk
cp .env.example .env          # edit SECUREDESK_HOST if needed
docker compose up -d
```

Open `https://localhost` and log in with the default login above.
The first start downloads the images and needs about a minute before the page answers; `docker compose logs securedesk` shows the line `SecureDesk administrator created`.
Your browser will warn about the certificate (it comes from Caddy's own local authority); continue, or trust it as described under [HTTPS](#https).

Good to know:
* **Port 80 or 443 already in use?** Set `SECUREDESK_HTTP_PORT` / `SECUREDESK_HTTPS_PORT` in `.env` (for example `8080` and `8443`) and open `https://localhost:8443`.
* **Opening it from another computer?** Put the server's IP address or domain in `SECUREDESK_HOST` in `.env`, then run `docker compose up -d` again.
* **Run it twice on one machine?** Use a different folder (or `docker compose -p name`) and different ports.

Only the image, without HTTPS (testing only):

```bash
docker run -d --name securedesk -p 5000:5000 -v securedesk-data:/remotely-data shubhamwaghagkmf010/securedesk:latest
# http://localhost:5000   (same default login)
```

### Settings (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `SECUREDESK_HOST` | `localhost` | Name or IP address people use to open SecureDesk |
| `SECUREDESK_HTTPS_PORT` / `SECUREDESK_HTTP_PORT` | `443` / `80` | Ports published on the host |
| `SECUREDESK_ADMIN_EMAIL` | `admin@securedesk.local` | First administrator (created once, on an empty database) |
| `SECUREDESK_ADMIN_PASSWORD` | `SecureDesk@123` | Password of that account |
| `SECUREDESK_SEED_ADMIN` | `true` | `false` = do not create the account automatically |
| `SECUREDESK_IMAGE` | `shubhamwaghagkmf010/securedesk:latest` | Image to run |

Data (database, settings) lives in the `securedesk-data` volume. Back it up with
`docker run --rm -v securedesk-data:/d -v "$PWD":/b alpine tar czf /b/securedesk-data.tgz -C /d .`
Update with `docker compose pull && docker compose up -d`.

---

## Active Directory login (optional)

Technicians can sign in with their company Active Directory username and password, followed by an authenticator app code (2FA).
It is off until you switch it on, the normal login keeps working, and the local administrator account always works.

1. Copy `ad/ad-config.env.example` to `ad/ad-config.env` and `ad/ad-users.txt.example` to `ad/ad-users.txt`, then fill them in
   (domain controller, base DN, a read-only service account, the usernames that may log in, optional AD groups).
   Both files stay on your server: they are not in the image and not in Git.
2. Run `./apply-ad.sh`. It checks the files, tests the connection and the service account with the server's own code, and only if
   everything passes it sets `AD_ENABLED=true` and restarts SecureDesk. `./apply-ad.sh --test-login USER` also tests one password.
3. People type only their username (for example `raju`). New users are created automatically in the default organization (or, if none is marked, the server administrator's organization).
   Members of `AD_ADMINS_GROUP` become Organization Admins. To limit a user to some devices, put the user and those devices into a Device Group.

Two-factor sign-in is required for AD users by default (`AD_REQUIRE_2FA=true`). This is a security setting that only the server
administrator can change, in `ad/ad-config.env` (there is no switch in the web console); anything but an explicit `false` keeps it required.
The first AD login opens only the authenticator setup page. Use LDAPS (port 636); plain LDAP is refused unless `AD_ALLOW_INSECURE=true`.

## HTTPS

The `caddy` container terminates TLS and forwards to SecureDesk.

* **Public domain** (`SECUREDESK_HOST=desk.example.com`, DNS pointing to the server, ports 80 and 443 reachable):
  Caddy gets a real Let's Encrypt certificate automatically. Nothing else to do.
* **`localhost` or an IP address** (home lab, LAN): Caddy signs the certificate with its own local certificate authority.
  Browsers show a warning until that authority is trusted. To trust it:

  ```bash
  docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./securedesk-local-ca.crt
  ```
  Windows (run as Administrator): `certutil -addstore -f Root securedesk-local-ca.crt`
  Linux: copy it to `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.
  The agents (Windows service) use the Windows certificate store, so install the certificate on every managed PC, or use a real domain.

---

## Windows clients (installer and session client)

The server offers these on its **Downloads** page. They are named `SecureDesk_Install-[code].exe` and `SecureDesk_Desktop-[code].exe`;
the `[code]` identifies your organization, so the installer fills in the Organization ID itself.

* The images ship **generic** clients: they ask for the server URL once.
* To give your users clients that already know your server, build them on Windows (.NET SDK 6 or newer) and rebuild the image:

  ```powershell
  .\build\Build-WindowsClients.ps1 -ServerUrl https://desk.example.com
  docker build -f docker/Dockerfile -t my-securedesk .
  ```
  The script writes the clients to `docker/overlay/Content`, which the Dockerfile copies into the image.
* Installed folders: `C:\Program Files\SecureDesk`, `%APPDATA%\SecureDesk`, `C:\ProgramData\SecureDesk`.
  Installations made by older builds in `C:\Program Files\Remotely` are migrated automatically (same device identity).
* Silent install: `SecureDesk_Install-[code].exe -install -quiet -serverurl https://desk.example.com`.

---

## Build from source

```bash
git clone https://github.com/shubhamwaghagkmf010/securedesk.git
cd securedesk
docker build -f docker/Dockerfile -t securedesk .
docker run -d --name securedesk -p 5000:5000 -v securedesk-data:/remotely-data securedesk
# http://localhost:5000   (same default login)
```
The first build takes several minutes (it downloads the .NET packages).
The Dockerfile builds the web app from this tree and takes the stock agent packages from the Remotely release it builds on.

---

## What differs from upstream Remotely

* SecureDesk name, logo, colours, e-mail texts, page titles, API title, download file names.
* New dark-glass look for the Windows installer and session client.
* Windows folders, firewall rule and log files use the SecureDesk name; internal names (`Remotely_Agent.exe`, service `Remotely_Service`) are unchanged so agents, updates and uninstall keep working.
* Docker packaging: HTTPS through Caddy, automatic first administrator, reverse-proxy ready.

## License

GNU General Public License v3, same as Remotely. The license text is in [LICENSE](LICENSE); credits are in [NOTICE](NOTICE).
If you distribute modified versions (including Docker images or the Windows clients) you must make the corresponding source available under the same license.
Remotely is a trademark/product name of its authors; SecureDesk is not affiliated with or endorsed by them.
