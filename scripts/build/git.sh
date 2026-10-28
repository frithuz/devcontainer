#!/usr/bin/env bash
# Builds git from its release tarball into /out (Dockerfile's git stage), after apt-bootstrap.sh,
# with zlib-ng compiled in for faster compression. The tarball's signature must verify against
# the pinned maintainer key and zlib-ng's archive must match its pinned digest before either is
# used, and zlib-ng's test suite must pass before git links it. Installs under /usr/local
# with symlinked built-ins, so the files stage copies it as one tree, plus its license texts and
# a record of its sources under /out/legal.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

readonly script=${BASH_SOURCE[0]}
readonly version=${VERSION:?VERSION must be set} signer=${SIGNER:?SIGNER must be set}
jobs=$(nproc)

apt-get install -y --no-install-recommends \
	curl gcc make libc6-dev dpkg-dev gnupg xz-utils \
	libcurl4-openssl-dev libpcre2-dev libssl-dev

work=$(mktemp -d)
cd "$work"
readonly base=https://www.kernel.org/pub/software/scm/git
curl -fsSL --retry 3 -o signer.asc "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$signer"

# The keyserver's answer must be the pinned key alone: the fingerprint is field 10 of the fpr
# line after each pub line.
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
primaries=$(gpg --show-keys --with-colons signer.asc | awk -F: '/^pub:/ { getline; print $10 }')
if [[ $primaries != "$signer" ]]; then
	echo "unexpected keys from the keyserver: ${primaries//$'\n'/, }" >&2
	exit 1
fi
gpg --batch --quiet --import signer.asc

# Downloads <name>.tar.xz and checks its signature, leaving <name>.tar. kernel.org signs the
# uncompressed tarball. gpg fails on a bad signature; a good one by any other key must not pass
# either, so check that the signing key's primary is the pinned one (VALIDSIG's last field).
fetch_signed() {
	local name=$1 status signed_by
	curl -fsSL --retry 3 -o "$name.tar.xz" "$base/$name.tar.xz"
	curl -fsSL --retry 3 -o "$name.tar.sign" "$base/$name.tar.sign"
	xz --decompress --stdout "$name.tar.xz" >"$name.tar"
	status=$(gpg --batch --status-fd 1 --verify "$name.tar.sign" "$name.tar")
	signed_by=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }' <<<"$status")
	if [[ $signed_by != "$signer" ]]; then
		echo "$name.tar.sign isn't a valid signature by $signer: ${status//$'\n'/; }" >&2
		exit 1
	fi
	echo "$name.tar: good signature by $signer"
}
fetch_signed "git-$version"

# Debian's hardening flags without debug info, plus link-time optimization, for both builds. The
# base image drops dpkg's default vendor, and without one dpkg-buildflags prints nothing.
export DEB_VENDOR=Debian
export DEB_BUILD_MAINT_OPTIONS='hardening=+all optimize=+lto'
export DEB_CFLAGS_MAINT_STRIP=-g
cflags=$(dpkg-buildflags --get CFLAGS)
cppflags=$(dpkg-buildflags --get CPPFLAGS)
ldflags=$(dpkg-buildflags --get LDFLAGS)
for flag in -fstack-protector-strong -flto=auto; do
	if [[ " $cflags " != *" $flag "* ]]; then
		echo "dpkg-buildflags' CFLAGS lack $flag: '$cflags'" >&2
		exit 1
	fi
done

# zlib-ng, a static library git links in place of zlib, with its native API. It picks its
# CPU-specific code at run time, so one build suits every host. Its releases aren't signed
# (lightweight tags, unsigned commits), so the archive of the pinned commit must match the pinned
# digest, and its version the pinned version.
readonly zlib_ng_version=${ZLIB_NG_VERSION:?} zlib_ng_commit=${ZLIB_NG_COMMIT:?}
readonly zlib_ng_url=https://github.com/zlib-ng/zlib-ng/archive/$zlib_ng_commit.tar.gz
curl -fsSL --retry 3 -o zlib-ng.tar.gz "$zlib_ng_url"
zlib_ng_digest=$(sha256sum zlib-ng.tar.gz | cut -d' ' -f1)
if [[ $zlib_ng_digest != "${ZLIB_NG_SHA256:?}" ]]; then
	echo "$zlib_ng_url: sha256 $zlib_ng_digest, expected $ZLIB_NG_SHA256" >&2
	exit 1
fi
tar -xzf zlib-ng.tar.gz
cd "zlib-ng-$zlib_ng_commit"
if ! grep -qF "#define ZLIBNG_VERSION \"$zlib_ng_version\"" zlib-ng.h.in; then
	echo "zlib-ng $zlib_ng_commit isn't version $zlib_ng_version" >&2
	exit 1
