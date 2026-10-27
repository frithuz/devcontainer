#!/usr/bin/env bash
# Point the sandbox kits at a published image and the agent versions it installed
# (docs/maintenance.md#sandbox-kits). Runs on the host, including macOS's bash 3.2.
#
#   scripts/update-kits.sh <name>:<tag>@sha256:<digest>
#
# Reads /legal/manifest.tsv from both platforms of the image, and fails unless each agent has
# one version across them. Rewrites each kit's FROM line and its provides entry, and prints
# one `<kit>	<old version>	<new version>` line per kit. Only the working tree changes.
set -euo pipefail

cd "$(dirname "$0")/.."

ref=${1:?usage: scripts/update-kits.sh <name>:<tag>@sha256:<digest>}
if [[ ! $ref =~ ^[^@]+:[^@/]+@sha256:[0-9a-f]{64}$ ]]; then
	echo "update-kits: $ref isn't a <name>:<tag>@sha256:<digest> reference" >&2
	exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
scripts/copy-manifests.sh "$ref" "$work/manifests"

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
	versions=$(awk -F'\t' -v kit="$kit" '$1 == kit { print $2 }' "$work"/manifests/*/manifest.tsv | sort -u)
	if [[ ! $versions =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "update-kits: $ref doesn't record one $kit version across its platforms: ${versions:-none}" >&2
		exit 1
	fi

	dir=sandboxes/devcontainer-$kit
	descriptor=$dir/$kit.yaml
	provides='^provides: \["'$kit'@[^"]*"\]$'
	old=$(grep -E "$provides" "$descriptor" | sed -E 's/.*@([^"]*)".*/\1/' || true)
	replace_line "$dir/$kit.dockerfile" '^FROM ' "FROM $ref"
	replace_line "$descriptor" "$provides" "provides: [\"$kit@$versions\"]"
	printf '%s\t%s\t%s\n' "$kit" "${old:--}" "$versions"
done
