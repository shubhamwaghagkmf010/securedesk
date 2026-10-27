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
