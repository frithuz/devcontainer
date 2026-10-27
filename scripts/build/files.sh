#!/usr/bin/env bash
# Links in the files stage's /out tree (Dockerfile's files stage).
set -euo pipefail

# pnpm picks its command from argv[0] (pnpx/pnx run `pnpm dlx`), so the aliases must be hard
# links next to the binary; symlinks resolve to `pnpm`. The image's single COPY keeps them.
for alias in pn pnpx pnx; do
	ln /out/opt/pnpm/pnpm "/out/opt/pnpm/$alias"
done
# Every primary command resolves from /usr/local/bin (see "Default PATH").
cd /out/usr/local/bin
for bin in /out/usr/local/go/bin/*; do
	ln -s "/usr/local/go/bin/${bin##*/}" "${bin##*/}"
done
for bin in pnpm pn pnpx pnx; do
	ln -s "/opt/pnpm/$bin" "$bin"
done
