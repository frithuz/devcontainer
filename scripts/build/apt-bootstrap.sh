#!/usr/bin/env bash
# Makes every apt source HTTPS: the base image's Debian and DHI sources use plain HTTP. It ships
# ca-certificates, so the update trusts the installed store. Shared by the Dockerfile's git and
# image stages.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

shopt -s nullglob
deb822=(/etc/apt/sources.list.d/*.sources)
if ((${#deb822[@]})); then
	sed -i 's|^URIs: http://|URIs: https://|' "${deb822[@]}"
fi
sources=(/etc/apt/sources.list.d/*)
if [[ -e /etc/apt/sources.list ]]; then
	sources+=(/etc/apt/sources.list)
fi
if ((${#sources[@]})) && plain=$(grep -hE '^[[:space:]]*(URIs:|deb)' "${sources[@]}" | grep 'http://'); then
	echo "plain HTTP apt source left: $plain" >&2
	exit 1
fi
apt-get update
