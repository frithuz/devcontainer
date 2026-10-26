# Installs devcontainer-python3-shim, a local package that provides python3, before apt
# installs anything (Dockerfile's image stage, step 2). sudo-rs depends on python3:any (for an
# apport hook), which would otherwise pull in Ubuntu's own Python; the copied CPython in
# /usr/local is the image's python3. The package owns only its copyright file, so a package that
# needs Ubuntu's real python3 can still install it.
$env.DEBIAN_FRONTEND = 'noninteractive'
let arch = dpkg --print-architecture | str trim

let shim = mktemp -d
mkdir $"($shim)/DEBIAN" $"($shim)/usr/share/doc/devcontainer-python3-shim"
$"Package: devcontainer-python3-shim
Version: 1.0
Architecture: ($arch)
Multi-Arch: allowed
Maintainer: devcontainer <noreply@localhost>
Provides: python3
Description: python3 is provided by the copied CPython in /usr/local
 Satisfies unversioned python3 dependencies with the image's copied interpreter
 instead of installing Ubuntu's python3.
" | save $"($shim)/DEBIAN/control"
r#'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: devcontainer
Comment: Part of this project's image; see /legal/LICENSE.

Files: *
Copyright: none
License: CC0-1.0
 See /legal/LICENSE for the full text.
'# | save $"($shim)/usr/share/doc/devcontainer-python3-shim/copyright"
dpkg-deb --build $shim /tmp/devcontainer-python3-shim.deb
dpkg -i /tmp/devcontainer-python3-shim.deb
rm -rf $shim /tmp/devcontainer-python3-shim.deb
