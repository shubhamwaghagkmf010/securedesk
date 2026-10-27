#!/usr/bin/env bash
#
# SecureDesk Auto-Update - Step 1: check for newer .NET / base-image patches.
#
# This script is READ-ONLY / DETECTION ONLY. It pulls base images to compare
# their digest against the last known one, and checks whether the pinned
# .NET channel is still "active" upstream. If a base-image patch is found,
# it hands off to auto-update-build-and-test.sh. It never touches the live
# production container and never edits application source.
#
# Intended to run from cron (weekly by default - see auto-update-config.yaml
# "schedule" field, which is documentation; set the actual cron cadence
# yourself, e.g.:
#   crontab -e
#   0 3 * * 1 /home/claude/securedesk-auto-update/check-for-updates.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HERE/auto-update-config.yaml"
# shellcheck source=lib/config.sh
source "$HERE/lib/config.sh"

LOG_DIR="$(eval echo "$(yaml_get log_dir '~/securedesk-auto-update/logs')")"
STATUS_FILE="$(eval echo "$(yaml_get status_file '~/securedesk-auto-update/status.json')")"
STATE_FILE="$(dirname "$STATUS_FILE")/known-image-ids.env"
mkdir -p "$LOG_DIR" "$(dirname "$STATUS_FILE")"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/check-$TS.log"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

write_status() {
	cat > "$STATUS_FILE" <<JSON
{
  "last_check": "$(date -Iseconds)",
  "state": "$1",
  "detail": "$2"
}
JSON
}

ENABLED="$(yaml_get auto_update_enabled true)"
if [ "$ENABLED" != "true" ]; then
	log "auto_update_enabled is false in config - auto-update is disabled, doing nothing."
	write_status "disabled" "auto_update_enabled=false in auto-update-config.yaml"
	exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
	log "ERROR: docker not found - cannot check for image updates."
	write_status "error" "docker command not found on this host"
	exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
	log "WARN: curl not found - the .NET EOL check will be skipped, base-image check will still run."
fi

[ -f "$STATE_FILE" ] && source "$STATE_FILE"

IMAGES_ENABLED="$(yaml_get docker_images_enabled true)"
UPDATED_IMAGES=()

if [ "$IMAGES_ENABLED" = "true" ]; then
	: > "$STATE_FILE.new"
	while IFS= read -r img; do
		[ -z "$img" ] && continue
		log "Checking $img ..."
		if ! docker pull "$img" >>"$LOG" 2>&1; then
			log "  WARN: could not pull $img (network issue?) - skipping this image this run."
			continue
		fi
		NEW_ID="$(docker inspect --format '{{.Id}}' "$img" 2>/dev/null)"
		VAR_NAME="IMGID_$(echo "$img" | tr -c 'A-Za-z0-9' '_' | tr '[:lower:]' '[:upper:]')"
		OLD_ID="$(eval echo "\${$VAR_NAME:-}")"
		if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$NEW_ID" ]; then
			log "  UPDATE FOUND: $img changed ($OLD_ID -> $NEW_ID)"
			UPDATED_IMAGES+=("$img")
		elif [ -z "$OLD_ID" ]; then
			log "  First time seeing $img - recording baseline ($NEW_ID), not treated as an update."
		else
			log "  No change."
		fi
		printf '%s=%s\n' "$VAR_NAME" "$NEW_ID" >> "$STATE_FILE.new"
	done < <(yaml_get_list docker_images)
	mv "$STATE_FILE.new" "$STATE_FILE"
fi

# Informational only: is the pinned .NET channel still an actively supported
# LTS release upstream? This NEVER triggers an automatic major-version change.
DOTNET_ENABLED="$(yaml_get dotnet_enabled true)"
EOL_NOTICE=""
if [ "$DOTNET_ENABLED" = "true" ] && command -v curl >/dev/null 2>&1; then
	CHANNEL="$(yaml_get dotnet_channel 8.0)"
	INFO="$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/dotnet/core/main/release-notes/releases-index.json" 2>/dev/null)"
	if [ -n "$INFO" ]; then
		PHASE="$(echo "$INFO" | grep -A12 "\"channel-version\": \"$CHANNEL\"" | grep -oE '"support-phase": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
		EOL_DATE="$(echo "$INFO" | grep -A12 "\"channel-version\": \"$CHANNEL\"" | grep -oE '"eol-date": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
		log ".NET $CHANNEL support-phase=${PHASE:-unknown}, eol-date=${EOL_DATE:-unknown}"
		if [ -n "$PHASE" ] && [ "$PHASE" != "active" ]; then
			EOL_NOTICE=".NET $CHANNEL support-phase is '$PHASE' (not 'active', eol-date=${EOL_DATE:-unknown}) - a major-version upgrade phase should be planned. This is a NOTICE only; nothing was changed automatically."
			log "NOTICE: $EOL_NOTICE"
		fi
	else
		log "WARN: could not fetch .NET release-notes index (network/parse issue) - skipping EOL check this run."
	fi
fi

if [ "${#UPDATED_IMAGES[@]}" -eq 0 ]; then
	log "No base-image patch updates found."
	write_status "up-to-date" "${EOL_NOTICE:-no base-image updates found}"
	exit 0
fi

log "Base-image updates found for: ${UPDATED_IMAGES[*]} - handing off to build+test."
write_status "update-detected" "Rebuilding/testing for: ${UPDATED_IMAGES[*]}"
exec "$HERE/auto-update-build-and-test.sh" "${UPDATED_IMAGES[@]}"
