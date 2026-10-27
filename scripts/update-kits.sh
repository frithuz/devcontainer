#!/usr/bin/env bash
# Point the sandbox kits at a published image and at the newest release of each agent's mixin
# from Docker (docs/maintenance.md#sandbox-kits). Runs on the host, including macOS's bash 3.2,
# with curl, jq, and docker buildx.
#
#   scripts/update-kits.sh <name>:<tag>@sha256:<digest>
#
# Each kit's dockerfile pins the image (ARG IMAGE) and docker.io/docker/sbx-kit-<agent>-mixin
# (ARG MIXIN) by tag and index digest, and its descriptor's provides names the mixin's version.
# The mixin's newest release is what its latest tag points at, pinned by the one
# <major>.<minor>.<patch> tag on Docker Hub with the same digest; tags aren't ordered by version.
# Rewrites the three lines in each kit and prints one `<kit>	<old version>	<new version>` line
# per kit. Only the working tree changes.
set -euo pipefail

cd "$(dirname "$0")/.."

ref=${1:?usage: scripts/update-kits.sh <name>:<tag>@sha256:<digest>}
if [[ ! $ref =~ ^[^@]+:[^@/]+@sha256:[0-9a-f]{64}$ ]]; then
	echo "update-kits: $ref isn't a <name>:<tag>@sha256:<digest> reference" >&2
	exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Replaces the one line matching $2 in file $1 with $3, and fails unless exactly one matches.
replace_line() {
	local file=$1 pattern=$2 line=$3
	if [[ $(grep -c -E "$pattern" "$file") != 1 ]]; then
		echo "update-kits: expected one line matching $pattern in $file" >&2
		exit 1
	fi
	# Through the environment, because awk -v would process the pattern's backslashes.
	pattern=$pattern line=$line awk '$0 ~ ENVIRON["pattern"] { print ENVIRON["line"]; next } { print }' \
		"$file" >"$work/edit"
	cat "$work/edit" >"$file"
}

for kit in claude codex; do
	repository=docker.io/docker/sbx-kit-$kit-mixin
	curl -fsSL --retry 3 "https://hub.docker.com/v2/repositories/docker/sbx-kit-$kit-mixin/tags?page_size=100" >"$work/tags.json"
	digest=$(docker buildx imagetools inspect "$repository:latest" --format '{{json .Manifest}}' | jq -er .digest)
	version=$(jq -r --arg digest "$digest" \
		'[.results[] | select(.digest == $digest and (.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | .name] | if length == 1 then .[0] else empty end' \
		"$work/tags.json")
	if [[ -z $version ]]; then
		echo "update-kits: $repository:latest ($digest) isn't one <major>.<minor>.<patch> tag" >&2
		exit 1
	fi

	dir=sandboxes/devcontainer-$kit
	descriptor=$dir/$kit.yaml
	provides='^provides: \["'$kit'@[^"]*"\]$'
	old=$(grep -E "$provides" "$descriptor" | sed -E 's/.*@([^"]*)".*/\1/' || true)
	replace_line "$dir/$kit.dockerfile" '^ARG IMAGE=' "ARG IMAGE=$ref"
	replace_line "$dir/$kit.dockerfile" '^ARG MIXIN=' "ARG MIXIN=$repository:$version@$digest"
	replace_line "$descriptor" "$provides" "provides: [\"$kit@$version\"]"
	printf '%s\t%s\t%s\n' "$kit" "${old:--}" "$version"
done
