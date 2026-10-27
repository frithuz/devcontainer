# Builds git from its release tarball into /out (Dockerfile's git stage), after apt-bootstrap.nu,
# with zlib-ng compiled in for faster compression. The tarball's signature must verify against
# the pinned maintainer key and zlib-ng's archive must match its pinned digest before either is
# used, and both test suites must pass before anything is installed. Installs under /usr/local
# with symlinked built-ins, so the files stage copies it as one tree, plus its license texts and
# a record of its sources under /out/legal.
const script = path self
$env.DEBIAN_FRONTEND = 'noninteractive'
let version = $env.VERSION
let signer = $env.SIGNER
let jobs = sys cpu | length

# perl is for the test suite (prove and its helpers); git itself is built without it.
(apt-get install -y --no-install-recommends
  gcc make libc6-dev dpkg-dev gnupg xz-utils perl
  libcurl4-openssl-dev libpcre2-dev libssl-dev)

let work = mktemp -d
cd $work
let base = 'https://www.kernel.org/pub/software/scm/git'
http get $"https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x($signer)"
  | save signer.asc

# The keyserver's answer must be the pinned key alone: the fingerprint is field 10 of the fpr
# line after each pub line.
$env.GNUPGHOME = (mktemp -d)
let rows = gpg --show-keys --with-colons signer.asc | lines
let primaries = $rows | enumerate | where {|row| $row.item starts-with 'pub:' }
  | each {|row| $rows | get ($row.index + 1) | split row ':' | get 9 }
if $primaries != [$signer] {
  error make {msg: $"unexpected keys from the keyserver: ($primaries | str join ', ')"}
}
gpg --batch --quiet --import signer.asc

# Downloads <name>.tar.xz and checks its signature, leaving <name>.tar. kernel.org signs the
# uncompressed tarball. gpg fails on a bad signature; a good one by any other key must not pass
# either, so check that the signing key's primary is the pinned one (VALIDSIG's last field).
def fetch-signed [name: string, base: string, signer: string] {
  http get $"($base)/($name).tar.xz" | save $"($name).tar.xz"
  http get $"($base)/($name).tar.sign" | save $"($name).tar.sign"
  xz --decompress --stdout $"($name).tar.xz" | save $"($name).tar"
  let status = gpg --batch --status-fd 1 --verify $"($name).tar.sign" $"($name).tar" | lines
  let signed_by = $status | where $it starts-with '[GNUPG:] VALIDSIG '
    | each {|line| $line | split row ' ' | last }
  if $signed_by != [$signer] {
    error make {msg: $"($name).tar.sign isn't a valid signature by ($signer): ($status | str join '; ')"}
  }
  print $"($name).tar: good signature by ($signer)"
}
fetch-signed $"git-($version)" $base $signer

# Debian's hardening flags without debug info, plus link-time optimization, for both builds. The
# base image drops dpkg's default vendor, and without one dpkg-buildflags prints nothing.
$env.DEB_VENDOR = 'Debian'
$env.DEB_BUILD_MAINT_OPTIONS = 'hardening=+all optimize=+lto'
$env.DEB_CFLAGS_MAINT_STRIP = '-g'
let cflags = dpkg-buildflags --get CFLAGS | str trim
let cppflags = dpkg-buildflags --get CPPFLAGS | str trim
let ldflags = dpkg-buildflags --get LDFLAGS | str trim
for flag in [-fstack-protector-strong -flto=auto] {
  if not ($cflags | split row ' ' | any {|it| $it == $flag }) {
    error make {msg: $"dpkg-buildflags' CFLAGS lack ($flag): '($cflags)'"}
  }
}

# zlib-ng, a static library git links in place of zlib, with its native API. It picks its
# CPU-specific code at run time, so one build suits every host. Its releases aren't signed
# (lightweight tags, unsigned commits), so the archive of the pinned commit must match the pinned
# digest, and its version the pinned version.
let zlib_ng = {
  version: $env.ZLIB_NG_VERSION
  commit: $env.ZLIB_NG_COMMIT
  url: $"https://github.com/zlib-ng/zlib-ng/archive/($env.ZLIB_NG_COMMIT).tar.gz"
}
http get $zlib_ng.url | save zlib-ng.tar.gz
let zlib_ng_digest = open --raw zlib-ng.tar.gz | hash sha256
if $zlib_ng_digest != $env.ZLIB_NG_SHA256 {
  error make {msg: $"($zlib_ng.url): sha256 ($zlib_ng_digest), expected ($env.ZLIB_NG_SHA256)"}
}
tar -xzf zlib-ng.tar.gz
cd $"zlib-ng-($zlib_ng.commit)"
let zlib_ng_header = open --raw zlib-ng.h.in
if not ($zlib_ng_header | str contains $"#define ZLIBNG_VERSION \"($zlib_ng.version)\"") {
  error make {msg: $"zlib-ng ($zlib_ng.commit) isn't version ($zlib_ng.version)"}
}
with-env {CFLAGS: $"($cppflags) ($cflags)", LDFLAGS: $ldflags} {
  ./configure --static --prefix=/opt/zlib-ng
}
make $"-j($jobs)"
make test
make install
let zlib_ng_license = $"($work)/zlib-ng-LICENSE.md"
cp LICENSE.md $zlib_ng_license
cd $work

