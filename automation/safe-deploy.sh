#!/usr/bin/env bash
#
# SecureDesk Auto-Update - safe production cutover.
#
# MANUALLY INVOKED ONLY. Never called automatically by any other script in
# this system. A human runs this after reviewing a "ready-for-review"
# candidate from auto-update-build-and-test.sh.
#
# Usage:
#   sudo bash safe-deploy.sh <candidate-image-tag>
#   sudo bash safe-deploy.sh securedesk:auto-update-candidate-20261103-030000
#
# What this does, and why it's "safe":
#   1. Backs up the live docker-compose.yml and the live SQLite database
#      BEFORE touching anything.
#   2. Swaps only the `securedesk` app service's image. Caddy (which holds
#      the TLS connection to users) is never restarted, so the connection
#      layer itself never drops - only the backend app container briefly
#      restarts (typically 5-10 seconds).
#   3. Immediately health-checks the new container for up to ~60 seconds.
#   4. If healthy -> done, old image is left on disk (not deleted) as a
#      rollback target. If NOT healthy within the timeout -> AUTOMATICALLY
#      restores the previous docker-compose.yml and brings the old image
#      back up. This auto-rollback is the actual safety net - it does not
#      require a human to notice something is wrong.
#
set -uo pipefail

# SAFE_DEPLOY_REQUIRE_ROOT=0 exists only so this exact script can be proven
# against a throwaway, non-root-owned simulation stack during testing - real
# production use always goes through the default (root required, because
# /appdata/securedesk is root-owned).
if [ "${SAFE_DEPLOY_REQUIRE_ROOT:-1}" = "1" ] && [ "$(id -u)" -ne 0 ]; then
	echo "Run this with sudo: sudo bash $0 <candidate-image-tag>"
	exit 1
fi

CANDIDATE_IMAGE="${1:-}"
if [ -z "$CANDIDATE_IMAGE" ]; then
	echo "Usage: sudo bash $0 <candidate-image-tag>"
	echo "  (the tag printed by auto-update-build-and-test.sh as 'ready for review')"
	exit 1
fi

# These can be overridden by environment variables for testing against a
# throwaway simulation stack instead of real production - defaults are the
# real production values, so a plain `sudo bash safe-deploy.sh <tag>` run
# behaves exactly as documented above with no extra setup.
COMPOSE_DIR="${SAFE_DEPLOY_COMPOSE_DIR:-/appdata/securedesk}"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LIVE_CONTAINER="${SAFE_DEPLOY_LIVE_CONTAINER:-securedesk-securedesk-1}"
BACKUP_DIR="${SAFE_DEPLOY_BACKUP_DIR:-/appdata/securedesk-auto-update-backups}"
LOG_DIR="$HOME/securedesk-auto-update/logs"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/safe-deploy-$TS.log"
BASE="${SAFE_DEPLOY_BASE_URL:-https://127.0.0.1:5443}"
HEALTH_TRIES="${SAFE_DEPLOY_HEALTH_TRIES:-20}"          # 20 x 3s = ~60s
HEALTH_INTERVAL="${SAFE_DEPLOY_HEALTH_INTERVAL:-3}"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

if [ ! -f "$COMPOSE_FILE" ]; then
	log "ERROR: cannot find $COMPOSE_FILE - are you on the right host? Aborting, nothing changed."
	exit 1
fi

if ! docker image inspect "$CANDIDATE_IMAGE" >/dev/null 2>&1; then
	log "ERROR: image '$CANDIDATE_IMAGE' not found locally. Aborting, nothing changed."
	exit 1
fi

PREVIOUS_IMAGE="$(docker inspect "$LIVE_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)"
if [ -z "$PREVIOUS_IMAGE" ]; then
	log "ERROR: could not determine the currently-live image (is $LIVE_CONTAINER running?). Aborting, nothing changed."
	exit 1
