#!/bin/bash
# SecureDesk container entrypoint.
#  0. if started as root (e.g. an older data volume still owned by root), fixes ownership of the
#     data volume then re-execs itself as the non-root "securedesk" user,
#  1. keeps appsettings.json in the data volume (so it survives container re-creation),
#  2. starts the web app,
#  3. on the very first start creates the default administrator account (see README, "Default login").

ServerDir=/var/www/remotely
RemotelyData=/remotely-data
AppSettingsVolume=$RemotelyData/appsettings.json
AppSettingsWww=$ServerDir/appsettings.json
SeedMarker=$RemotelyData/.securedesk-admin-seeded

if [ "$(id -u)" = "0" ]; then
	chown -R securedesk:securedesk "$RemotelyData" 2>/dev/null || true
	exec gosu securedesk "$0" "$@"
fi

echo "Entered main script."

if [ ! -f "$AppSettingsVolume" ]; then
	echo "Copying appsettings.json to volume."
	cp "$AppSettingsWww" "$AppSettingsVolume"
fi

if [ -e "$AppSettingsWww" ] || [ -L "$AppSettingsWww" ]; then
	rm -f "$AppSettingsWww"
fi
ln -s "$AppSettingsVolume" "$AppSettingsWww"

urlencode() {
	local s="$1" i c out=""
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
			[a-zA-Z0-9.~_-]) out+="$c" ;;
			*) out+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s' "$out"
}

seed_admin() {
	[ -f "$SeedMarker" ] && return 0

	local email="${SECUREDESK_ADMIN_EMAIL:-admin@securedesk.local}"
	local pass="${SECUREDESK_ADMIN_PASSWORD:-SecureDesk@123}"
	local base="http://127.0.0.1:5000"
	local jar="/tmp/securedesk-seed.jar"
	local page token i

	# wait until the web app answers
	for i in $(seq 1 120); do
		wget -q -O /dev/null "$base/" 2>/dev/null && break
		sleep 2
	done

	rm -f "$jar"
	page=$(wget -q -O - --save-cookies "$jar" --keep-session-cookies "$base/Identity/Account/Register" 2>/dev/null)

	# The registration form is only offered while no organization exists (a fresh database).
	if ! echo "$page" | grep -q 'name="Input.Email"'; then
		echo "Default administrator not created: this database already has an organization."
		touch "$SeedMarker"
		return 0
	fi

	token=$(echo "$page" | grep -o 'name="__RequestVerificationToken"[^>]*value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')
	wget -q -O /dev/null --load-cookies "$jar" --save-cookies "$jar" --keep-session-cookies \
		--post-data "Input.Email=$(urlencode "$email")&Input.Password=$(urlencode "$pass")&Input.ConfirmPassword=$(urlencode "$pass")&__RequestVerificationToken=$(urlencode "$token")" \
		"$base/Identity/Account/Register" 2>/dev/null

	if grep -q "AspNetCore.Identity.Application" "$jar" 2>/dev/null; then
		touch "$SeedMarker"
		echo "=================================================================="
		echo " SecureDesk administrator created:  $email"
		if [ -z "${SECUREDESK_ADMIN_PASSWORD:-}" ]; then
			echo " Default password: SecureDesk@123   (CHANGE IT after the first login)"
		else
			echo " Password: taken from SECUREDESK_ADMIN_PASSWORD"
		fi
		echo "=================================================================="
	else
		echo "Could not create the administrator automatically (password rejected or server not ready)."
		echo "Open the web page and use Register to create it."
	fi
	rm -f "$jar"
}

echo "Starting SecureDesk server."
/usr/bin/dotnet "$ServerDir/Remotely_Server.dll" &
SERVER_PID=$!

# forward docker stop to the server
trap 'kill -TERM "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID"; exit $?' TERM INT

if [ "${SECUREDESK_SEED_ADMIN:-true}" = "true" ]; then
	seed_admin &
fi

wait "$SERVER_PID"
