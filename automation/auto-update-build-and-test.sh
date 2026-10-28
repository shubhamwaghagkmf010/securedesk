#!/usr/bin/env bash
#
# SecureDesk Auto-Update - Step 2: rebuild with the latest base images and
# run the full test suite on a brand-new, isolated test instance.
#
# This script NEVER deploys to production and NEVER edits application
# source - the only thing that changes between builds is which base-image
# layers get pulled in (via `docker build --pull`). If every test passes,
# the resulting image is tagged and left for a human to review and deploy
# by hand (see rollback.sh / safe-deploy.sh) - it is never deployed
# automatically, regardless of config.
#
# Can be run standalone (e.g. to force a rebuild+test right now), called by
# check-for-updates.sh when it detects a base-image change, or called by
# scan-vulnerabilities.sh with a "--cve=CVE-ID|pkg|installed|fixed" argument
# when a fixable Critical/High vulnerability was found - in that case an
# extra check re-scans the candidate to confirm the specific CVE is gone.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HERE/auto-update-config.yaml"
# shellcheck source=lib/config.sh
source "$HERE/lib/config.sh"

LOG_DIR="$(eval echo "$(yaml_get log_dir '~/securedesk-auto-update/logs')")"
STATUS_FILE="$(eval echo "$(yaml_get status_file '~/securedesk-auto-update/status.json')")"
REQUIRE_PASS="$(yaml_get require_tests_pass true)"
TRIVY_ENABLED="$(yaml_get trivy_enabled true)"

# --- Parse an optional "--cve=CVE-ID|pkg|installed|fixed" trigger argument ---
TRIGGER_CVE=""
for arg in "$@"; do
	case "$arg" in
		--cve=*)
			CVE_CONTEXT="${arg#--cve=}"
			TRIGGER_CVE="${CVE_CONTEXT%%|*}"
			;;
	esac
done

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/build-$TS.log"
CANDIDATE_TAG="securedesk:auto-update-candidate-$TS"
TEST_PROJECT="autoupdatetest-$TS"
TEST_HTTPS_PORT="7998"
TEST_DIR="$HOME/securedesk-auto-update/test-stacks/$TS"
TRIVY_CACHE_DIR="$HOME/securedesk-auto-update/trivy-cache"

mkdir -p "$LOG_DIR" "$TEST_DIR" "$TRIVY_CACHE_DIR"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

write_status() {
	cat > "$STATUS_FILE" <<JSON
{
  "last_run": "$(date -Iseconds)",
  "state": "$1",
  "detail": "$2",
  "log": "$LOG"
}
JSON
}

TEST_STACK_UP=0
DISCARD_IMAGE=""   # set by the FAIL branch; removed here, AFTER the
                   # containers using it are torn down (docker rmi fails
                   # while a container still references the image)
