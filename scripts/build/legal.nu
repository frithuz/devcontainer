# Assembles /legal (Dockerfile's image stage, step 3). The build context is mounted at
# /mnt/legal-src, the gh stage's output at /mnt/gh-legal, and the config stage's at /mnt/config.
bash /mnt/legal-src/scripts/collect-legal.sh /mnt/legal-src/Dockerfile /mnt/config /mnt/gh-legal
# The version checks run node as root, which leaves a compile cache behind.
rm -rf /tmp/node-compile-cache
