#!/bin/bash
# SecureDesk: switch on Active Directory login.
#
#   1. copy ad/ad-config.env.example to ad/ad-config.env and ad/ad-users.txt.example to ad/ad-users.txt
#   2. fill in the two files
#   3. run:  ./apply-ad.sh
#
# The script checks the files, tests the connection and the service account with the same code the
# login uses, and only when everything passes it sets AD_ENABLED=true and restarts SecureDesk.
# If anything fails, AD login stays as it was and the normal (local) login keeps working.
#
#   ./apply-ad.sh --test-login USER   also tests one user's password (asked silently, never stored)
#   ./apply-ad.sh --allow-no-2fa      needed only to accept AD_REQUIRE_2FA=false (typing YES is required)

cd "$(dirname "$0")" || exit 1
CONF=ad/ad-config.env
USERS=ad/ad-users.txt
LOG=ad/ad-apply.log
ALLOW_NO_2FA=0
TEST_USER=""

while [ $# -gt 0 ]; do
	case "$1" in
		--allow-no-2fa) ALLOW_NO_2FA=1 ;;
		--test-login) shift; TEST_USER="${1:-}" ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1"; exit 2 ;;
	esac
	shift
done

say() { echo "$*" | tee -a "$LOG"; }
fail() { say "FAILED: $*"; say "AD login was NOT changed. Local login keeps working."; exit 1; }
get() { grep -E "^$1=" "$CONF" | tail -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/'; }

mkdir -p ad
touch "$LOG" && chmod 600 "$LOG" 2>/dev/null
say "=== apply-ad.sh $(date '+%F %T') ==="

[ -f "$CONF" ] || fail "$CONF not found. Copy ad/ad-config.env.example to $CONF and fill it in."
[ -f "$USERS" ] || fail "$USERS not found. Copy ad/ad-users.txt.example to $USERS and list the allowed usernames."

# 1. required values (the password itself is never printed)
for key in AD_SERVER AD_BASE_DN AD_SERVICE_ACCOUNT AD_SERVICE_PASSWORD; do
	[ -n "$(get $key)" ] || fail "$key is empty in $CONF"
done
grep -qvE '^[[:space:]]*(#|$)' "$USERS" || fail "$USERS has no usernames"
say "OK  values filled in, $(grep -cvE '^[[:space:]]*(#|$)' "$USERS") user(s) in $USERS"

# 2. 2FA is a security setting: this script never turns it off by itself
REQ2FA="$(get AD_REQUIRE_2FA)"
if [ "${REQ2FA,,}" = "false" ]; then
	[ "$ALLOW_NO_2FA" = 1 ] || fail "AD_REQUIRE_2FA=false in $CONF. Set it to true, or run again with --allow-no-2fa to accept it."
	read -r -p "AD users would log in WITHOUT two-factor. Type YES to accept: " ans
	[ "$ans" = "YES" ] || fail "not confirmed"
	say "WARNING  2FA for AD users is OFF (accepted by the server administrator)"
else
	say "OK  2FA is required for AD users"
fi

# 3. file permissions: the file holds the service account password
chmod 600 "$CONF" 2>/dev/null; chmod 640 "$USERS" 2>/dev/null
say "OK  file permissions set"

# 4. can the server be reached at all?
SERVER="$(get AD_SERVER)"; PORT="$(get AD_PORT)"
if [ -z "$PORT" ]; then if [ "$(get AD_USE_LDAPS)" = "false" ]; then PORT=389; else PORT=636; fi; fi
if timeout 6 bash -c "echo > /dev/tcp/$SERVER/$PORT" 2>/dev/null; then
	say "OK  $SERVER:$PORT is reachable from this machine"
else
	say "NOTE  $SERVER:$PORT is not reachable from this machine itself; the test from inside the SecureDesk container below decides"
fi

# 5. service account and base DN, tested by the SecureDesk server code itself
ENVARGS=()
if [ -n "$TEST_USER" ]; then
	read -r -s -p "Password of $TEST_USER (not shown, not stored): " AD_TEST_PASSWORD; echo
	export AD_TEST_USER="$TEST_USER" AD_TEST_PASSWORD
	ENVARGS=(-e AD_TEST_USER -e AD_TEST_PASSWORD)
fi
OUT="$(docker compose run --rm --no-deps -T "${ENVARGS[@]}" --entrypoint /usr/bin/dotnet securedesk /var/www/remotely/Remotely_Server.dll --ad-test 2>&1)"
RC=$?
unset AD_TEST_PASSWORD
echo "$OUT" | grep -E "^(AD_ENABLED|OK|FAIL|Test login)" | tee -a "$LOG"
[ $RC -eq 0 ] || fail "the directory test did not pass (see the lines above)"

# 6. switch on
if grep -qE '^AD_ENABLED=' "$CONF"; then
	sed -i 's/^AD_ENABLED=.*/AD_ENABLED=true/' "$CONF"
else
	echo "AD_ENABLED=true" >> "$CONF"
fi
say "OK  AD_ENABLED=true"
docker compose restart securedesk >/dev/null 2>&1 || fail "could not restart the securedesk container (run: docker compose restart securedesk)"
for i in $(seq 1 40); do
	docker compose exec -T securedesk wget -q -O /dev/null http://127.0.0.1:5000/Identity/Account/Login 2>/dev/null && { say "OK  SecureDesk is back up"; break; }
	sleep 3
done
say "Done. Active Directory login is ON. The local administrator account still works."
say "To switch it off again: set AD_ENABLED=false in $CONF and run: docker compose restart securedesk"
