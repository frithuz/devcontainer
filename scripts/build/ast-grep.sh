#!/usr/bin/env bash
# Downloads ast-grep's release archive for TARGETARCH and its LICENSE from the release tag, checks
# each against the SHA-256 the stage pins, and puts the binary and LICENSE in /opt/ast-grep
# (Dockerfile's ast-grep stage). SOURCE records the archive, for scripts/collect-legal.sh
# (install: release). The archive's sg, a deprecated alias, is left out: it would shadow the
# system's sg (run a command as another group).
set -euo pipefail

case $TARGETARCH in
amd64)
	triple=x86_64-unknown-linux-gnu
	expected=$SHA256_AMD64
	;;
arm64)
	triple=aarch64-unknown-linux-gnu
	expected=$SHA256_ARM64
	;;
*)
	echo "ast-grep: no pinned archive for $TARGETARCH" >&2
	exit 1
	;;
esac
url=https://github.com/ast-grep/ast-grep/releases/download/$VERSION/app-$triple.zip
license_url=https://raw.githubusercontent.com/ast-grep/ast-grep/$VERSION/LICENSE
work=$(mktemp -d)

# verify <file> <url> <expected sha256>
verify() {
	local digest
	digest=$(sha256sum "$1" | cut -d' ' -f1)
	if [[ $digest != "$3" ]]; then
		echo "ast-grep: $2 has sha256 $digest, expected $3" >&2
		exit 1
	fi
}

curl -fsSL --retry 3 -o "$work/ast-grep.zip" "$url"
verify "$work/ast-grep.zip" "$url" "$expected"
curl -fsSL --retry 3 -o "$work/LICENSE" "$license_url"
verify "$work/LICENSE" "$license_url" "$SHA256_LICENSE"
# The go stage has no unzip; Python's zipfile extracts without keeping modes, so the files stage
# sets them.
python3 -I -m zipfile -e "$work/ast-grep.zip" "$work/app"
mkdir /opt/ast-grep
mv "$work/app/ast-grep" /opt/ast-grep/ast-grep
mv "$work/LICENSE" /opt/ast-grep/LICENSE
rm -r "$work"
cat >/opt/ast-grep/SOURCE <<SOURCE
component: ast-grep
repository: https://github.com/ast-grep/ast-grep
ref: $VERSION
release: $url
sha256: $expected
license: $license_url
license-sha256: $SHA256_LICENSE
SOURCE
