#!/usr/bin/env bash
# Validates each scripts/*.yaml against its schema, checks it for duplicate names, and converts
# it to /config/<name>.json (Dockerfile's config-run stage). scripts/ is mounted at /mnt/scripts.
set -euo pipefail

mkdir /config
for schema in /mnt/scripts/schemas/*.schema.json; do
	name=$(basename "$schema" .schema.json)
	yaml=/mnt/scripts/$name.yaml
	echo "validating scripts/$name.yaml"
	jv "$schema" "$yaml"
	yq -o=json . "$yaml" >"/config/$name.json"
	# Names identify entries across every list in a file; a schema can't express that.
	jq -e --arg file "scripts/$name.yaml" '[.[] | arrays | .[] | .name // .module] | group_by(.) | map(select(length > 1)[0]) |
		if length > 0 then error("\($file): duplicate names: \(join(", "))") else true end' "/config/$name.json" >/dev/null
done