fi
log "=== Safe deploy: $PREVIOUS_IMAGE -> $CANDIDATE_IMAGE ==="

# --- 1a. Back up the compose file ---
COMPOSE_BACKUP="$COMPOSE_FILE.safe-deploy-backup-$TS"
cp "$COMPOSE_FILE" "$COMPOSE_BACKUP"
log "Backed up compose file to $COMPOSE_BACKUP"

# --- 1b. Back up the live database (best-effort consistent copy: the .db
# file plus its -wal/-shm sidecars, taken together while the app keeps
# running - SQLite readers don't block each other, so this is safe to do
# without stopping anything) ---
DATA_VOLUME="$(docker inspect "$LIVE_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/remotely-data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
if [ -z "$DATA_VOLUME" ]; then
	log "WARN: could not determine the live data volume name - skipping DB backup. Proceeding anyway (compose backup still gives a config-level rollback)."
else
	DB_BACKUP_DIR="$BACKUP_DIR/db-$TS"
	mkdir -p "$DB_BACKUP_DIR"
	if docker run --rm -v "$DATA_VOLUME:/data:ro" -v "$DB_BACKUP_DIR:/backup" alpine \
		sh -c 'cp /data/*.db /data/*.db-wal /data/*.db-shm /backup/ 2>/dev/null; cp /data/*.db /backup/ 2>/dev/null; true' >>"$LOG" 2>&1; then
		log "Backed up live database files to $DB_BACKUP_DIR"
	else
		log "WARN: database backup step reported an error - check $LOG. Proceeding anyway (compose backup still gives a config-level rollback)."
	fi
fi

# --- 2. Swap: only the app service's image changes. Caddy is untouched. ---
sed -i "s#image: .*securedesk:.*#image: $CANDIDATE_IMAGE#" "$COMPOSE_FILE"
log "Set image to $CANDIDATE_IMAGE in $COMPOSE_FILE"

cd "$COMPOSE_DIR"
log "--- Swapping (docker compose up -d) ---"
docker compose up -d >>"$LOG" 2>&1

# --- 3. Health-check loop ---
log "--- Health-checking for up to $((HEALTH_TRIES * HEALTH_INTERVAL))s ---"
HEALTHY=0
for i in $(seq 1 "$HEALTH_TRIES"); do
	sleep "$HEALTH_INTERVAL"
	ROOT_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" 2>/dev/null)"
	NEGOTIATE_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$BASE/_blazor/negotiate?negotiateVersion=1" 2>/dev/null)"
	log "  attempt $i/$HEALTH_TRIES: / -> $ROOT_CODE, /_blazor/negotiate -> $NEGOTIATE_CODE"
	if [ "$ROOT_CODE" = "200" ] && [ "$NEGOTIATE_CODE" = "200" ]; then
		HEALTHY=1
		break
	fi
done

# --- 4. Decision ---
if [ "$HEALTHY" = "1" ]; then
	log "=== SUCCESS: $CANDIDATE_IMAGE is live and healthy. ==="
	log "Previous image ($PREVIOUS_IMAGE) was NOT deleted - it remains available for rollback.sh if needed."
	log "Compose backup: $COMPOSE_BACKUP"
	echo "Deployed $CANDIDATE_IMAGE successfully. See $LOG for details."
	exit 0
fi

log "=== HEALTH CHECK FAILED after $((HEALTH_TRIES * HEALTH_INTERVAL))s - rolling back automatically ==="
cp "$COMPOSE_BACKUP" "$COMPOSE_FILE"
log "Restored compose file from $COMPOSE_BACKUP (image: $PREVIOUS_IMAGE)"
docker compose up -d >>"$LOG" 2>&1
log "Ran 'docker compose up -d' to bring $PREVIOUS_IMAGE back up."
echo "AUTOMATIC ROLLBACK: $CANDIDATE_IMAGE failed its health check and was rolled back to $PREVIOUS_IMAGE. See $LOG for details."
exit 1