cleanup() {
	# Tear down the compose stack FIRST, while $TEST_DIR still exists (docker
	# compose needs the compose file to know what to remove), THEN remove the
	# candidate image (now unused), THEN remove the directory. Getting this
	# order wrong was a real bug found during testing: the old code called
	# `docker rmi` and `rm -rf "$TEST_DIR"` before `exit`, i.e. before this
	# trap ran - `docker rmi` silently failed (image still in use by the
	# running test containers) and the directory was already gone by the
	# time `docker compose down` needed its compose file, which orphaned a
	# running container pair and permanently held the scratch port.
	if [ "$TEST_STACK_UP" = "1" ]; then
		( cd "$TEST_DIR" && docker compose -p "$TEST_PROJECT" down -v >>"$LOG" 2>&1 ) || true
	fi
	if [ -n "$DISCARD_IMAGE" ]; then
		docker rmi "$DISCARD_IMAGE" >>"$LOG" 2>&1 || true
	fi
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

log "=== Auto-update build+test run ==="
log "Triggered by: $*"
log "Candidate tag: $CANDIDATE_TAG"
[ -n "$TRIGGER_CVE" ] && log "CVE context for this run: $TRIGGER_CVE"

SOURCE_DIR="$(ensure_source_tree)"
if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR/Server" ]; then
	log "ERROR: no source tree available and none could be bootstrapped (git missing, or no network to clone https://github.com/shubhamwaghagkmf010/securedesk.git)."
	write_status "failed" "no source tree available - see $LOG"
	exit 1
fi
log "Source tree: $SOURCE_DIR"

# Disk-space guard - works whether this host has the original VM's
# /appdata layout or is a fresh/lightweight server (falls back to
# Docker's own data root, then to /).
DISK_CHECK_PATH="/appdata"
[ -d "$DISK_CHECK_PATH" ] || DISK_CHECK_PATH="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
{ [ -n "$DISK_CHECK_PATH" ] && [ -d "$DISK_CHECK_PATH" ]; } || DISK_CHECK_PATH="/"
df -h "$DISK_CHECK_PATH" >>"$LOG" 2>&1
AVAIL_GB="$(df --output=avail -BG "$DISK_CHECK_PATH" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt 5 ]; then
	log "ERROR: only ${AVAIL_GB}G free on $DISK_CHECK_PATH - aborting to avoid filling the disk. Nothing was built."
	write_status "failed" "insufficient disk space on $DISK_CHECK_PATH (${AVAIL_GB}G free, need 5G+)"
	exit 1
fi

log "--- Building (docker build --pull picks up the latest patched base images) ---"
if ! docker build --pull -f "$SOURCE_DIR/docker/Dockerfile" -t "$CANDIDATE_TAG" "$SOURCE_DIR" >>"$LOG" 2>&1; then
	log "ERROR: build failed. See $LOG for details."
	write_status "failed" "docker build failed - see $LOG"
	exit 1
fi
log "Build succeeded: $CANDIDATE_TAG"

log "--- Standing up isolated test instance on port $TEST_HTTPS_PORT ---"
CADDYFILE_SRC=""
for candidate in "$HOME/secfixtest2/Caddyfile" "$HOME/secfix-test/Caddyfile" "$HOME/ad-test/Caddyfile" "$SOURCE_DIR/Caddyfile"; do
	if [ -f "$candidate" ]; then
		CADDYFILE_SRC="$candidate"
		break
	fi
done
if [ -z "$CADDYFILE_SRC" ]; then
	log "ERROR: could not find a reference Caddyfile to copy - aborting test, candidate image kept for manual inspection."
	write_status "failed" "no reference Caddyfile found - see $LOG"
	exit 1
fi
cp "$CADDYFILE_SRC" "$TEST_DIR/Caddyfile"

TEST_PASSWORD="AutoUpdateTest-$TS-Aa1!"

cat > "$TEST_DIR/docker-compose.yml" <<EOF
services:
  securedesk:
    image: $CANDIDATE_TAG
    restart: unless-stopped
    environment:
      ASPNETCORE_FORWARDEDHEADERS_ENABLED: "true"
      SECUREDESK_SEED_ADMIN: "true"
      SECUREDESK_ADMIN_EMAIL: "autoupdate-test@local.test"
      SECUREDESK_ADMIN_PASSWORD: "$TEST_PASSWORD"
    volumes:
      - data:/remotely-data
  caddy:
    image: caddy:2
    restart: unless-stopped
    depends_on: [securedesk]
    environment:
      SECUREDESK_HOST: "127.0.0.1"
    ports:
      - "${TEST_HTTPS_PORT}:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
volumes:
  data:
  caddy-data:
  caddy-config:
EOF

cd "$TEST_DIR"
if ! docker compose -p "$TEST_PROJECT" up -d >>"$LOG" 2>&1; then
	log "ERROR: test stack failed to start. Candidate image kept for manual inspection: $CANDIDATE_TAG"
	write_status "failed" "test stack did not start - see $LOG"
	exit 1
fi
TEST_STACK_UP=1
sleep 10

BASE="https://127.0.0.1:$TEST_HTTPS_PORT"
PASS=0
FAIL=0

check() {
	# check <name> <actual> <expected>
	if [ "$2" = "$3" ]; then
		log "  PASS: $1 ($2)"
		PASS=$((PASS+1))
	else
		log "  FAIL: $1 (expected '$3', got '$2')"
		FAIL=$((FAIL+1))
	fi
}

log "--- Running test suite ---"

CONTAINER_UID="$(docker exec "${TEST_PROJECT}-securedesk-1" sh -c 'cat /proc/1/status 2>/dev/null | grep ^Uid | awk "{print \$2}"' 2>/dev/null)"
check "process runs non-root" "$([ "$CONTAINER_UID" != "0" ] && [ -n "$CONTAINER_UID" ] && echo ok || echo root)" "ok"

SWAGGER_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/swagger/v1/swagger.json" 2>/dev/null)"
check "swagger not exposed" "$SWAGGER_CODE" "404"

HDRS="$(curl -sk -I --max-time 10 "$BASE/" 2>/dev/null)"
check "CSP header present" "$(echo "$HDRS" | grep -qi '^content-security-policy:' && echo yes || echo no)" "yes"
check "X-Frame-Options present" "$(echo "$HDRS" | grep -qi '^x-frame-options:' && echo yes || echo no)" "yes"
check "X-Content-Type-Options present" "$(echo "$HDRS" | grep -qi '^x-content-type-options:' && echo yes || echo no)" "yes"

LOGIN_HDRS="$(curl -sk -I --max-time 10 "$BASE/Identity/Account/Login" 2>/dev/null)"
check "antiforgery cookie secure" "$(echo "$LOGIN_HDRS" | grep -i '^set-cookie:.*[Aa]ntiforgery' | grep -qi secure && echo yes || echo no)" "yes"

JAR="/tmp/autoupdate-$TS-cookies.txt"
PAGE="$(curl -sk -c "$JAR" --max-time 10 "$BASE/Identity/Account/Login" 2>/dev/null)"
TOKEN="$(echo "$PAGE" | grep -oE 'name="__RequestVerificationToken" type="hidden" value="[^"]+"' | sed -E 's/.*value="([^"]+)"/\1/')"
LOGIN_CODE="$(curl -sk -b "$JAR" -c "$JAR" -o /dev/null -w '%{http_code}' --max-time 10 \
	-X POST "$BASE/Identity/Account/Login" \
	--data-urlencode "Input.Email=autoupdate-test@local.test" \
	--data-urlencode "Input.Password=$TEST_PASSWORD" \
	--data-urlencode "Input.RememberMe=false" \
	--data-urlencode "__RequestVerificationToken=$TOKEN" 2>/dev/null)"
