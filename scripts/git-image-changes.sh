#!/usr/bin/env bash
# Emit workflow outputs. Only a missing tag permits building after a failed lookup.
set -euo pipefail
version=$(awk -F= 'NF == 2 && $1 == "ARG VERSION" { print $2 }' Dockerfile.git)
checksum=$(awk -F= 'NF == 2 && $1 == "ARG SHA256" { print $2 }' Dockerfile.git)
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $checksum =~ ^[0-9a-f]{64}$ ]]; then
	echo 'Dockerfile.git must pin one VERSION and SHA256' >&2
	exit 1
fi
echo "version=$version"
echo "checksum=$checksum"
if [[ ${FORCE:-false} == true ]]; then
	echo 'build=true'
	exit 0
fi
error=$(mktemp)
trap 'rm -f "$error"' EXIT
if manifest=$(docker buildx imagetools inspect "quay.io/frithuz/git:$version" --raw 2>"$error"); then
	published=$(jq -er '.annotations["dev.frithuz.git.source-sha256"]' <<<"$manifest")
	if [[ $published == "$checksum" ]]; then
		echo 'build=false'
	else
		echo 'build=true'
	fi
elif grep -Eq 'manifest unknown|MANIFEST_UNKNOWN' "$error" ||
	grep -Fxq "ERROR: quay.io/frithuz/git:$version: not found" "$error"; then
	echo 'build=true'
else
	cat "$error" >&2
	exit 1
fi
