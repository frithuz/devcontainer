#!/usr/bin/env bash
# Builds protoc from protobuf's release source tarball into /out (Dockerfile's protoc stage), after
# apt-bootstrap.sh, with the Abseil release protobuf pins compiled in statically. Both archives
# must match their pinned SHA-256 before use, and CMake builds offline. protoc links dynamically
# against the base's glibc and libstdc++: upstream's Linux release binary links glibc statically,
# which would bring LGPL code into the image. Installs protoc and the well-known types upstream's
# release ships under /out/usr/local, plus the license texts and a record of the sources under
# /out/legal.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

readonly script=${BASH_SOURCE[0]}
readonly version=${VERSION:?VERSION must be set} abseil_version=${ABSEIL_VERSION:?ABSEIL_VERSION must be set}
jobs=$(nproc)

apt-get install -y --no-install-recommends curl g++ make cmake dpkg-dev binutils

work=$(mktemp -d)
cd "$work"

# fetch <url> <file> <expected sha256>
fetch() {
	local digest
	curl -fsSL --retry 3 -o "$2" "$1"
	digest=$(sha256sum "$2" | cut -d' ' -f1)
	if [[ $digest != "$3" ]]; then
		echo "$1: sha256 $digest, expected $3" >&2
		exit 1
	fi
}
readonly protobuf_url=https://github.com/protocolbuffers/protobuf/releases/download/v$version/protobuf-$version.tar.gz
readonly abseil_url=https://github.com/abseil/abseil-cpp/releases/download/$abseil_version/abseil-cpp-$abseil_version.tar.gz
fetch "$protobuf_url" protobuf.tar.gz "${SHA256:?SHA256 must be set}"
fetch "$abseil_url" abseil-cpp.tar.gz "${ABSEIL_SHA256:?ABSEIL_SHA256 must be set}"
tar -xzf protobuf.tar.gz
tar -xzf abseil-cpp.tar.gz
readonly src=$work/protobuf-$version abseil_src=$work/abseil-cpp-$abseil_version

# protobuf names the Abseil release it's built and tested with; a bump that moves it fails here
# until ABSEIL_VERSION and ABSEIL_SHA256 follow.
pinned=$(sed -n 's/^set(abseil-cpp-version "\(.*\)")$/\1/p' "$src/cmake/dependencies.cmake")
if [[ $pinned != "$abseil_version" ]]; then
	echo "protobuf $version pins Abseil '$pinned', not $abseil_version" >&2
	exit 1
fi

# Debian's hardening flags without debug info. The base image drops dpkg's default vendor, and
# without one dpkg-buildflags prints nothing.
export DEB_VENDOR=Debian
export DEB_BUILD_MAINT_OPTIONS=hardening=+all
export DEB_CFLAGS_MAINT_STRIP=-g DEB_CXXFLAGS_MAINT_STRIP=-g
cppflags=$(dpkg-buildflags --get CPPFLAGS)
cflags=$(dpkg-buildflags --get CFLAGS)
cxxflags=$(dpkg-buildflags --get CXXFLAGS)
ldflags=$(dpkg-buildflags --get LDFLAGS)
if [[ " $cxxflags " != *' -fstack-protector-strong '* ]]; then
	echo "dpkg-buildflags' CXXFLAGS lack -fstack-protector-strong: '$cxxflags'" >&2
	exit 1
fi

# Abseil from the verified archive, never fetched: FORCE_FETCH skips any installed Abseil, the
# source directory override replaces the download, and FULLY_DISCONNECTED stops FetchContent from
# reaching the network. No zlib: protoc doesn't read gzip streams.
cmake -S "$src" -B build \
	-DCMAKE_BUILD_TYPE=Release \
	"-DCMAKE_C_FLAGS=$cppflags $cflags" \
	"-DCMAKE_CXX_FLAGS=$cppflags $cxxflags" \
	"-DCMAKE_EXE_LINKER_FLAGS=$ldflags" \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-Dprotobuf_BUILD_TESTS=OFF \
	-Dprotobuf_INSTALL=OFF \
	-Dprotobuf_WITH_ZLIB=OFF \
	-Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON \
	"-DFETCHCONTENT_SOURCE_DIR_ABSL=$abseil_src" \
	-DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build build --target protoc --parallel "$jobs"
