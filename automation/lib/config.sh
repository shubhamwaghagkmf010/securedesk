#!/usr/bin/env bash
# Minimal YAML value/list reader for auto-update-config.yaml.
#
# The config file is deliberately kept flat (no nested keys reused at
# different levels) so this stays reliable with plain grep/awk and does not
# need a yq/python dependency. Requires $CONFIG_FILE to be set by the caller
# before sourcing this file.

yaml_get() {
	local key="$1" default="${2:-}"
	local val
	val=$(grep -E "^${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 \
		| sed -E 's/^[^:]+:[[:space:]]*//' \
		| sed -E 's/[[:space:]]*#.*$//' \
		| sed -E 's/^"(.*)"$/\1/' \
		| sed -E "s/^'(.*)'\$/\1/")
	if [ -z "$val" ]; then
		val="$default"
	fi
	echo "$val"
}

yaml_get_list() {
	local key="$1"
	awk -v k="^${key}:" '
		$0 ~ k { flag=1; next }
		flag && /^[^[:space:]]/ { flag=0 }
		flag && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print }
	' "$CONFIG_FILE"
}

# --- Source-tree resolution / bootstrap --------------------------------
# These exist so check-for-updates.sh / scan-vulnerabilities.sh /
# auto-update-build-and-test.sh can run on ANY SecureDesk server, not just
# the original build VM (which already has a hand-maintained tree at
# ~/securedesk-ui-build). A fresh/lightweight server has neither, so a
# plain clone of the public repo is used instead, at ~/securedesk-src -
# this also brings this automation/ folder itself along for the ride.

resolve_source_dir() {
	local candidate
	for candidate in "$HOME/securedesk-ui-build" "$HOME/securedesk-src"; do
		if [ -d "$candidate/Server" ] && [ -d "$candidate/docker" ]; then
			echo "$candidate"
			return 0
		fi
	done
	echo "$HOME/securedesk-src"
}

# Prints the resolved source dir path on success, prints nothing and
# returns non-zero if no tree exists and none could be bootstrapped
# (no git, no network). NEVER touches ~/securedesk-ui-build beyond a
# fast-forward-only `git pull` if it happens to be a git repo - that tree
# is hand-maintained by a human and is never cloned/reset here.
ensure_source_tree() {
	local dir
	dir="$(resolve_source_dir)"

	if [ -d "$dir/Server" ]; then
		if [ -d "$dir/.git" ]; then
			git -C "$dir" pull --ff-only >/dev/null 2>&1 || true
		fi
		echo "$dir"
		return 0
	fi

	if ! command -v git >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
			apt-get update -y >/dev/null 2>&1
			apt-get install -y git >/dev/null 2>&1
		fi
	fi
	command -v git >/dev/null 2>&1 || return 1

	git clone https://github.com/shubhamwaghagkmf010/securedesk.git "$dir" >/dev/null 2>&1 || return 1
	echo "$dir"
	return 0
}
