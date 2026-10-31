# Corresponding Source

This image includes software under copyleft licenses (GPL, LGPL, and MPL-2.0), such as git
(compiled from source for this image), MPL-2.0 Go modules, and Debian packages including Bash,
coreutils, and bubblewrap. `manifest.tsv` lists each component with its license and exact source
provenance.

`source.tsv` lists where the complete source of every GPL and LGPL component was published when
this image was built: one row per file, with its URL and digest, and the components it covers.

- **Debian packages:** the source package (`.dsc` and archives) at the exact version installed,
  from the repository it was installed from: Docker's hardened Debian rebuilds (`dhi.io`), or
  Debian's archive. Debian also keeps every version it has published at
  `https://snapshot.debian.org`.
- **git:** the release tarball it was compiled from, the archive of zlib-ng, which is compiled
  into it, and the script that controlled the build, at the commit this image was built from.

Every file is identified by its digest, so a copy from anywhere else can be checked against it.

The sandbox kits built on this image, `quay.io/frithuz/claude-kit` and `quay.io/frithuz/codex-kit`,
carry this same file: the agents they add bring no copyleft code.

The MPL-2.0 Go modules are compiled into binaries their upstream projects built and publish with
their source (betterleaks, dbmate, yq, Task, and Docker's packages), and are unmodified.
`manifest.tsv` lists each module (`go-module:` rows) with its exact version and its archive on the Go module
proxy, `https://proxy.golang.org`. Sampo's release binary likewise carries one unmodified MPL-2.0
Rust crate, `option-ext`, published on `https://crates.io`.
