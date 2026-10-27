#!/usr/bin/env bash
#
# SecureDesk Auto-Update - vulnerability scan (Trivy + dotnet CLI).
#
# READ-ONLY. Scans the CURRENT LIVE image and the canonical source tree's
# NuGet dependencies for known vulnerabilities. Never touches production -
# the live image is inspected by reference only (docker inspect / trivy
# image), the running container itself is never exec'd into or modified.
#
# Decision: a Critical/High finding with a known fix available triggers
# auto-update-build-and-test.sh (which only ever touches an isolated test
# instance - this script does not gain any extra production access by
# triggering it). Medium/Low findings are report-only.
#
# Uses the official Trivy Docker image (aquasec/trivy) rather than a host
# install - this VM's sudo requires an interactive TTY + password, so a
# host package install cannot be done non-interactively. The Docker image
# needs no host install at all and gives identical scan results.
#
# Intended to run from cron (daily - see auto-update-config.yaml
# "scan_frequency", which is documentation; set the actual cron cadence
# yourself):
#   0 2 * * * /home/claude/securedesk-auto-update/scan-vulnerabilities.sh >> /home/claude/securedesk-auto-update/logs/cron-scan.log 2>&1
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HERE/auto-update-config.yaml"
# shellcheck source=lib/config.sh
source "$HERE/lib/config.sh"

LOG_DIR="$(eval echo "$(yaml_get log_dir '~/securedesk-auto-update/logs')")"
STATUS_FILE="$(eval echo "$(yaml_get status_file '~/securedesk-auto-update/status.json')")"
SOURCE_DIR="$HOME/securedesk-ui-build"
TRIVY_CACHE_DIR="$HOME/securedesk-auto-update/trivy-cache"
mkdir -p "$LOG_DIR" "$TRIVY_CACHE_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/vulnerability-report-$TS.log"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

write_status() {
	# $1=state  $2=detail  $3=critical  $4=high  $5=medium  $6=low
	cat > "$STATUS_FILE" <<JSON
{
  "last_scan": "$(date -Iseconds)",
  "state": "$1",
  "detail": "$2",
  "vulnerabilities": {
    "critical": ${3:-0},
    "high": ${4:-0},
    "medium": ${5:-0},
    "low": ${6:-0}
  },
  "report": "$LOG"
}
JSON
}

ENABLED="$(yaml_get auto_update_enabled true)"
if [ "$ENABLED" != "true" ]; then
	log "auto_update_enabled is false in config - vulnerability scanning is disabled, doing nothing."
	write_status "disabled" "auto_update_enabled=false in auto-update-config.yaml" 0 0 0 0
	exit 0
fi

TRIVY_ENABLED="$(yaml_get trivy_enabled true)"
if [ "$TRIVY_ENABLED" != "true" ]; then
	log "trivy_enabled is false in config - skipping image scan (NuGet scan still runs)."
fi

if ! command -v docker >/dev/null 2>&1; then
	log "ERROR: docker not found - cannot scan."
	write_status "error" "docker command not found on this host" 0 0 0 0
	exit 1
fi

CRIT_COUNT=0
HIGH_COUNT=0
MED_COUNT=0
LOW_COUNT=0
FIXABLE_FINDINGS=()   # entries like "CVE-xxxx-yyyy|package|installed|fixed"

