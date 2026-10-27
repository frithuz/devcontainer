#!/usr/bin/env bash
# The apt signing key for Docker's repository, checked against its published fingerprint
# (Dockerfile's apt-keys stage).
set -euo pipefail

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
mkdir /keys
curl -fsSL --retry 3 -o /keys/docker.asc https://download.docker.com/linux/debian/gpg

# The fingerprint is field 10 of the fpr line after each pub line.
check() {
	local fingerprints
	fingerprints=$(gpg --show-keys --with-colons "$1" | awk -F: '/^pub:/ { getline; print $10 }')
	if [[ $fingerprints != "$2" ]]; then
		echo "unexpected key in $1: $fingerprints" >&2
		exit 1
	fi
}
check /keys/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
