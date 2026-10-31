#!/usr/bin/env bash
# Links in the files stage's /out tree (Dockerfile's files stage).
set -euo pipefail

# Every primary command resolves from /usr/local/bin (see "Default PATH").
cd /out/usr/local/bin
for bin in /out/usr/local/go/bin/*; do
	ln -s "/usr/local/go/bin/${bin##*/}" "${bin##*/}"
done
for bin in pnpm pn pnpx pnx; do
	ln -s "/opt/pnpm/$bin" "$bin"
done
