#!/usr/bin/env bash
# Assembles /legal (Dockerfile's image stage, step 3). The build context is mounted at
# /mnt/legal-src, the gh stage's output at /mnt/gh-legal, the config stage's at /mnt/config, and
# the go stage's toolchain at /mnt/go: the image ships no Go, but collect-legal.sh reads the Go
# binaries' module info and downloads their modules with it.
set -euo pipefail

export PATH=/mnt/go/bin:$PATH

bash /mnt/legal-src/scripts/collect-legal.sh /mnt/legal-src/Dockerfile /mnt/config /mnt/gh-legal
bash /mnt/legal-src/scripts/collect-source.sh /mnt/config
# The version checks run node as root, which leaves a compile cache behind.
rm -rf /tmp/node-compile-cache
