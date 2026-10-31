#!/usr/bin/env bash
# Downloads Sampo's release archive for TARGETARCH and its LICENSE from the release tag, checks
# each against the SHA-256 the stage pins, and puts the binary and LICENSE in /opt/sampo
# (Dockerfile's sampo stage). SOURCE records the archive, for scripts/collect-legal.sh
# (install: release).
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
	echo "sampo: no pinned archive for $TARGETARCH" >&2
	exit 1
	;;
esac
tag=cargo-sampo-v$VERSION
url=https://github.com/bruits/sampo/releases/download/$tag/sampo-$VERSION-$triple.tar.gz
license_url=https://raw.githubusercontent.com/bruits/sampo/$tag/LICENSE
work=$(mktemp -d)

# verify <file> <url> <expected sha256>
verify() {
	local digest
	digest=$(sha256sum "$1" | cut -d' ' -f1)
	if [[ $digest != "$3" ]]; then
		echo "sampo: $2 has sha256 $digest, expected $3" >&2
		exit 1
	fi
}

curl -fsSL --retry 3 -o "$work/sampo.tar.gz" "$url"
verify "$work/sampo.tar.gz" "$url" "$expected"
curl -fsSL --retry 3 -o "$work/LICENSE" "$license_url"
verify "$work/LICENSE" "$license_url" "$SHA256_LICENSE"
mkdir /opt/sampo
tar -xzf "$work/sampo.tar.gz" -C /opt/sampo sampo
mv "$work/LICENSE" /opt/sampo/LICENSE
rm -r "$work"
cat >/opt/sampo/SOURCE <<SOURCE
component: sampo
repository: https://github.com/bruits/sampo
ref: $tag
release: $url
sha256: $expected
license: $license_url
license-sha256: $SHA256_LICENSE
SOURCE
