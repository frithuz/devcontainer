#!/usr/bin/env bash
# Makes every apt source HTTPS: the base image's Debian sources use plain HTTP, and it ships no CA
# store. So the first update and the ca-certificates install go over HTTP, which apt still checks
# against the archive's signed InRelease files, and every later fetch uses HTTPS and trusts the
# installed store. Shared by the Dockerfile's fetch and image stages.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
	apt-get update
	apt-get install -y --no-install-recommends ca-certificates
fi

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
