#!/usr/bin/env bash
# The Rust toolchain from the official image, with the developer components its minimal profile
# leaves out, laid out at /opt/rust (Dockerfile's rust stage). rustup fetches each component for
# the image's pinned release and checks it against the SHA-256 in that release's channel manifest.
# The image takes only the toolchain directory, without rustup: rustc finds its sysroot from its
# own path, so the commands work without RUSTUP_HOME, the way GitHub Actions runs them.
set -euo pipefail

rustup component add rustfmt clippy rust-analyzer rust-src

sysroot=$(rustc --print sysroot)
cp -a "$sysroot" /opt/rust

# The notices for /legal: rustc's and the standard library's, and each component's.
mkdir -p /opt/rust-legal
cp -a /opt/rust/share/doc/. /opt/rust-legal/

# The copy runs on its own, without rustup's proxies.
for bin in cargo rustc rustdoc rustfmt cargo-fmt cargo-clippy clippy-driver rust-analyzer; do
	if [[ ! -x /opt/rust/bin/$bin ]]; then
		echo "rust: /opt/rust/bin/$bin is missing" >&2
		exit 1
	fi
done
expected=$(rustc --version)
actual=$(env -i PATH=/opt/rust/bin:/usr/bin:/bin /opt/rust/bin/rustc --version)
if [[ $actual != "$expected" ]]; then
	echo "rust: the copied rustc reports '$actual', not '$expected'" >&2
	exit 1
fi
