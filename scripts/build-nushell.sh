#!/usr/bin/env bash
# Builds nu from its crates.io release archive into /out (Dockerfile's nushell stage). The stage
# ADDs the archive, verified against its pinned SHA-256; cargo fetches the dependencies, each
# checked against the checksum in the release's Cargo.lock (--locked). Bash, not nu: this builds
# the nu every other stage runs its scripts with. Writes nu under /out/usr/local/bin, plus its
# license texts and a record of its sources under /out/legal.
set -euo pipefail

readonly crate=${1:?usage: build-nushell.sh <crate archive>}
readonly version=${VERSION:?VERSION must be set} features=${FEATURES:?FEATURES must be set}
readonly script=${BASH_SOURCE[0]}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$crate" -C "$work"
readonly src=$work/nu-$version
if [[ ! -f $src/Cargo.lock ]]; then
	echo "build-nushell: $crate has no nu-$version/Cargo.lock" >&2
	exit 1
fi

# Sized for one shipped binary rather than for build time: fat LTO across all crates in one
# codegen unit, and no symbol table. nushell's own release profile sets the rest (opt-level "s").
# Built from outside the source tree: rustup reads rust-toolchain.toml from the working directory,
# and nushell's pins an older toolchain than the rust stage's, which it would try to download.
export CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_STRIP=symbols
cd "$work"
cargo build --release --locked --manifest-path "$src/Cargo.toml" --target-dir "$work/target" \
	--bin nu --no-default-features --features "$features"
install -D -m 0755 "$work/target/release/nu" /out/usr/local/bin/nu
readonly nu=/out/usr/local/bin/nu

reported=$("$nu" --version)
if [[ $reported != "$version" ]]; then
	echo "build-nushell: nu --version reports '$reported', not $version" >&2
	exit 1
fi
# version's features are one comma-separated string.
listed=$("$nu" --no-config-file -c 'version | get features')
built=${listed//,/ }
for feature in ${features//,/ }; do
	if [[ " $built " != *" $feature "* ]]; then
		echo "build-nushell: nu lacks the $feature feature (it has: $listed)" >&2
		exit 1
	fi
done
echo "build-nushell: nu $version, features: $listed, $(du -h "$nu" | cut -f1)"

# The notices, and what scripts/collect-legal.sh records as the source: the archive this build
# compiled and this script. The Rust standard library is compiled in, so its notices and the
# license texts they reference come from the toolchain that built it.
readonly legal=/out/legal/attribution/nushell
mkdir -p "$legal/rust"
install -m 0644 "$src/LICENSE" "$legal/LICENSE"
rust_doc=$(echo /usr/local/rustup/toolchains/*/share/doc/rust)
cp "$rust_doc/COPYRIGHT-library.html" "$legal/rust/"
cp -r "$rust_doc/licenses" "$legal/rust/"
{
	echo "component: nushell"
	echo "source: https://static.crates.io/crates/nu/nu-$version.crate"
	echo "sha256: $(sha256sum "$crate" | cut -d' ' -f1)"
	echo "toolchain: $(rustc --version)"
	echo "features: $features"
	echo "build-script: ${script#/mnt/src/} sha256:$(sha256sum "$script" | cut -d' ' -f1)"
} >"$legal/SOURCE"