tar -xf $"git-($version).tar"
cd $"git-($version)"
# sysconfdir keeps the system config at /etc/gitconfig, where `git config --system` and other
# tools expect it. No Perl, Python, Tcl/Tk, or translations: no send-email, svn, p4, gitk, or
# git-gui. No expat: git-http-push only pushes over WebDAV. SHA-1 stays collision-detecting for
# object IDs; OpenSSL's accelerated SHA-1 is used only where that isn't needed (checksums of
# files git writes itself), and for SHA-256. Built-ins are symlinks rather than hard links, and
# only those git still needs as separate commands are installed. git's Rust code has no crate
# dependencies, so cargo runs offline: a build that tried to fetch one fails.
let make_args = [
  prefix=/usr/local sysconfdir=/etc
  $"CFLAGS=($cflags)" $"CPPFLAGS=($cppflags)" $"LDFLAGS=($ldflags)"
  ZLIB_NG=YesPlease ZLIB_NG_PATH=/opt/zlib-ng
  NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_EXPAT=YesPlease
  OPENSSL_SHA1_UNSAFE=YesPlease OPENSSL_SHA256=YesPlease USE_LIBPCRE2=YesPlease
  INSTALL_SYMLINKS=YesPlease SKIP_DASHED_BUILT_INS=YesPlease
]
$env.CARGO_NET_OFFLINE = 'true'
make $"-j($jobs)" ...$make_args all
make ...$make_args strip
# The hardening reached the binary: full RELRO (GNU_RELRO with BIND_NOW) and a stack protector.
let dynamic = readelf --dynamic --program-headers --wide git | lines
for marker in [GNU_RELRO BIND_NOW] {
  if not ($dynamic | any {|line| $line | str contains $marker }) {
    error make {msg: $"git isn't linked with ($marker)"}
  }
}
if not (readelf --dyn-syms --wide git | str contains __stack_chk_fail) {
  error make {msg: 'git has no stack protector'}
}

# The test suite, through prove so the log gets one line per test script. As root, tests that
# need an unprivileged user are skipped (the SANITY prerequisite).
(make ...$make_args DEFAULT_TEST_TARGET=prove $"GIT_PROVE_OPTS=--jobs ($jobs)"
  GIT_TEST_OPTS=--verbose-log test)
make ...$make_args -C contrib/subtree $"-j($jobs)" test

make ...$make_args DESTDIR=/out install
make ...$make_args DESTDIR=/out -C contrib/subtree install

# Commands a client container never runs: the daemon and servers, imap-send, instaweb, and the
# stubs that only report a missing Perl or Python. A version that stops shipping one fails here.
let exec_path = '/out/usr/local/libexec/git-core'
let unused = [
  git-daemon git-http-backend git-imap-send git-instaweb
  git-archimport git-cvsexportcommit git-cvsimport git-p4 git-send-email git-svn
]
for command in $unused {
  if not ($"($exec_path)/($command)" | path exists) {
    error make {msg: $"($exec_path)/($command) doesn't exist; update the list in git.nu"}
  }
  rm $"($exec_path)/($command)"
}
for command in [git-shell git-cvsserver] {
  rm $"/out/usr/local/bin/($command)"
}
if ($"($exec_path)/git-http-push" | path exists) {
  error make {msg: 'git-http-push was built despite NO_EXPAT'}
}

# The notices, and what scripts/collect-legal.sh records as the source: the tarball this build
# compiled, and this script, which controls the build, so git's source image carries it too
# (scripts/plan-sources.sh checks it against this digest). zlib-ng and the Rust standard library
# are compiled in too: zlib-ng is recorded as embedded (its archive is part of git's source), and
# the Rust notices and the license texts they reference come from the toolchain that built it.
let legal = '/out/legal/attribution/git'
mkdir $legal
cp COPYING LGPL-2.1 $legal
let rust_doc = glob /usr/local/rustup/toolchains/*/share/doc/rust | first
mkdir $"($legal)/rust"
cp $"($rust_doc)/COPYRIGHT-library.html" $"($legal)/rust/"
cp -r $"($rust_doc)/licenses" $"($legal)/rust/"
mkdir $"($legal)/zlib-ng"
cp $zlib_ng_license $"($legal)/zlib-ng/LICENSE.md"
let rustc = rustc --version | str trim
let digest = open --raw $"../git-($version).tar.xz" | hash sha256
let script_path = $script | path relative-to /mnt/src
let script_digest = open --raw $script | hash sha256
$"component: git
source: ($base)/git-($version).tar.xz
sha256: ($digest)
signer: ($signer)
toolchain: ($rustc)
build-script: ($script_path) sha256:($script_digest)
embedded: zlib-ng ($zlib_ng.version) Zlib ($zlib_ng.url) sha256:($zlib_ng_digest)
" | save $"($legal)/SOURCE"
