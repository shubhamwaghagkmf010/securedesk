#!/usr/bin/env bash
# SecureDesk updater
#
# Pulls whatever newer SecureDesk + Caddy images are currently published
# (Docker Hub for the app - includes its .NET runtime, security patches,
# etc baked in by the maintainer's build pipeline - and the official Caddy
# image for the reverse proxy) and safely swaps them in, with an automatic
# health check and automatic rollback if anything goes wrong.
#
# Works on ANY server set up with SecureDesk-Installation.sh (or any
# docker-compose.yml following the same layout). On its own it needs no
# source code, no .NET SDK, no build tools - it only pulls already-published
# images. By default it ALSO runs the full check/scan/build-and-test
# pipeline first (see "full pipeline" below) - that part bootstraps a git
# clone of the source tree for itself the first time it runs, but still
# never needs a human to pre-install anything.
#
#   -----------------------------------------------------------------
#   The maintainer's build/test/vulnerability-scan pipeline (what makes
#   a new image in the first place: compiling, Trivy scanning, running
#   the test suite) used to only run on the build server - see
#   automation/README.md in this repository. This script now ALSO runs
#   that same pipeline locally on every server (bootstrapping whatever it
#   needs - git, a clone of this repo - automatically), in addition to
#   its original job of pulling whatever the Docker Hub images publish.
#   Either path can surface a new candidate; a human still always decides
#   when to actually put one into production.
#   -----------------------------------------------------------------
#
# Run:      sudo bash securedesk-update.sh
# Options:
#   --dir PATH          install folder (auto-detected if not given: tries
#                        /appdata/securedesk, the current folder,
#                        ./securedesk, ~/securedesk)
#   --yes, -y           no confirmation prompt (for cron)
#   --check-only        report whether an update is available; change nothing
#   --rollback          restore the most recent backup this script made, now
#   --skip-full-pipeline  skip the check-for-updates/scan/build-and-test step
#                        below and only do the Docker Hub image pull+swap
#   --help, -h          show this text
#
# What happens, step by step:
#   1. Checks this server (docker present, root/sudo)
#   2. Finds the SecureDesk install folder
#   3. Runs the full update-detection pipeline (unless --skip-full-pipeline):
#      bootstraps a source-tree clone if one isn't already present, then
#      runs check-for-updates.sh, which itself chains into
#      scan-vulnerabilities.sh and auto-update-build-and-test.sh as needed.
#      This can produce a "ready-for-review" candidate image, built and
#      fully tested locally - it is NEVER deployed automatically; this step
#      only reports it and tells you the exact safe-deploy.sh command to
#      run by hand. Any failure here (no network, no git, build/test
#      failure) is logged and does not stop the rest of this script.
#   4. Records the currently-running image IDs
#   5. Pulls the latest published images (docker compose pull) - nothing
#      changed -> stops here, nothing is restarted
#   6. Something changed -> backs up docker-compose.yml and the live
#      SQLite database, then restarts with the new images
#   7. Health-checks the site for up to ~60 seconds
#   8. Healthy -> done, old images are kept on disk for --rollback.
#      NOT healthy -> automatically restores the backup and restarts on
#      the previous images - the same safety net as --rollback, but
#      automatic.
#
# Safe to run from cron on a schedule: it only ever changes anything when
# there is something new to apply, and it always verifies before leaving
# a new version running. Production is NEVER auto-deployed from a
# pipeline-built candidate - only from the already-published Docker Hub
# image, which went through that same pipeline and a human review earlier.
#
# One-line install (downloads and runs this script):
#   curl -fsSL https://raw.githubusercontent.com/shubhamwaghagkmf010/securedesk/main/automation/securedesk-update.sh -o securedesk-update.sh
#   sudo bash securedesk-update.sh
#
# Cron example (weekly, Monday 4am):
#   0 4 * * 1 /usr/bin/bash /opt/securedesk/securedesk-update.sh --yes --dir /opt/securedesk >> /opt/securedesk/update.log 2>&1
#
set -uo pipefail