fi
CFLAGS="$cppflags $cflags" LDFLAGS=$ldflags ./configure --static --prefix=/opt/zlib-ng
make "-j$jobs"
make test
make install
zlib_ng_license=$work/zlib-ng-LICENSE.md
cp LICENSE.md "$zlib_ng_license"
cd "$work"

tar -xf "git-$version.tar"
cd "git-$version"
# sysconfdir keeps the system config at /etc/gitconfig, where `git config --system` and other
# tools expect it. No Perl, Python, Tcl/Tk, or translations: no send-email, svn, p4, gitk, or
# git-gui. No expat: git-http-push only pushes over WebDAV. SHA-1 stays collision-detecting for
# object IDs; OpenSSL's accelerated SHA-1 is used only where that isn't needed (checksums of
# files git writes itself), and for SHA-256. Built-ins are symlinks rather than hard links, and
# only those git still needs as separate commands are installed. git's Rust code has no crate
# dependencies, so cargo runs offline: a build that tried to fetch one fails.
make_args=(
	prefix=/usr/local sysconfdir=/etc
	"CFLAGS=$cflags" "CPPFLAGS=$cppflags" "LDFLAGS=$ldflags"
	ZLIB_NG=YesPlease ZLIB_NG_PATH=/opt/zlib-ng
	NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_EXPAT=YesPlease
	OPENSSL_SHA1_UNSAFE=YesPlease OPENSSL_SHA256=YesPlease USE_LIBPCRE2=YesPlease
	INSTALL_SYMLINKS=YesPlease SKIP_DASHED_BUILT_INS=YesPlease
)
export CARGO_NET_OFFLINE=true
make "-j$jobs" "${make_args[@]}" all
make "${make_args[@]}" strip
# The hardening reached the binary: full RELRO (GNU_RELRO with BIND_NOW) and a stack protector.
dynamic=$(readelf --dynamic --program-headers --wide git)
for marker in GNU_RELRO BIND_NOW; do
	if [[ $dynamic != *"$marker"* ]]; then
		echo "git isn't linked with $marker" >&2
		exit 1
	fi
done
if [[ $(readelf --dyn-syms --wide git) != *__stack_chk_fail* ]]; then
	echo 'git has no stack protector' >&2
	exit 1
fi

make "${make_args[@]}" DESTDIR=/out install
make "${make_args[@]}" DESTDIR=/out -C contrib/subtree install

# Commands a client container never runs: the daemon and servers, imap-send, instaweb, and the
# stubs that only report a missing Perl or Python. A version that stops shipping one fails here.
readonly exec_path=/out/usr/local/libexec/git-core
for command in git-daemon git-http-backend git-imap-send git-instaweb \
	git-archimport git-cvsexportcommit git-cvsimport git-p4 git-send-email git-svn; do
	if [[ ! -e $exec_path/$command ]]; then
		echo "$exec_path/$command doesn't exist; update the list in git.sh" >&2
		exit 1
	fi
	rm "$exec_path/$command"
done
rm /out/usr/local/bin/git-shell /out/usr/local/bin/git-cvsserver
if [[ -e $exec_path/git-http-push ]]; then
	echo 'git-http-push was built despite NO_EXPAT' >&2
	exit 1
fi

# The notices, and what scripts/collect-legal.sh records as the source: the tarball this build
# compiled, and this script, which controls the build, so git's source image carries it too
# (scripts/plan-sources.sh checks it against this digest). zlib-ng and the Rust standard library
# are compiled in too: zlib-ng is recorded as embedded (its archive is part of git's source), and
# the Rust notices and the license texts they reference come from the toolchain that built it.
readonly legal=/out/legal/attribution/git
mkdir -p "$legal/rust" "$legal/zlib-ng"
cp COPYING LGPL-2.1 "$legal/"
rust_docs=(/usr/local/rustup/toolchains/*/share/doc/rust)
cp "${rust_docs[0]}/COPYRIGHT-library.html" "$legal/rust/"
cp -r "${rust_docs[0]}/licenses" "$legal/rust/"
cp "$zlib_ng_license" "$legal/zlib-ng/LICENSE.md"
cat >"$legal/SOURCE" <<SOURCE
component: git
source: $base/git-$version.tar.xz
sha256: $(sha256sum "../git-$version.tar.xz" | cut -d' ' -f1)
signer: $signer
toolchain: $(rustc --version)
build-script: ${script#/mnt/src/} sha256:$(sha256sum "$script" | cut -d' ' -f1)
embedded: zlib-ng $zlib_ng_version Zlib $zlib_ng_url sha256:$zlib_ng_digest
SOURCE
