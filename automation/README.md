# SecureDesk Auto-Update & Vulnerability-Scan Automation

Built for, and tied to, the main SecureDesk host (where `~/securedesk-ui-build` - the
full source tree - lives). It is **not** a drop-in script for an arbitrary server;
a fresh install done with `SecureDesk-Installation.sh` just runs the published Docker
image and updates by re-pulling it, it does not use any of this.

Everything here is **read/build/test only** by default. Nothing is ever deployed to the
live production container automatically - a human always runs `safe-deploy.sh` by hand
after reviewing a result.

## The pieces

| Script | What it does | Run by |
|---|---|---|
| `check-for-updates.sh` | Pulls the tracked base images (see `docker_images:` in the config), compares digests against the last known ones, and checks whether the pinned .NET channel is still "active" upstream (notice only, never auto-upgrades). If a base-image changed, hands off to `auto-update-build-and-test.sh`. | cron (weekly) or manually |
| `scan-vulnerabilities.sh` | Scans the live image (Trivy) and the source tree's NuGet packages (`dotnet list package --vulnerable`) for CVEs. Auto-triggers a rebuild for Critical/High findings that have a known fix. | cron (daily) or manually |
| `auto-update-build-and-test.sh` | Rebuilds from `~/securedesk-ui-build` with `docker build --pull`, stands up a throwaway isolated test stack, runs the full check suite (non-root, Swagger disabled, security headers, antiforgery secure, login flow, Blazor negotiate, optional CVE-fix confirmation). Passes -> candidate image kept, tagged `ready-for-review`. Fails -> candidate discarded automatically. Never touches production. | called automatically by the two scripts above, or run directly to force a rebuild+test right now |
| `safe-deploy.sh` | **Manual only.** Backs up the compose file and the live SQLite database, swaps the production app image, health-checks it for up to ~60s, and automatically rolls back to the previous image if the health check fails. | a human, after reviewing a `ready-for-review` candidate |
| `rollback.sh` | **Manual only.** Reverts production to a known-good image (defaults to `shubhamwaghagkmf010/securedesk:1.4.0`). | a human |
| `git-sync-push.sh` | **Manual only.** Syncs the current `~/securedesk-ui-build` source and this `automation/` folder into a git clone of this repo and pushes, after showing the diff and asking for confirmation. | a human, when source/automation changes need to go to GitHub |

## Status and logs

- `~/securedesk-auto-update/status.json` - always reflects the last run's outcome (`up-to-date`, `update-detected`, `ready-for-review`, `failed`, `disabled`).
- `~/securedesk-auto-update/logs/` - a timestamped log per run (`check-*.log`, `build-*.log`, `safe-deploy-*.log`, `vulnerability-report-*.log`).

## Configuration (`auto-update-config.yaml`)

Flat `key: value` file, read by `lib/config.sh` (no `yq`/Python dependency). Key switches:

- `auto_update_enabled: true|false` - **master switch**. `false` makes `check-for-updates.sh` exit immediately and do nothing else.
- `auto_deploy_to_production: false` - must stay `false`. There is no config flag that makes this `true` do anything; production deploys always require a human to run `safe-deploy.sh` by hand.
- `require_tests_pass: true` - a candidate is only kept if every check in `auto-update-build-and-test.sh` passes.
- `vulnerability_severity_auto_trigger: high` - the minimum severity that auto-triggers a rebuild from `scan-vulnerabilities.sh`.
- `docker_images:` - the list of base images tracked for patch-level updates.

## Typical flow

```bash
# weekly/daily, normally via cron - see below
bash ~/securedesk-auto-update/check-for-updates.sh
bash ~/securedesk-auto-update/scan-vulnerabilities.sh

# check what happened
cat ~/securedesk-auto-update/status.json

# if a candidate is ready-for-review, a human deploys it:
sudo bash ~/securedesk-auto-update/safe-deploy.sh <candidate-or-registry-image-tag>

# if something goes wrong after a deploy that safe-deploy.sh's own health
# check somehow missed:
sudo bash ~/securedesk-auto-update/rollback.sh
```

## Cron (not installed automatically - add it yourself)

```
0 2 * * *   /home/claude/securedesk-auto-update/scan-vulnerabilities.sh >> /home/claude/securedesk-auto-update/logs/cron-scan.log 2>&1
0 3 * * 1   /home/claude/securedesk-auto-update/check-for-updates.sh >> /home/claude/securedesk-auto-update/logs/cron-check.log 2>&1
```

## What this system will never do by itself

- Deploy to the live production container.
- Move to a new major .NET version (that stays a deliberate, human-reviewed phase).
- Fix an application-level dependency CVE by itself (a NuGet version bump in `Server.csproj` needs a human decision, same as a major .NET upgrade).
- Push to GitHub or Docker Hub (`git-sync-push.sh` and any registry push are manual, confirmed steps).