VERSION="1.1"
DIR="${SECUREDESK_DIR:-}"
ASSUME_YES=0
CHECK_ONLY=0
DO_ROLLBACK=0
SKIP_FULL_PIPELINE=0
LOG="/tmp/securedesk-update-$(date +%Y%m%d-%H%M%S).log"
HEALTH_TRIES=20
HEALTH_INTERVAL=3
REPO_URL="https://github.com/shubhamwaghagkmf010/securedesk.git"

while [ $# -gt 0 ]; do
	case "$1" in
		--dir) DIR="$2"; shift 2;;
		--yes|-y) ASSUME_YES=1; shift;;
		--check-only) CHECK_ONLY=1; shift;;
		--rollback) DO_ROLLBACK=1; shift;;
		--skip-full-pipeline) SKIP_FULL_PIPELINE=1; shift;;
		--help|-h) sed -n '2,76p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
		*) echo "Unknown option: $1 (try --help)"; exit 2;;
	esac
done

TTY=0; [ -t 1 ] && TTY=1
if [ "$TTY" = 1 ]; then
	RST=$'\033[0m'; BLD=$'\033[1m'; DIM=$'\033[2m'
	GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
	RST=""; BLD=""; DIM=""; GRN=""; YEL=""; RED=""; CYN=""
