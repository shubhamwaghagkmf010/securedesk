#!/usr/bin/env bash
#
# SecureDesk Auto-Update - manual rollback helper.
#
# Reverts the LIVE production container to a known-good image. This is a
# manual safety net for a human to run AFTER reviewing a bad deploy - the
# auto-update system itself never deploys to production, so this script is
# never called automatically.
#
# Must be run with sudo: the production compose directory is root-owned.
#
# Usage:
#   sudo bash rollback.sh                 # rolls back to the pre-security-fixes image
#   sudo bash rollback.sh <image:tag>     # rolls back to a specific image
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this with sudo: sudo bash $0 [image_tag]"
	exit 1
fi

# Known-good baseline, recorded when the security-fix phases started.
DEFAULT_IMAGE="shubhamwaghagkmf010/securedesk:1.4.0"
DEFAULT_DIGEST="sha256:7ed1dfd6eb90538dbde39cdfa18ff453a9db9584d7529d569e147c53010c719e"

TARGET_IMAGE="${1:-$DEFAULT_IMAGE}"
COMPOSE_DIR="/appdata/securedesk"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
	echo "Cannot find $COMPOSE_FILE - are you on the right host?"
	exit 1
fi

if [ "$TARGET_IMAGE" = "$DEFAULT_IMAGE" ]; then
	echo "Rolling back to the default known-good image: $DEFAULT_IMAGE"
	echo "(recorded digest: $DEFAULT_DIGEST)"
fi

BACKUP="$COMPOSE_FILE.rollback-backup-$(date +%Y%m%d-%H%M%S)"
cp "$COMPOSE_FILE" "$BACKUP"
echo "Backed up current compose file to $BACKUP"

sed -i "s#image: .*securedesk:.*#image: $TARGET_IMAGE#" "$COMPOSE_FILE"
echo "Set image to $TARGET_IMAGE in $COMPOSE_FILE"

cd "$COMPOSE_DIR"
docker compose up -d

echo
echo "Rolled back. Verify with:"
echo "  curl -sk -I https://127.0.0.1:5443/"
echo "  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'"