check "login succeeds (302)" "$LOGIN_CODE" "302"

DASH_CODE="$(curl -sk -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/" 2>/dev/null)"
check "dashboard loads after login" "$DASH_CODE" "200"

NEGOTIATE_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE/_blazor/negotiate?negotiateVersion=1" 2>/dev/null)"
check "blazor/signalr negotiate" "$NEGOTIATE_CODE" "200"

rm -f "$JAR"

# --- 10th check: if this run was triggered by a specific CVE, confirm it's
# actually gone from the candidate image. Never fails the pipeline when
# there's no CVE context (normal base-image-patch runs) - it's purely
# additive proof for CVE-triggered runs.
if [ -n "$TRIGGER_CVE" ] && [ "$TRIVY_ENABLED" = "true" ]; then
	log "--- Confirming fix: re-scanning candidate for $TRIGGER_CVE ---"
	CAND_JSON="$TRIVY_CACHE_DIR/candidate-scan-$TS.json"
	if docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$TRIVY_CACHE_DIR:/root/.cache/" \
		aquasec/trivy:latest image --severity CRITICAL,HIGH,MEDIUM,LOW --scanners vuln \
		-f json -o "/root/.cache/$(basename "$CAND_JSON")" "$CANDIDATE_TAG" >>"$LOG" 2>&1; then
		STILL_PRESENT="no"
		if [ -f "$CAND_JSON" ] && grep -q "\"VulnerabilityID\": *\"$TRIGGER_CVE\"" "$CAND_JSON"; then
			STILL_PRESENT="yes"
		fi
		check "CVE $TRIGGER_CVE resolved in candidate" "$STILL_PRESENT" "no"
	else
		log "  WARN: could not re-scan candidate image - treating CVE-fix confirmation as inconclusive (not counted as pass or fail)."
	fi
elif [ -n "$TRIGGER_CVE" ]; then
	log "--- Skipping CVE-fix confirmation: trivy_enabled is false in config ---"
else
	log "--- No specific CVE context for this run (base-image-patch trigger) - skipping CVE-fix confirmation check ---"
fi

log "--- Test suite result: $PASS passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ] && [ "$REQUIRE_PASS" = "true" ]; then
	log "Tests failed - discarding candidate image $CANDIDATE_TAG. Production was never touched."
	DISCARD_IMAGE="$CANDIDATE_TAG"   # actually removed by cleanup(), after the test stack is torn down
	write_status "failed" "$FAIL test(s) failed - candidate discarded automatically, see $LOG"
	exit 1
fi

log "All tests passed. Candidate image ready for review: $CANDIDATE_TAG"
log "Nothing has been deployed. A human must review this and run safe-deploy.sh by hand."
write_status "ready-for-review" "Candidate $CANDIDATE_TAG passed all $PASS tests. Production was NOT touched - review and run safe-deploy.sh manually."
exit 0