fi
ts()    { date +%H:%M:%S; }
_emit() { printf '%s%s%s %s%s%s %s\n' "$DIM" "$(ts)" "$RST" "$2" "$1" "$RST" "$3"; printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$3" >>"$LOG"; }
ok()    { _emit "[ OK ]" "$GRN" "$*"; }
info()  { _emit "[INFO]" "$CYN" "$*"; }
warn()  { _emit "[WARN]" "$YEL" "$*"; }
fail()  { _emit "[FAIL]" "$RED" "$*"; }
step()  { printf '\n%s%sStep %s%s\n' "$BLD" "$CYN" "$*" "$RST"; printf '\n== Step %s\n' "$*" >>"$LOG"; }
die()   { fail "$*"; fail "Full log: $LOG"; exit 1; }

echo "SecureDesk updater v$VERSION - log: $LOG"

step "1/8  Checking this server"
SU=""
if [ "$(id -u)" != 0 ]; then
	if command -v sudo >/dev/null 2>&1; then SU="sudo"; warn "Not running as root - using sudo where needed"
	else warn "Not running as root and sudo is missing - this will likely fail if the install folder needs root"; fi
fi
command -v docker >/dev/null 2>&1 || die "docker not found on this server."
ok "Docker found: $(docker --version 2>/dev/null)"

step "2/8  Finding the install folder"
if [ -z "$DIR" ]; then
	for c in /appdata/securedesk "$PWD" "$PWD/securedesk" "$HOME/securedesk"; do
		if [ -f "$c/docker-compose.yml" ]; then DIR="$c"; break; fi
	done
fi
[ -n "$DIR" ] || die "Could not find a docker-compose.yml automatically. Pass --dir PATH."
[ -f "$DIR/docker-compose.yml" ] || die "$DIR/docker-compose.yml not found."
ok "Install folder: $DIR"
cd "$DIR" || die "Cannot enter $DIR"

COMPOSE="docker compose"
if ! $COMPOSE version >/dev/null 2>&1; then
	if [ -n "$SU" ] && $SU docker compose version >/dev/null 2>&1; then
		COMPOSE="$SU docker compose"
	else
		die "'docker compose' is not available (tried without and with sudo)."
	fi
fi

# Pin a service's CURRENT image under a fixed, non-floating local tag before
# touching anything. This matters because these compose files normally use
# floating tags (shubhamwaghagkmf010/securedesk:latest, caddy:2, ...) - simply
# restoring the old docker-compose.yml text on rollback would still say
# "image: ...:latest", which by then points at the broken image we just
# pulled, not the old one. Pinning the exact old image ID under its own tag
# first means rollback is never at the mercy of a floating tag moving again.
pin_tag_for() { printf 'securedesk-update-rollback:%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-')"; }

if [ "$DO_ROLLBACK" = 1 ]; then
	step "Rolling back to the last pinned images"
	LAST_PINNED="$(ls -t docker-compose.yml.rollback-pinned-* 2>/dev/null | head -1)"
	[ -n "$LAST_PINNED" ] || die "No rollback-pinned compose file found in $DIR (docker-compose.yml.rollback-pinned-*)."
	cp "$LAST_PINNED" docker-compose.yml
	ok "Restored $LAST_PINNED -> docker-compose.yml"
	$COMPOSE up -d >>"$LOG" 2>&1 || die "docker compose up -d failed - see $LOG"
	ok "Restarted on the previous (pinned) images."
	exit 0
fi

step "3/8  Running the full update-detection pipeline"
if [ "$SKIP_FULL_PIPELINE" = 1 ]; then
	info "--skip-full-pipeline given - skipping check-for-updates/scan/build-and-test."
else
	PIPELINE_HOME="${SECUREDESK_SRC_DIR:-$HOME/securedesk-src}"
	AUTOMATION_DIR=""
	if [ -f "$HOME/securedesk-auto-update/check-for-updates.sh" ]; then
		# Build server: the hand-maintained source tree + automation scripts
		# already exist locally - use them as-is, nothing to bootstrap.
		AUTOMATION_DIR="$HOME/securedesk-auto-update"
	else
		# Any other server: bootstrap (clone, or fast-forward pull if already
		# cloned) a plain copy of the public repo, which carries both the
		# source tree AND this automation/ folder together.
		if [ -d "$PIPELINE_HOME/.git" ]; then
			git -C "$PIPELINE_HOME" pull --ff-only >>"$LOG" 2>&1 || warn "Could not update $PIPELINE_HOME (network issue?) - using whatever is there."
		elif [ ! -d "$PIPELINE_HOME" ]; then
			if ! command -v git >/dev/null 2>&1; then
				if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
					info "Installing git (needed to bootstrap the update-detection pipeline) ..."
					apt-get update -y >>"$LOG" 2>&1 && apt-get install -y git >>"$LOG" 2>&1
				fi
			fi
			if command -v git >/dev/null 2>&1; then
				info "Cloning $REPO_URL -> $PIPELINE_HOME ..."
				git clone "$REPO_URL" "$PIPELINE_HOME" >>"$LOG" 2>&1 || warn "Clone failed (see $LOG) - skipping the full pipeline this run."
			else
				warn "git not available and could not be installed - skipping the full pipeline this run."
			fi
		fi
		[ -f "$PIPELINE_HOME/automation/check-for-updates.sh" ] && AUTOMATION_DIR="$PIPELINE_HOME/automation"
	fi

	if [ -n "$AUTOMATION_DIR" ]; then
		info "Running $AUTOMATION_DIR/check-for-updates.sh ..."
		if bash "$AUTOMATION_DIR/check-for-updates.sh" >>"$LOG" 2>&1; then
			ok "Base-image/.NET-channel check finished - see $LOG for detail."
		else
			warn "check-for-updates.sh reported an error (non-fatal) - see $LOG for detail."
		fi
		info "Running $AUTOMATION_DIR/scan-vulnerabilities.sh ..."
		if bash "$AUTOMATION_DIR/scan-vulnerabilities.sh" >>"$LOG" 2>&1; then
			ok "Vulnerability scan finished - see $LOG for detail."
		else
			warn "scan-vulnerabilities.sh reported an error (non-fatal) - see $LOG for detail."
		fi
		STATUS_FILE="$(eval echo "$(grep -E '^status_file:' "$AUTOMATION_DIR/auto-update-config.yaml" 2>/dev/null | sed -E 's/^[^:]+:[[:space:]]*"?//; s/"?[[:space:]]*$//')" 2>/dev/null)"
		[ -n "$STATUS_FILE" ] || STATUS_FILE="$HOME/securedesk-auto-update/status.json"
		if [ -f "$STATUS_FILE" ] && grep -q '"ready-for-review"' "$STATUS_FILE" 2>/dev/null; then
			CANDIDATE="$(grep -oE 'securedesk:auto-update-candidate-[0-9-]+' "$STATUS_FILE" | head -1)"
			ok "Pipeline built and fully tested a candidate: ${CANDIDATE:-see $STATUS_FILE}"
			ok "Nothing was deployed. To put it into production on THIS server, review it and run:"
			ok "  sudo bash $AUTOMATION_DIR/safe-deploy.sh ${CANDIDATE:-<candidate-tag-from-$STATUS_FILE>}"
		fi
	else
		warn "No source tree / automation scripts available for this server - skipping the full pipeline this run. The Docker-Hub-image pull below still runs normally."
	fi
fi

step "4/8  Recording the currently-running images"
# Compare by the IMAGE REFERENCE each service uses (docker compose config --images),
# not `docker compose images -q` - that reports the currently-RUNNING container's
# image, which does not change just because a newer one was pulled for the same tag.
IMAGE_REFS="$($COMPOSE config --images 2>/dev/null)"
[ -n "$IMAGE_REFS" ] || die "Could not determine the image(s) used by $DIR/docker-compose.yml."
ids_for_refs() { for r in $IMAGE_REFS; do docker image inspect "$r" --format '{{.Id}}' 2>/dev/null; done | sort; }
# ref|id pairs captured HERE, before any pull - re-inspecting a tag later
# would show the NEWLY pulled image, not the one we actually need to be
# able to roll back to.
OLD_MAP=""
for r in $IMAGE_REFS; do
	OLD_MAP="$OLD_MAP$r|$(docker image inspect "$r" --format '{{.Id}}' 2>/dev/null)
"
done
OLD_IDS="$(ids_for_refs)"
ok "Recorded $(echo "$IMAGE_REFS" | wc -w) tracked image(s): $(echo "$IMAGE_REFS" | tr '\n' ' ')"

step "5/8  Pulling the latest images"
$COMPOSE pull >>"$LOG" 2>&1 || die "docker compose pull failed - see $LOG for details (network / Docker Hub reachable?)"
NEW_IDS="$(ids_for_refs)"

if [ "$OLD_IDS" = "$NEW_IDS" ]; then
	ok "Already up to date - nothing changed, nothing restarted."
	exit 0
fi
ok "New image(s) pulled - an update is available."

if [ "$CHECK_ONLY" = 1 ]; then
	info "--check-only: stopping here without applying anything."
	info "Run again without --check-only to apply it safely."
	exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
	if [ -t 0 ]; then
		read -r -p "Apply this update now? [y/N] " REPLY
		case "$REPLY" in y|Y|yes|Yes) ;; *) info "Not applying - nothing was changed."; exit 0;; esac
	else
		warn "No terminal to ask for confirmation and --yes was not given - not applying. Re-run with --yes (e.g. from cron)."
		exit 0
	fi