readonly protoc=$work/build/protoc
strip "$protoc"

# The hardening reached the binary: full RELRO (GNU_RELRO with BIND_NOW) and a stack protector.
dynamic=$(readelf --dynamic --program-headers --wide "$protoc")
for marker in GNU_RELRO BIND_NOW; do
	if [[ $dynamic != *"$marker"* ]]; then
		echo "protoc isn't linked with $marker" >&2
		exit 1
	fi
done
if [[ $(readelf --dyn-syms --wide "$protoc") != *__stack_chk_fail* ]]; then
	echo 'protoc has no stack protector' >&2
	exit 1
fi
reported=$("$protoc" --version)
if [[ $reported != "libprotoc $version" ]]; then
	echo "protoc reports '$reported', expected 'libprotoc $version'" >&2
	exit 1
fi

# The well-known types, as upstream's release archive lays them out under include/. A bump that
# moves one fails here; compare the list with the release's protoc-<version>-linux-*.zip.
readonly include=/out/usr/local/include
wkt=(
	src/google/protobuf/any.proto
	src/google/protobuf/api.proto
	src/google/protobuf/compiler/plugin.proto
	src/google/protobuf/cpp_features.proto
	src/google/protobuf/cpp_file_options.proto
	src/google/protobuf/cpp_options.proto
	src/google/protobuf/descriptor.proto
	src/google/protobuf/duration.proto
	src/google/protobuf/empty.proto
	src/google/protobuf/field_mask.proto
	src/google/protobuf/json_enumvalue_options.proto
	src/google/protobuf/json_options.proto
	src/google/protobuf/source_context.proto
	src/google/protobuf/struct.proto
	src/google/protobuf/timestamp.proto
	src/google/protobuf/type.proto
	src/google/protobuf/wrappers.proto
	csharp/google/protobuf/c_sharp_features.proto
	go/google/protobuf/go_features.proto
	java/core/src/main/resources/google/protobuf/java_features.proto
)
installed=()
for file in "${wkt[@]}"; do
	dest=google/protobuf/${file#*/google/protobuf/}
	install -D -m 0644 "$src/$file" "$include/$dest"
	installed+=("$dest")
done
install -D -m 0755 "$protoc" /out/usr/local/bin/protoc
# Every installed type compiles with the installed protoc.
/out/usr/local/bin/protoc "-I$include" --include_imports --descriptor_set_out=/dev/null "${installed[@]}"

# The notices, and what scripts/collect-legal.sh records as the source: the tarball this build
# compiled, and this script, which controls the build. utf8_range ships inside protobuf's tarball;
# Abseil is recorded as embedded (its archive is part of protoc's source).
readonly legal=/out/legal/attribution/protoc
mkdir -p "$legal/utf8_range" "$legal/abseil-cpp"
cp "$src/LICENSE" "$legal/LICENSE"
cp "$src/third_party/utf8_range/LICENSE" "$legal/utf8_range/LICENSE"
cp "$abseil_src/LICENSE" "$legal/abseil-cpp/LICENSE"
cat >"$legal/SOURCE" <<SOURCE
component: protoc
source: $protobuf_url
sha256: $SHA256
toolchain: $(g++ --version | head -1)
build-script: ${script#/mnt/src/} sha256:$(sha256sum "$script" | cut -d' ' -f1)
embedded: abseil-cpp $abseil_version Apache-2.0 $abseil_url sha256:$ABSEIL_SHA256
SOURCE
cd /
rm -r "$work"