# ---------------------------------------------------------------------------
# 1) Scan the current LIVE image with Trivy (image reference only - this
#    reads image layers, it does not touch the running container).
# ---------------------------------------------------------------------------
if [ "$TRIVY_ENABLED" = "true" ]; then
	LIVE_IMAGE="$(docker inspect securedesk-securedesk-1 --format '{{.Config.Image}}' 2>/dev/null)"
	if [ -z "$LIVE_IMAGE" ]; then
		log "WARN: could not determine the live image reference (is securedesk-securedesk-1 running?) - skipping image scan."
	else
		log "--- Trivy scan: live image ($LIVE_IMAGE) ---"
		IMAGE_JSON="$TRIVY_CACHE_DIR/image-scan-$TS.json"
		if docker run --rm \
			-v /var/run/docker.sock:/var/run/docker.sock \
			-v "$TRIVY_CACHE_DIR:/root/.cache/" \
			aquasec/trivy:latest image \
			--severity CRITICAL,HIGH,MEDIUM,LOW \
			--scanners vuln \
			-f json -o "/root/.cache/$(basename "$IMAGE_JSON")" \
			"$LIVE_IMAGE" >>"$LOG" 2>&1; then

			if [ -f "$IMAGE_JSON" ]; then
				while IFS='|' read -r sev cve pkg installed fixed; do
					[ -z "$sev" ] && continue
					case "$sev" in
						CRITICAL) CRIT_COUNT=$((CRIT_COUNT+1)) ;;
						HIGH)      HIGH_COUNT=$((HIGH_COUNT+1)) ;;
						MEDIUM)    MED_COUNT=$((MED_COUNT+1)) ;;
						LOW)       LOW_COUNT=$((LOW_COUNT+1)) ;;
					esac
					log "  [$sev] $cve  pkg=$pkg installed=$installed fixed=${fixed:-none}"
					if [ -n "$fixed" ] && [ "$fixed" != "null" ] && { [ "$sev" = "CRITICAL" ] || [ "$sev" = "HIGH" ]; }; then
						FIXABLE_FINDINGS+=("$cve|$pkg|$installed|$fixed")
					fi
				done < <(docker run --rm -v "$TRIVY_CACHE_DIR:/root/.cache/" aquasec/trivy:latest convert --format template --template "$(cat "$HERE/lib/trivy-vuln.tpl")" "/root/.cache/$(basename "$IMAGE_JSON")" 2>>"$LOG")
			fi
			log "Image scan complete: ${CRIT_COUNT} critical, ${HIGH_COUNT} high, ${MED_COUNT} medium, ${LOW_COUNT} low."
		else
			log "WARN: Trivy image scan failed/timed out - see $LOG for details. Continuing with NuGet scan."
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 2) Scan NuGet dependencies in the canonical source tree.
# ---------------------------------------------------------------------------
NUGET_CRIT=0
NUGET_HIGH=0
if [ -d "$SOURCE_DIR/Server" ]; then
	log "--- dotnet list package --vulnerable: $SOURCE_DIR/Server ---"
	NUGET_OUT="$(docker run --rm \
		-v "$SOURCE_DIR:/src" -w /src/Server \
		mcr.microsoft.com/dotnet/sdk:8.0 \
		sh -c 'dotnet restore --nologo >/dev/null 2>&1; dotnet list package --vulnerable --include-transitive' 2>&1)"
	echo "$NUGET_OUT" >> "$LOG"
	if echo "$NUGET_OUT" | grep -qi 'has no vulnerable packages'; then
		log "No vulnerable NuGet packages found."
	else
		NUGET_CRIT=$(echo "$NUGET_OUT" | grep -ci 'Critical' || true)
		NUGET_HIGH=$(echo "$NUGET_OUT" | grep -ci '   High' || true)
		log "NuGet scan found potential findings - see log above for package/version detail (counts are approximate line-matches, review the raw output)."
	fi
else
	log "WARN: $SOURCE_DIR/Server not found - skipping NuGet scan."
fi

CRIT_COUNT=$((CRIT_COUNT + NUGET_CRIT))
HIGH_COUNT=$((HIGH_COUNT + NUGET_HIGH))

# ---------------------------------------------------------------------------
# 3) Decide: Critical/High with a fix available -> trigger build+test.
#    Medium/Low -> report only.
# ---------------------------------------------------------------------------
AUTO_TRIGGER_LEVEL="$(yaml_get vulnerability_severity_auto_trigger high)"

log "=== Scan summary: critical=$CRIT_COUNT high=$HIGH_COUNT medium=$MED_COUNT low=$LOW_COUNT ==="

if [ "${#FIXABLE_FINDINGS[@]}" -eq 0 ]; then
	log "No Critical/High finding with a known fix - nothing to rebuild for. (Medium/Low findings, if any, are logged above for the weekly report.)"
	write_status "scanned" "critical=$CRIT_COUNT high=$HIGH_COUNT medium=$MED_COUNT low=$LOW_COUNT - no fixable Critical/High finding" \
		"$CRIT_COUNT" "$HIGH_COUNT" "$MED_COUNT" "$LOW_COUNT"
	exit 0
fi

if [ "$AUTO_TRIGGER_LEVEL" = "none" ]; then
	log "vulnerability_severity_auto_trigger=none - found fixable issues but config says report-only. NOT triggering a rebuild."
	write_status "scanned" "Fixable findings present but auto-trigger disabled: ${FIXABLE_FINDINGS[*]}" \
		"$CRIT_COUNT" "$HIGH_COUNT" "$MED_COUNT" "$LOW_COUNT"
	exit 0
fi

TRIGGER="${FIXABLE_FINDINGS[0]}"
log "Fixable Critical/High finding(s): ${FIXABLE_FINDINGS[*]}"
log "Triggering auto-update-build-and-test.sh (CVE context: $TRIGGER) ..."
write_status "vulnerability-triggered-rebuild" "Rebuilding to address: ${FIXABLE_FINDINGS[*]}" \
	"$CRIT_COUNT" "$HIGH_COUNT" "$MED_COUNT" "$LOW_COUNT"

exec "$HERE/auto-update-build-and-test.sh" "--cve=$TRIGGER"