fi

step "6/8  Backing up the compose file and the database"
TS="$(date +%Y%m%d-%H%M%S)"
COMPOSE_BACKUP="docker-compose.yml.update-backup-$TS"
cp docker-compose.yml "$COMPOSE_BACKUP"
ok "Backed up docker-compose.yml -> $COMPOSE_BACKUP"

PINNED_COMPOSE="docker-compose.yml.rollback-pinned-$TS"
cp docker-compose.yml "$PINNED_COMPOSE"
while IFS='|' read -r r old_id; do
	[ -z "$r" ] && continue
	if [ -z "$old_id" ]; then
		warn "No previous local image for $r - nothing to pin for rollback (first run for this image?)."
		continue
	fi
	TAG="$(pin_tag_for "$r")-$TS"
	docker tag "$old_id" "$TAG" >>"$LOG" 2>&1 || { warn "Could not tag $old_id as $TAG"; continue; }
	ESCAPED_REF="$(printf '%s\n' "$r" | sed 's/[.[\*^$/]/\\&/g')"
	sed -i "s#image:[[:space:]]*${ESCAPED_REF}\$#image: ${TAG}#" "$PINNED_COMPOSE"
done <<EOF
$OLD_MAP
EOF
ok "Pinned pre-update images for rollback -> $PINNED_COMPOSE"

