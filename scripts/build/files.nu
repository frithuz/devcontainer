# Links in the files stage's /out tree (Dockerfile's files stage).
# pnpm picks its command from argv[0] (pnpx/pnx run `pnpm dlx`), so the aliases must be hard
# links next to the binary; symlinks resolve to `pnpm`. The image's single COPY keeps them.
for alias in [pn pnpx pnx] {
  ^ln /out/opt/pnpm/pnpm $"/out/opt/pnpm/($alias)"
}
# Every primary command resolves from /usr/local/bin (see "Default PATH").
cd /out/usr/local/bin
for bin in (ls /out/usr/local/go/bin | get name | path basename) {
  ^ln -s $"/usr/local/go/bin/($bin)" $bin
}
for bin in [pnpm pn pnpx pnx] {
  ^ln -s $"/opt/pnpm/($bin)" $bin
}
