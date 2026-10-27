#!/usr/bin/env bash
#
# SecureDesk - sync canonical source + auto-update automation into the git
# repo clone and push to GitHub.
#
# MANUALLY INVOKED ONLY - this is not called by any cron job or the
# auto-update pipeline. A human runs this, reviews the diff it shows, and
# then confirms the push. git push will prompt for GitHub username +
# Personal Access Token the first time (credential.helper store caches it
# after that).
#
# Usage:
#   bash git-sync-push.sh "commit message"
#   bash git-sync-push.sh                      # uses a default message
#
set -uo pipefail

SOURCE_DIR="$HOME/securedesk-ui-build"
AUTOMATION_DIR="$HOME/securedesk-auto-update"
REPO_DIR="$HOME/securedesk-repo-check"
COMMIT_MSG="${1:-Sync security fixes, .NET 8 upgrade, AD/LDAP login, and auto-update automation}"

if [ ! -d "$REPO_DIR/.git" ]; then
	echo "ERROR: $REPO_DIR is not a git clone. Clone it first:"
	echo "  git clone https://github.com/shubhamwaghagkmf010/securedesk.git $REPO_DIR"
	exit 1
fi

echo "=== Syncing $SOURCE_DIR -> $REPO_DIR ==="
rsync -a \
	--exclude='.git' --exclude='bin/' --exclude='obj/' --exclude='node_modules/' \
	--exclude='*.bak-net6' --exclude='docker/overlay/' \
	"$SOURCE_DIR/" "$REPO_DIR/"

echo "=== Syncing $AUTOMATION_DIR -> $REPO_DIR/automation ==="
mkdir -p "$REPO_DIR/automation"
rsync -a \
	--exclude='logs/' --exclude='test-stacks/' --exclude='trivy-cache/' \
	--exclude='status.json' --exclude='known-image-ids.env' \
	"$AUTOMATION_DIR/" "$REPO_DIR/automation/"

cd "$REPO_DIR"

echo "=== git status (review before this commits) ==="
git status --short

if [ -z "$(git status --porcelain)" ]; then
	echo "No changes to commit - nothing to push."
	exit 0
fi

read -r -p "Proceed with commit + push? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
	echo "Aborted - nothing committed, nothing pushed."
	exit 1
fi

git add -A
git commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"

echo "=== Pushing to origin main (may prompt for GitHub username + PAT) ==="
git push origin main

echo "=== Done. ==="
