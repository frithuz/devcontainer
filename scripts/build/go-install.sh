#!/usr/bin/env bash
# Builds a pinned Go command, static and stripped, and copies the verified module's LICENSE
# beside it (Dockerfile's jv, dnslookup, and gh-stack stages). From the stage's ARGs:
# MODULE is <module path>@<version>, PACKAGE the command's directory in the module ('.' for its
# root), OUT the destination, and LDFLAGS (optional) the linker flags, where {version} stands for
# the module's version.
set -euo pipefail

readonly module=${MODULE:?MODULE must be set} out=${OUT:?OUT must be set}
path=${module%@*}
version=${module##*@}
if [[ ${PACKAGE:?PACKAGE must be set} == . ]]; then
	package=$path
else
	package=$path/$PACKAGE
fi
# -s -w drop the symbol table and DWARF; the build info `go version -m` reads stays.
ldflags="-s -w ${LDFLAGS:-}"
ldflags=${ldflags//\{version\}/$version}
ldflags=${ldflags% }
CGO_ENABLED=0 GOBIN=$out go install -trimpath "-ldflags=$ldflags" "$package@$version"
cp "$(go env GOMODCACHE)/$module/LICENSE" "$out/LICENSE"
