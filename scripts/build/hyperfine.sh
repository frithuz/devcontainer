#!/usr/bin/env bash
# Downloads hyperfine's release archive for TARGETARCH, checks it against the SHA-256 the stage
# pins for that architecture, and unpacks the binary and its license texts to /opt/hyperfine
# (Dockerfile's hyperfine stage). SOURCE records the archive, for scripts/collect-legal.sh
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
	echo "hyperfine: no pinned archive for $TARGETARCH" >&2
	exit 1
	;;
esac
name=hyperfine-v$VERSION-$triple
url=https://github.com/sharkdp/hyperfine/releases/download/v$VERSION/$name.tar.gz
work=$(mktemp -d)
curl -fsSL --retry 3 -o "$work/hyperfine.tar.gz" "$url"
digest=$(sha256sum "$work/hyperfine.tar.gz" | cut -d' ' -f1)
if [[ $digest != "$expected" ]]; then
	echo "hyperfine: $url has sha256 $digest, expected $expected" >&2
	exit 1
fi
mkdir /opt/hyperfine
tar -xzf "$work/hyperfine.tar.gz" -C /opt/hyperfine --strip-components=1 \
	"$name/hyperfine" "$name/LICENSE-APACHE" "$name/LICENSE-MIT"
rm -r "$work"
cat >/opt/hyperfine/SOURCE <<SOURCE
component: hyperfine
repository: https://github.com/sharkdp/hyperfine
ref: v$VERSION
release: $url
sha256: $digest
SOURCE