DB_BACKUP_DIR="db-backups/$TS"
mkdir -p "$DB_BACKUP_DIR"
# Resolve the data volume from THIS project's own running "securedesk" container
# mount - never by searching volume names across the whole host, which could
# match an unrelated project's (or production's) volume on a host that runs
# more than one SecureDesk stack.
SECUREDESK_CONTAINER="$($COMPOSE ps -q securedesk 2>/dev/null | head -1)"
VOL=""
if [ -n "$SECUREDESK_CONTAINER" ]; then
	VOL="$(docker inspect "$SECUREDESK_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/remotely-data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
fi
if [ -n "$VOL" ]; then
	if docker run --rm -v "$VOL:/data:ro" -v "$PWD/$DB_BACKUP_DIR:/backup" alpine \
		sh -c 'cp /data/*.db /data/*.db-wal /data/*.db-shm /backup/ 2>/dev/null; cp /data/*.db /backup/ 2>/dev/null; true' >>"$LOG" 2>&1; then
		ok "Backed up the database -> $DB_BACKUP_DIR"
	else
		warn "Database backup reported an error - see $LOG. Continuing anyway (the compose backup still gives a rollback path)."
	fi
else
	warn "Could not find the securedesk-data volume - skipping database backup."
fi

step "7/8  Restarting with the new images"
$COMPOSE up -d >>"$LOG" 2>&1 || die "docker compose up -d failed - see $LOG"
ok "Restarted."

step "8/8  Health-checking"
HOST="localhost"
HTTPS_PORT="443"
if [ -f .env ]; then
	H="$(grep -E '^SECUREDESK_HOST=' .env | tail -1 | cut -d= -f2-)"; [ -n "$H" ] && HOST="$H"
	P="$(grep -E '^SECUREDESK_HTTPS_PORT=' .env | tail -1 | cut -d= -f2-)"; [ -n "$P" ] && HTTPS_PORT="$P"
fi
BASE="https://127.0.0.1:$HTTPS_PORT"
HEALTHY=0
for i in $(seq 1 "$HEALTH_TRIES"); do
	sleep "$HEALTH_INTERVAL"
	CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" 2>/dev/null)"
	info "attempt $i/$HEALTH_TRIES: $BASE/ -> $CODE"
	case "$CODE" in 2*|3*) HEALTHY=1; break;; esac
done

if [ "$HEALTHY" = 1 ]; then
	ok "SecureDesk is up and healthy on $BASE"
	ok "Previous images were NOT deleted. To go back: sudo bash $0 --dir \"$DIR\" --rollback"
	echo "Update applied successfully. See $LOG for details."
	exit 0
fi

fail "Health check failed after $((HEALTH_TRIES * HEALTH_INTERVAL))s - rolling back automatically"
cp "$PINNED_COMPOSE" docker-compose.yml
$COMPOSE up -d >>"$LOG" 2>&1
ok "Restored $PINNED_COMPOSE (pinned pre-update images) and restarted."
echo "AUTOMATIC ROLLBACK: the update failed its health check and was rolled back. See $LOG for details."
exit 1
